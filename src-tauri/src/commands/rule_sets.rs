//! Managed offline China rule sets.
//!
//! The route template names `geoip-cn` and `geosite-cn`, but this module makes
//! their source deterministic: a known-good SagerNet snapshot is bundled with
//! the application, copied to the writable app configuration directory on
//! first use, then refreshed in the background at most once every seven days.
//! sing-box watches local `.srs` files and reloads them when they are atomically
//! replaced, so refreshing never requires a VPN restart.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::Value;
use tauri::{AppHandle, Manager};
use tauri_plugin_http::reqwest;

use crate::core::DEFAULT_MIXED_PROXY_PORT;

use super::settings;

const RULE_SET_DIR: &str = "rule-sets";
const LAST_SUCCESSFUL_REFRESH_FILE: &str = "cn-rule-sets-updated-at";
const REFRESH_INTERVAL: Duration = Duration::from_secs(7 * 24 * 60 * 60);
const REFRESH_POLL_INTERVAL: Duration = Duration::from_secs(30 * 60);
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(20);
const MIN_RULE_SET_BYTES: usize = 32;

struct RuleSetSource {
    tag: &'static str,
    file_name: &'static str,
    url: &'static str,
}

const CN_RULE_SETS: [RuleSetSource; 2] = [
    RuleSetSource {
        tag: "geoip-cn",
        file_name: "geoip-cn.srs",
        url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
    },
    RuleSetSource {
        tag: "geosite-cn",
        file_name: "geosite-cn.srs",
        url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
    },
];

/// Absolute paths injected into the generated sing-box configuration.
#[derive(Clone, Debug)]
pub(crate) struct ManagedCnRuleSetPaths {
    pub(crate) geoip_cn: String,
    pub(crate) geosite_cn: String,
}

impl ManagedCnRuleSetPaths {
    fn path_for_tag(&self, tag: &str) -> Option<&str> {
        match tag {
            "geoip-cn" => Some(&self.geoip_cn),
            "geosite-cn" => Some(&self.geosite_cn),
            _ => None,
        }
    }
}

fn rule_set_dir(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .app_config_dir()
        .map_err(|error| format!("resolve rule-set directory: {error}"))?
        .join(RULE_SET_DIR))
}

fn bundled_rule_set_path(app: &AppHandle, source: &RuleSetSource) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .resource_dir()
        .map_err(|error| format!("resolve bundled rule sets: {error}"))?
        .join("rules")
        .join(source.file_name))
}

fn is_valid_rule_set(bytes: &[u8]) -> bool {
    // `.srs` is binary, but its internal format is intentionally owned by
    // sing-box. A small, non-HTML payload catches common CDN/proxy failure
    // pages without rejecting a future valid rule-set format.
    bytes.len() >= MIN_RULE_SET_BYTES && !bytes.starts_with(b"<")
}

fn is_valid_rule_set_file(path: &Path) -> bool {
    fs::read(path)
        .map(|bytes| is_valid_rule_set(&bytes))
        .unwrap_or(false)
}

fn write_atomically(path: &Path, data: &[u8]) -> Result<(), String> {
    let Some(parent) = path.parent() else {
        return Err("rule-set path has no parent".to_owned());
    };
    fs::create_dir_all(parent).map_err(|error| format!("create rule-set directory: {error}"))?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| "invalid rule-set file name".to_owned())?;
    let temporary = parent.join(format!(".{file_name}.{}.tmp", uuid::Uuid::new_v4()));

    let result = (|| -> Result<(), String> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|error| format!("create temporary rule set: {error}"))?;
        file.write_all(data)
            .map_err(|error| format!("write temporary rule set: {error}"))?;
        file.sync_all()
            .map_err(|error| format!("sync temporary rule set: {error}"))?;
        drop(file);
        fs::rename(&temporary, path).map_err(|error| format!("replace rule set: {error}"))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// Ensures each managed rule set exists on disk before a configuration points
/// to it. Existing valid copies are never overwritten by the bundled version.
pub(crate) fn ensure_cn_rule_set_baseline(app: &AppHandle) -> Result<ManagedCnRuleSetPaths, String> {
    let directory = rule_set_dir(app)?;
    fs::create_dir_all(&directory).map_err(|error| format!("create rule-set directory: {error}"))?;

    for source in &CN_RULE_SETS {
        let destination = directory.join(source.file_name);
        if is_valid_rule_set_file(&destination) {
            continue;
        }
        let bundled = bundled_rule_set_path(app, source)?;
        let bytes = fs::read(&bundled)
            .map_err(|error| format!("read bundled {}: {error}", source.file_name))?;
        if !is_valid_rule_set(&bytes) {
            return Err(format!("bundled {} is invalid", source.file_name));
        }
        write_atomically(&destination, &bytes)?;
        log::info!("[RULE-SETS] Installed bundled {}", source.file_name);
    }

    Ok(ManagedCnRuleSetPaths {
        geoip_cn: directory.join("geoip-cn.srs").to_string_lossy().into_owned(),
        geosite_cn: directory.join("geosite-cn.srs").to_string_lossy().into_owned(),
    })
}

/// Converts only the CN definitions that are already present in the template
/// to local SagerNet rule sets. All route rule ordering remains untouched:
/// custom direct/proxy rules stay before the CN direct rule.
pub(crate) fn inject_managed_cn_rule_sets(
    config: &mut Value,
    paths: &ManagedCnRuleSetPaths,
) -> bool {
    let Some(route) = config.get_mut("route").and_then(Value::as_object_mut) else {
        return false;
    };
    let Some(rule_sets) = route.get_mut("rule_set").and_then(Value::as_array_mut) else {
        return false;
    };

    let mut changed = false;
    for source in &CN_RULE_SETS {
        let Some(path) = paths.path_for_tag(source.tag) else {
            continue;
        };
        let Some(rule_set) = rule_sets.iter_mut().find(|rule_set| {
            rule_set.get("tag").and_then(Value::as_str) == Some(source.tag)
        }) else {
            continue;
        };
        let managed = serde_json::json!({
            "tag": source.tag,
            "type": "local",
            "format": "binary",
            "path": path,
        });
        if *rule_set != managed {
            *rule_set = managed;
            changed = true;
        }
    }
    changed
}

/// Migrates a configuration generated by an older app version before the
/// local rule-set policy existed. It is intentionally idempotent so opening
/// the application never rewrites an already-correct configuration.
pub(crate) fn migrate_current_config_to_managed_cn_rule_sets(
    app: &AppHandle,
) -> Result<bool, String> {
    let paths = ensure_cn_rule_set_baseline(app)?;
    let config_path = app
        .path()
        .app_config_dir()
        .map_err(|error| format!("resolve config directory: {error}"))?
        .join("config.json");
    if !config_path.is_file() {
        return Ok(false);
    }
    let mut config: Value = serde_json::from_slice(
        &fs::read(&config_path).map_err(|error| format!("read current config: {error}"))?,
    )
    .map_err(|error| format!("parse current config: {error}"))?;
    if !inject_managed_cn_rule_sets(&mut config, &paths) {
        return Ok(false);
    }
    let data = serde_json::to_vec(&config)
        .map_err(|error| format!("serialize migrated config: {error}"))?;
    write_atomically(&config_path, &data)?;
    log::info!("[RULE-SETS] Migrated existing config to bundled CN rule sets");
    Ok(true)
}

fn now_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn refresh_timestamp_path(directory: &Path) -> PathBuf {
    directory.join(LAST_SUCCESSFUL_REFRESH_FILE)
}

fn refresh_is_due(directory: &Path) -> bool {
    let last_refresh = fs::read_to_string(refresh_timestamp_path(directory))
        .ok()
        .and_then(|timestamp| timestamp.trim().parse::<u64>().ok());
    last_refresh
        .is_none_or(|timestamp| now_unix_secs().saturating_sub(timestamp) >= REFRESH_INTERVAL.as_secs())
}

fn proxy_port(app: &AppHandle) -> u16 {
    settings::settings_store(app)
        .ok()
        .and_then(|store| store.get("proxy_port_key"))
        .and_then(|value| value.as_u64())
        .filter(|port| (1..=65535).contains(port))
        .map(|port| port as u16)
        .unwrap_or(DEFAULT_MIXED_PROXY_PORT)
}

async fn download_rule_set(source: &RuleSetSource, port: u16) -> Result<Vec<u8>, String> {
    // GitHub is normally reached through the currently active NekoPilot
    // mixed listener. If it is not running yet, this quickly fails and the
    // bundled baseline remains active; the periodic task retries later.
    let proxy = reqwest::Proxy::all(format!("http://127.0.0.1:{port}"))
        .map_err(|error| format!("create rule-set proxy: {error}"))?;
    let client = reqwest::ClientBuilder::new()
        .timeout(DOWNLOAD_TIMEOUT)
        .proxy(proxy)
        .user_agent("NekoPilot rule-set updater")
        .build()
        .map_err(|error| format!("create rule-set client: {error}"))?;
    let response = client
        .get(source.url)
        .send()
        .await
        .map_err(|error| format!("download {}: {error}", source.file_name))?;
    if !response.status().is_success() {
        return Err(format!("download {}: HTTP {}", source.file_name, response.status()));
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|error| format!("read {}: {error}", source.file_name))?
        .to_vec();
    if !is_valid_rule_set(&bytes) {
        return Err(format!("downloaded {} is invalid", source.file_name));
    }
    Ok(bytes)
}

async fn local_proxy_is_ready(port: u16) -> bool {
    matches!(
        tokio::time::timeout(
            Duration::from_secs(1),
            tokio::net::TcpStream::connect(("127.0.0.1", port)),
        )
        .await,
        Ok(Ok(_))
    )
}

async fn refresh_cn_rule_sets_if_due(app: &AppHandle) {
    let Ok(paths) = ensure_cn_rule_set_baseline(app) else {
        log::warn!("[RULE-SETS] Bundled baseline is unavailable; skipping refresh");
        return;
    };
    let Ok(directory) = rule_set_dir(app) else {
        return;
    };
    if !refresh_is_due(&directory) {
        return;
    }

    let port = proxy_port(app);
    if !local_proxy_is_ready(port).await {
        return;
    }
    let mut downloads = Vec::with_capacity(CN_RULE_SETS.len());
    for source in &CN_RULE_SETS {
        match download_rule_set(source, port).await {
            Ok(bytes) => downloads.push((source, bytes)),
            Err(error) => {
                log::info!("[RULE-SETS] {}", error);
                return;
            }
        }
    }

    for (source, bytes) in downloads {
        let Some(path) = paths.path_for_tag(source.tag) else {
            continue;
        };
        if let Err(error) = write_atomically(Path::new(path), &bytes) {
            log::warn!("[RULE-SETS] Failed to store {}: {}", source.file_name, error);
            return;
        }
    }
    if let Err(error) = write_atomically(
        &refresh_timestamp_path(&directory),
        now_unix_secs().to_string().as_bytes(),
    ) {
        log::warn!("[RULE-SETS] Failed to save refresh timestamp: {}", error);
        return;
    }
    log::info!("[RULE-SETS] Refreshed SagerNet CN rule sets");
}

/// Starts the lightweight stale-check loop. It only downloads when the last
/// successful update is at least seven days old.
pub(crate) fn spawn_cn_rule_set_refresh_task(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        loop {
            refresh_cn_rule_sets_if_due(&app).await;
            tokio::time::sleep(REFRESH_POLL_INTERVAL).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replaces_only_cn_rule_set_definitions_with_local_files() {
        let mut config = serde_json::json!({
            "route": {"rule_set": [
                {"tag": "geoip-cn", "type": "remote", "url": "https://old.example"},
                {"tag": "geosite-cn", "type": "remote", "url": "https://old.example"},
                {"tag": "geosite-apple", "type": "remote", "url": "https://keep.example"}
            ]}
        });
        let paths = ManagedCnRuleSetPaths {
            geoip_cn: "/tmp/geoip-cn.srs".to_owned(),
            geosite_cn: "/tmp/geosite-cn.srs".to_owned(),
        };

        assert!(inject_managed_cn_rule_sets(&mut config, &paths));

        assert_eq!(config["route"]["rule_set"][0]["type"], "local");
        assert_eq!(config["route"]["rule_set"][0]["path"], "/tmp/geoip-cn.srs");
        assert_eq!(config["route"]["rule_set"][1]["path"], "/tmp/geosite-cn.srs");
        assert_eq!(config["route"]["rule_set"][2]["url"], "https://keep.example");
        assert!(!inject_managed_cn_rule_sets(&mut config, &paths));
    }

    #[test]
    fn rejects_empty_and_html_payloads() {
        assert!(!is_valid_rule_set(b""));
        assert!(!is_valid_rule_set(b"<html>rule set download error</html>"));
        assert!(is_valid_rule_set(&[0_u8; MIN_RULE_SET_BYTES]));
    }

    #[tokio::test]
    async fn closed_local_port_is_not_considered_ready() {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        assert!(!local_proxy_is_ready(port).await);
    }
}
