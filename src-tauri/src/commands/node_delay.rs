//! One-shot node URL testing while the main proxy engine is disconnected.
//!
//! `sing-box tools fetch` loads a stripped copy of the generated runtime
//! configuration, sends one request through the requested outbound, and exits.
//! It never opens an inbound listener or changes the macOS system proxy.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde_json::Value;
use tauri::{AppHandle, Manager};
use tauri_plugin_shell::{process::CommandEvent, ShellExt};

use super::config_write::write_atomically;

const URL_TEST_TARGET: &str = "https://www.google.com/generate_204";
const URL_TEST_TIMEOUT: Duration = Duration::from_secs(6);
const DEFAULT_DIRECT_DNS: &str = "223.5.5.5";

struct TemporaryConfig(PathBuf);

impl Drop for TemporaryConfig {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_file(&self.0) {
            if error.kind() != std::io::ErrorKind::NotFound {
                log::warn!("failed to remove one-shot URL Test config: {error}");
            }
        }
    }
}

fn direct_dns_server(config: &Value) -> String {
    config
        .get("dns")
        .and_then(|dns| dns.get("servers"))
        .and_then(Value::as_array)
        .and_then(|servers| {
            servers.iter().find_map(|server| {
                (server.get("tag").and_then(Value::as_str) == Some("system"))
                    .then(|| server.get("server").and_then(Value::as_str))
                    .flatten()
            })
        })
        .filter(|server| server.parse::<std::net::IpAddr>().is_ok())
        .unwrap_or(DEFAULT_DIRECT_DNS)
        .to_owned()
}

fn prepare_url_test_config(mut config: Value, node_name: &str) -> Result<Value, String> {
    let is_runtime_node = config
        .get("outbounds")
        .and_then(Value::as_array)
        .is_some_and(|outbounds| {
            outbounds.iter().any(|outbound| {
                outbound.get("tag").and_then(Value::as_str) == Some(node_name)
                    && !matches!(
                        outbound.get("type").and_then(Value::as_str),
                        Some("selector" | "urltest" | "direct" | "block" | "dns")
                    )
            })
        });
    if !is_runtime_node {
        return Err("url_test_node_not_found".to_owned());
    }

    let dns_server = direct_dns_server(&config);
    let root = config
        .as_object_mut()
        .ok_or_else(|| "url_test_config_invalid".to_owned())?;
    root.insert("log".to_owned(), serde_json::json!({ "level": "warn" }));
    root.insert("inbounds".to_owned(), Value::Array(Vec::new()));
    root.remove("experimental");
    root.insert(
        "dns".to_owned(),
        serde_json::json!({
            "servers": [{
                "type": "udp",
                "tag": "system",
                "server": dns_server,
                "server_port": 53
            }],
            "final": "system"
        }),
    );
    root.insert(
        "route".to_owned(),
        serde_json::json!({ "auto_detect_interface": true, "rules": [] }),
    );
    Ok(config)
}

/// Measures a single runtime node without starting the app engine. The return
/// value is `None` for timeout/connection failure, matching the renderer's
/// existing `-` delay state.
#[tauri::command]
pub async fn measure_offline_node_delay(
    app: AppHandle,
    node_name: String,
) -> Result<Option<u64>, String> {
    let config_dir = app
        .path()
        .app_config_dir()
        .map_err(|error| format!("resolve config directory: {error}"))?;
    let config_path = config_dir.join("config.json");
    let raw = tokio::fs::read(&config_path)
        .await
        .map_err(|error| format!("read URL Test config: {error}"))?;
    let config = serde_json::from_slice(raw.as_slice())
        .map_err(|error| format!("parse URL Test config: {error}"))?;
    let config = prepare_url_test_config(config, &node_name)?;
    let bytes = serde_json::to_vec(&config)
        .map_err(|error| format!("serialize URL Test config: {error}"))?;

    let file_name = format!("url-test-{}.json", uuid::Uuid::new_v4());
    write_atomically(&config_dir, &file_name, &bytes)?;
    let temporary_config = TemporaryConfig(config_dir.join(file_name));
    let temporary_path = temporary_config.0.to_string_lossy().into_owned();

    let command = app
        .shell()
        .sidecar("sing-box")
        .map_err(|error| format!("URL Test sidecar lookup failed: {error}"))?
        .args([
            "tools",
            "fetch",
            "-c",
            temporary_path.as_str(),
            "-o",
            node_name.as_str(),
            URL_TEST_TARGET,
            "--disable-color",
        ]);
    let started_at = Instant::now();
    let (mut events, child) = command
        .spawn()
        .map_err(|error| format!("URL Test spawn failed: {error}"))?;

    let completion = tokio::time::timeout(URL_TEST_TIMEOUT, async {
        while let Some(event) = events.recv().await {
            match event {
                CommandEvent::Terminated(payload) => return payload.code == Some(0),
                CommandEvent::Error(_) => return false,
                _ => {}
            }
        }
        false
    })
    .await;

    match completion {
        Ok(true) => Ok(Some(started_at.elapsed().as_millis() as u64)),
        Ok(false) => Ok(None),
        Err(_) => {
            let _ = child.kill();
            Ok(None)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn runtime_config() -> Value {
        serde_json::json!({
            "log": {"level":"info"},
            "dns": {
                "servers": [{"tag":"system", "type":"udp", "server":"119.29.29.29"}],
                "rules": [{"rule_set":"geoip-cn", "server":"system"}]
            },
            "inbounds": [{"type":"mixed", "listen_port":16789}],
            "outbounds": [
                {"type":"selector", "tag":"ExitGateway", "outbounds":["node-a"]},
                {"type":"vless", "tag":"node-a", "domain_resolver":"system"}
            ],
            "route": {
                "rule_set": [{"type":"remote", "tag":"geoip-cn"}],
                "rules": [{"rule_set":"geoip-cn", "outbound":"direct"}]
            },
            "experimental": {"cache_file":{"enabled":true}, "clash_api":{}}
        })
    }

    #[test]
    fn creates_a_listener_free_one_shot_config() {
        let config = prepare_url_test_config(runtime_config(), "node-a").unwrap();
        assert_eq!(config["inbounds"], serde_json::json!([]));
        assert!(config.get("experimental").is_none());
        assert_eq!(config["route"]["rules"], serde_json::json!([]));
        assert!(config["route"].get("rule_set").is_none());
        assert_eq!(config["dns"]["servers"][0]["server"], "119.29.29.29");
    }

    #[test]
    fn rejects_non_node_outbounds_and_unknown_tags() {
        assert_eq!(
            prepare_url_test_config(runtime_config(), "ExitGateway").unwrap_err(),
            "url_test_node_not_found"
        );
        assert_eq!(
            prepare_url_test_config(runtime_config(), "missing").unwrap_err(),
            "url_test_node_not_found"
        );
    }
}
