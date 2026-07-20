//! Native, validated access to the persistent settings store.
//!
//! Settings stay in the existing `settings.json` format so upgrades retain
//! user choices, but the renderer no longer writes this file directly.

use std::net::IpAddr;

use serde_json::Value;
use tauri::AppHandle;
use tauri_plugin_store::StoreExt;

const PROXY_PORT_KEY: &str = "proxy_port_key";
const DIRECT_DNS_KEY: &str = "direct_dns";
const BOOLEAN_KEYS: [&str; 4] = [
    "allow_lan_key",
    "auto_select_fastest_node_key",
    "show_node_protocol_key",
    "skip_system_proxy_key",
];
const STRING_LIMIT: usize = 16 * 1024;
const TEMPLATE_CACHE_LIMIT: usize = 2 * 1024 * 1024;
const RULESET_PREFIX: &str = "custom_ruleset_";
const RULESET_KEYS: [&str; 2] = ["custom_ruleset_direct", "custom_ruleset_proxy"];
const TEMPLATE_CACHE_MARKER: &str = "-template-config-cache";
const NODE_DELAY_HISTORY_KEY: &str = "node_delay_history_key";
const MAX_NODE_DELAY_HISTORY_ENTRIES: usize = 2_000;
const INTEGER_KEYS: [&str; 1] = ["github_release_update_last_check_ms"];
const STRING_KEYS: [&str; 4] = [
    "selected_subscription_identifier",
    "selected_node_tag_key",
    "user_agent_key",
    "clash_api_secret_key",
];

pub(crate) fn is_valid_ip_cidr(value: &str) -> bool {
    let Some((address, prefix)) = value.trim().rsplit_once('/') else {
        return false;
    };
    let Ok(address) = address.parse::<IpAddr>() else {
        return false;
    };
    let Ok(prefix) = prefix.parse::<u8>() else {
        return false;
    };
    match address {
        IpAddr::V4(_) => prefix <= 32,
        IpAddr::V6(_) => prefix <= 128,
    }
}

fn validate_custom_rules(raw: &str) -> bool {
    let Ok(Value::Object(rules)) = serde_json::from_str::<Value>(raw) else {
        return false;
    };
    for field in ["domain", "domain_suffix", "ip_cidr"] {
        let Some(value) = rules.get(field) else {
            continue;
        };
        let Some(values) = value.as_array() else {
            return false;
        };
        if values.iter().any(|value| {
            value.as_str().is_none_or(|value| {
                value.trim().is_empty() || (field == "ip_cidr" && !is_valid_ip_cidr(value))
            })
        }) {
            return false;
        }
    }
    true
}

fn validate_node_delay_history(value: &Value) -> bool {
    let Some(history) = value.as_object() else {
        return false;
    };
    if history.len() > MAX_NODE_DELAY_HISTORY_ENTRIES {
        return false;
    }
    history.iter().all(|(node, entry)| {
        if node.is_empty() || node.len() > 1_024 {
            return false;
        }
        let Some(entry) = entry.as_object() else {
            return false;
        };
        let delay_is_valid = entry.get("delay").is_some_and(|delay| {
            delay.as_str() == Some("-") || delay.as_u64().is_some_and(|delay| delay <= 600_000)
        });
        delay_is_valid && entry.get("measuredAt").and_then(Value::as_u64).is_some()
    })
}

fn validate_setting(key: &str, value: &Value) -> Result<(), String> {
    if key.trim().is_empty() || key.len() > 256 {
        return Err("invalid_setting_key".to_owned());
    }
    let serialized_limit = if key.contains(TEMPLATE_CACHE_MARKER) {
        TEMPLATE_CACHE_LIMIT
    } else {
        STRING_LIMIT
    };
    let serialized_len = serde_json::to_vec(value)
        .map_err(|_| "invalid_setting_value".to_owned())?
        .len();
    if serialized_len > serialized_limit {
        return Err("setting_value_too_large".to_owned());
    }
    if key == PROXY_PORT_KEY {
        let port = value
            .as_u64()
            .ok_or_else(|| "invalid_proxy_port".to_owned())?;
        if !(1..=65535).contains(&port) {
            return Err("invalid_proxy_port".to_owned());
        }
        return Ok(());
    }
    if key == DIRECT_DNS_KEY {
        let server = value
            .as_str()
            .map(str::trim)
            .filter(|server| !server.is_empty())
            .ok_or_else(|| "invalid_direct_dns".to_owned())?;
        server
            .parse::<IpAddr>()
            .map_err(|_| "invalid_direct_dns".to_owned())?;
        return Ok(());
    }
    if BOOLEAN_KEYS.contains(&key) {
        if !value.is_boolean() {
            return Err("invalid_boolean_setting".to_owned());
        }
        return Ok(());
    }
    if INTEGER_KEYS.contains(&key) {
        if value.as_u64().is_none() {
            return Err("invalid_integer_setting".to_owned());
        }
        return Ok(());
    }
    if STRING_KEYS.contains(&key) {
        if value.as_str().is_none() {
            return Err("invalid_string_setting".to_owned());
        }
        return Ok(());
    }
    if key == NODE_DELAY_HISTORY_KEY {
        if !validate_node_delay_history(value) {
            return Err("invalid_node_delay_history".to_owned());
        }
        return Ok(());
    }
    if key.starts_with(RULESET_PREFIX) {
        if !RULESET_KEYS.contains(&key) {
            return Err("invalid_setting_key".to_owned());
        }
        let raw = value
            .as_str()
            .ok_or_else(|| "invalid_custom_rules".to_owned())?;
        if raw.len() > STRING_LIMIT || !validate_custom_rules(raw) {
            return Err("invalid_custom_rules".to_owned());
        }
        return Ok(());
    }
    if let Some(string) = value.as_str() {
        if string.len() > serialized_limit {
            return Err("setting_value_too_large".to_owned());
        }
    }
    Ok(())
}

pub(crate) fn settings_store(
    app: &AppHandle,
) -> Result<std::sync::Arc<tauri_plugin_store::Store<tauri::Wry>>, String> {
    app.store("settings.json")
        .map_err(|error| format!("open settings store: {error}"))
}

#[tauri::command]
pub fn get_setting(app: AppHandle, key: String) -> Result<Option<Value>, String> {
    if key.trim().is_empty() || key.len() > 256 {
        return Err("invalid_setting_key".to_owned());
    }
    Ok(settings_store(&app)?.get(key))
}

#[tauri::command]
pub fn set_setting(app: AppHandle, key: String, value: Value) -> Result<(), String> {
    validate_setting(&key, &value)?;
    let store = settings_store(&app)?;
    store.set(key, value);
    store
        .save()
        .map_err(|error| format!("save settings store: {error}"))
}

#[tauri::command]
pub fn delete_setting(app: AppHandle, key: String) -> Result<bool, String> {
    if key.trim().is_empty() || key.len() > 256 {
        return Err("invalid_setting_key".to_owned());
    }
    let store = settings_store(&app)?;
    let deleted = store.delete(key);
    if deleted {
        store
            .save()
            .map_err(|error| format!("save settings store: {error}"))?;
    }
    Ok(deleted)
}

#[tauri::command]
pub fn list_setting_keys(app: AppHandle) -> Result<Vec<String>, String> {
    Ok(settings_store(&app)?.keys())
}

pub(crate) fn get_or_create_clash_api_secret_for_app(app: &AppHandle) -> Result<String, String> {
    const KEY: &str = "clash_api_secret_key";
    let store = settings_store(app)?;
    if let Some(secret) = store
        .get(KEY)
        .and_then(|value| value.as_str().map(ToOwned::to_owned))
    {
        if !secret.trim().is_empty() {
            return Ok(secret);
        }
    }
    let secret = uuid::Uuid::new_v4().simple().to_string();
    store.set(KEY, Value::String(secret.clone()));
    store
        .save()
        .map_err(|error| format!("save generated clash api secret: {error}"))?;
    Ok(secret)
}

#[tauri::command]
pub fn get_or_create_clash_api_secret(app: AppHandle) -> Result<String, String> {
    get_or_create_clash_api_secret_for_app(&app)
}

#[cfg(test)]
mod tests {
    use super::validate_setting;

    #[test]
    fn rejects_invalid_critical_settings() {
        assert!(validate_setting("proxy_port_key", &serde_json::json!(0)).is_err());
        assert!(validate_setting("direct_dns", &serde_json::json!("223.5.5.5")).is_ok());
        assert!(validate_setting("direct_dns", &serde_json::json!("bad dns")).is_err());
        assert!(validate_setting("allow_lan_key", &serde_json::json!("true")).is_err());
        assert!(validate_setting("auto_select_fastest_node_key", &serde_json::json!(true)).is_ok());
        assert!(
            validate_setting("auto_select_fastest_node_key", &serde_json::json!("true")).is_err()
        );
        assert!(validate_setting("custom_ruleset_direct", &serde_json::json!("bad json")).is_err());
        assert!(validate_setting("custom_ruleset_reject", &serde_json::json!("{}")).is_err());
        assert!(validate_setting(
            "custom_ruleset_direct",
            &serde_json::json!(r#"{"domain":[],"domain_suffix":[],"ip_cidr":["10.240.31.0/255"]}"#),
        )
        .is_err());
        assert!(validate_setting(
            "custom_ruleset_direct",
            &serde_json::json!(
                r#"{"domain":[],"domain_suffix":[],"ip_cidr":["10.240.31.0/24","2001:db8::/32"]}"#
            ),
        )
        .is_ok());
        assert!(validate_setting("proxy_port_key", &serde_json::json!(6789)).is_ok());
        assert!(validate_setting(
            "node_delay_history_key",
            &serde_json::json!({"node-a":{"delay":48,"measuredAt":1_784_000_000_000_u64}}),
        )
        .is_ok());
        assert!(validate_setting(
            "node_delay_history_key",
            &serde_json::json!({"node-a":{"delay":-1,"measuredAt":1}}),
        )
        .is_err());
        assert!(validate_setting(
            "github_release_update_last_check_ms",
            &serde_json::json!(1_784_000_000_000_u64),
        )
        .is_ok());
        assert!(validate_setting(
            "github_release_update_last_check_ms",
            &serde_json::json!("now"),
        )
        .is_err());
        assert!(validate_setting("selected_node_tag_key", &serde_json::json!(7)).is_err());
    }

    #[test]
    fn rejects_oversized_non_string_values() {
        let oversized = serde_json::json!({"data": vec![0_u8; super::STRING_LIMIT]});
        assert_eq!(
            validate_setting("unknown_legacy_key", &oversized),
            Err("setting_value_too_large".to_owned())
        );
        let bounded = serde_json::json!({"enabled": true});
        assert!(validate_setting("unknown_legacy_key", &bounded).is_ok());
    }
}
