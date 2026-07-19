//! Native, validated access to the persistent settings store.
//!
//! Settings stay in the existing `settings.json` format so upgrades retain
//! user choices, but the renderer no longer writes this file directly.

use serde_json::Value;
use tauri::AppHandle;
use tauri_plugin_store::StoreExt;

const PROXY_PORT_KEY: &str = "proxy_port_key";
const BOOLEAN_KEYS: [&str; 4] = [
    "allow_lan_key",
    "use_dhcp_key",
    "show_node_protocol_key",
    "skip_system_proxy_key",
];
const STRING_LIMIT: usize = 16 * 1024;
const RULESET_PREFIX: &str = "custom_ruleset_";
const RULESET_KEYS: [&str; 2] = ["custom_ruleset_direct", "custom_ruleset_proxy"];
const TEMPLATE_CACHE_MARKER: &str = "-template-config-cache";

fn validate_setting(key: &str, value: &Value) -> Result<(), String> {
    if key.trim().is_empty() || key.len() > 256 {
        return Err("invalid_setting_key".to_owned());
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
    if BOOLEAN_KEYS.contains(&key) {
        if !value.is_boolean() {
            return Err("invalid_boolean_setting".to_owned());
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
        if raw.len() > STRING_LIMIT || !serde_json::from_str::<Value>(raw).is_ok_and(|v| v.is_object()) {
            return Err("invalid_custom_rules".to_owned());
        }
        return Ok(());
    }
    if let Some(string) = value.as_str() {
        let max_len = if key.contains(TEMPLATE_CACHE_MARKER) {
            2 * 1024 * 1024
        } else {
            STRING_LIMIT
        };
        if string.len() > max_len {
            return Err("setting_value_too_large".to_owned());
        }
    }
    Ok(())
}

pub(crate) fn settings_store(app: &AppHandle) -> Result<std::sync::Arc<tauri_plugin_store::Store<tauri::Wry>>, String> {
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
    if let Some(secret) = store.get(KEY).and_then(|value| value.as_str().map(ToOwned::to_owned)) {
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
        assert!(validate_setting("allow_lan_key", &serde_json::json!("true")).is_err());
        assert!(validate_setting("custom_ruleset_direct", &serde_json::json!("bad json")).is_err());
        assert!(validate_setting("custom_ruleset_reject", &serde_json::json!("{}")).is_err());
        assert!(validate_setting("proxy_port_key", &serde_json::json!(6789)).is_ok());
    }
}
