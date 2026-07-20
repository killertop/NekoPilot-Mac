//! Native preparation of generated sing-box configurations.
//!
//! The frontend owns UI state, while database reads, JSON mutation and
//! persistence stay native so the aggregate node pool never crosses the
//! JavaScript bridge.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use tauri::{AppHandle, Manager};

use crate::core::{CLASH_API_PORT, DEFAULT_MIXED_PROXY_PORT};

use super::{
    config_write::write_atomically,
    rule_sets, settings,
    subscription::{self, SubscriptionConfigForBuild},
};

const ACTION_ANCHORS: [(&str, &str); 2] = [
    ("direct", "direct-tag.nekopilot.invalid"),
    ("proxy", "proxy-tag.nekopilot.invalid"),
];
const LEGACY_REJECT_ANCHOR: &str = "reject-tag.nekopilot.invalid";
const RUNTIME_NODE_TAG_PREFIX: &str = "@np:";

#[derive(Debug)]
pub struct ConfigBuildOptions {
    pub log_level: String,
    pub db_cache_file_path: String,
    pub clash_api_secret: String,
    pub allow_lan: bool,
    pub proxy_port: u16,
    pub use_dhcp: bool,
    pub direct_dns: String,
    pub custom_rules: Option<CustomRules>,
    pub managed_cn_rule_sets: rule_sets::ManagedCnRuleSetPaths,
}

#[derive(Debug, Default, Deserialize)]
pub struct CustomRules {
    #[serde(default)]
    pub direct: RuleSet,
    #[serde(default)]
    pub proxy: RuleSet,
}

#[derive(Debug, Default, Deserialize, Serialize)]
pub struct RuleSet {
    #[serde(default)]
    pub domain: Vec<String>,
    #[serde(default)]
    pub domain_suffix: Vec<String>,
    #[serde(default)]
    pub ip_cidr: Vec<String>,
}

fn string_setting(store: &tauri_plugin_store::Store<tauri::Wry>, key: &str) -> Option<String> {
    store
        .get(key)
        .and_then(|value| value.as_str().map(str::trim).filter(|value| !value.is_empty()).map(ToOwned::to_owned))
}

fn bool_setting(store: &tauri_plugin_store::Store<tauri::Wry>, key: &str) -> bool {
    store.get(key).and_then(|value| value.as_bool()).unwrap_or(false)
}

fn custom_rule_setting(store: &tauri_plugin_store::Store<tauri::Wry>, action: &str) -> RuleSet {
    let key = format!("custom_ruleset_{action}");
    let mut rules: RuleSet = string_setting(store, &key)
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default();
    let previous_count = rules.ip_cidr.len();
    rules
        .ip_cidr
        .retain(|value| settings::is_valid_ip_cidr(value));
    if rules.ip_cidr.len() != previous_count {
        if let Ok(raw) = serde_json::to_string(&rules) {
            store.set(key, Value::String(raw));
            if let Err(error) = store.save() {
                log::warn!("failed to persist repaired custom CIDR rules: {error}");
            }
        }
        log::warn!(
            "removed {} invalid custom CIDR rule(s) from {action}",
            previous_count - rules.ip_cidr.len()
        );
    }
    rules
}

/// Loads all engine-affecting settings from the native store. The renderer
/// never supplies proxy ports, DNS, rules or the controller secret to the
/// config compiler, so one trusted source governs validation and persistence.
fn build_options_from_settings(app: &AppHandle, mode: &str) -> Result<ConfigBuildOptions, String> {
    let store = settings::settings_store(app)?;
    let proxy_port = store
        .get("proxy_port_key")
        .and_then(|value| value.as_u64())
        .filter(|port| (1..=65535).contains(port))
        .unwrap_or(u64::from(DEFAULT_MIXED_PROXY_PORT)) as u16;
    let cache_name = match mode {
        "mixed" => "mixed-cache-rule-v2.db",
        _ => return Err("invalid_config_mode".to_owned()),
    };
    let cache_path = app
        .path()
        .app_config_dir()
        .map_err(|error| format!("resolve config directory: {error}"))?
        .join(cache_name)
        .to_string_lossy()
        .into_owned();
    Ok(ConfigBuildOptions {
        log_level: "info".to_owned(),
        db_cache_file_path: cache_path,
        clash_api_secret: settings::get_or_create_clash_api_secret_for_app(app)?,
        allow_lan: bool_setting(&store, "allow_lan_key"),
        proxy_port,
        use_dhcp: bool_setting(&store, "use_dhcp_key"),
        direct_dns: string_setting(&store, "direct_dns").unwrap_or_else(|| "223.5.5.5".to_owned()),
        custom_rules: Some(CustomRules {
            direct: custom_rule_setting(&store, "direct"),
            proxy: custom_rule_setting(&store, "proxy"),
        }),
        managed_cn_rule_sets: rule_sets::ensure_cn_rule_set_baseline(app)?,
    })
}

impl CustomRules {
    fn for_action(&self, action: &str) -> &RuleSet {
        match action {
            "direct" => &self.direct,
            "proxy" => &self.proxy,
            _ => unreachable!("fixed action list"),
        }
    }
}

fn object_mut<'a>(value: &'a mut Value, name: &str) -> Result<&'a mut Map<String, Value>, String> {
    value
        .as_object_mut()
        .ok_or_else(|| format!("template_{name}_missing"))
}

fn array_mut<'a>(
    object: &'a mut Map<String, Value>,
    name: &str,
) -> Result<&'a mut Vec<Value>, String> {
    object
        .get_mut(name)
        .and_then(Value::as_array_mut)
        .ok_or_else(|| format!("template_{name}_missing"))
}

fn insert_string(object: &mut Map<String, Value>, key: &str, value: impl Into<String>) {
    object.insert(key.to_owned(), Value::String(value.into()));
}

fn inject_custom_rules(config: &mut Value, custom_rules: Option<&CustomRules>) {
    let Some(rules) = config
        .get_mut("route")
        .and_then(Value::as_object_mut)
        .and_then(|route| route.get_mut("rules"))
        .and_then(Value::as_array_mut)
    else {
        return;
    };

    // Earlier app versions exposed a custom Reject action. Remove its anchored
    // route whenever a config is written, so cached templates and previously
    // generated configs cannot keep blocking traffic after the feature removal.
    rules.retain(|rule| {
        !rule
            .get("domain")
            .and_then(Value::as_array)
            .is_some_and(|domains| {
                domains
                    .iter()
                    .any(|domain| domain.as_str() == Some(LEGACY_REJECT_ANCHOR))
            })
    });

    let Some(custom_rules) = custom_rules else {
        return;
    };

    for (action, anchor) in ACTION_ANCHORS {
        let set = custom_rules.for_action(action);
        if set.domain.is_empty() && set.domain_suffix.is_empty() && set.ip_cidr.is_empty() {
            continue;
        }
        let Some(rule) = rules.iter_mut().find(|rule| {
            rule.get("domain")
                .and_then(Value::as_array)
                .is_some_and(|domains| domains.iter().any(|domain| domain.as_str() == Some(anchor)))
        }) else {
            continue;
        };
        let Some(rule) = rule.as_object_mut() else {
            continue;
        };
        append_strings(rule, "domain", &set.domain);
        append_strings(rule, "domain_suffix", &set.domain_suffix);
        let valid_cidrs = set
            .ip_cidr
            .iter()
            .filter(|value| settings::is_valid_ip_cidr(value))
            .cloned()
            .collect::<Vec<_>>();
        append_strings(rule, "ip_cidr", &valid_cidrs);
    }
}

fn append_strings(rule: &mut Map<String, Value>, field: &str, values: &[String]) {
    if values.is_empty() {
        return;
    }
    let target = rule
        .entry(field.to_owned())
        .or_insert_with(|| Value::Array(Vec::new()));
    if let Some(target) = target.as_array_mut() {
        target.extend(values.iter().cloned().map(Value::String));
    }
}

fn configure_runtime(config: &mut Value, options: &ConfigBuildOptions) -> Result<(), String> {
    let root = object_mut(config, "root")?;
    let log = root
        .get_mut("log")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| "template_log_missing".to_owned())?;
    insert_string(log, "level", &options.log_level);

    let experimental = root
        .get_mut("experimental")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| "template_experimental_missing".to_owned())?;
    experimental.insert(
        "clash_api".to_owned(),
        serde_json::json!({
            "external_controller": format!("127.0.0.1:{CLASH_API_PORT}"),
            "secret": options.clash_api_secret,
        }),
    );
    experimental.insert(
        "cache_file".to_owned(),
        serde_json::json!({
            "enabled": true,
            "store_fakeip": true,
            "store_rdrc": true,
            "path": options.db_cache_file_path,
        }),
    );

    let inbounds = array_mut(root, "inbounds")?;
    if let Some(inbound) = inbounds.iter_mut().find(|inbound| {
        inbound.get("type").and_then(Value::as_str) == Some("mixed")
            && inbound.get("tag").and_then(Value::as_str) == Some("mixed")
    }) {
        let inbound = inbound
            .as_object_mut()
            .ok_or_else(|| "template_mixed_inbound_invalid".to_owned())?;
        insert_string(
            inbound,
            "listen",
            if options.allow_lan {
                "0.0.0.0"
            } else {
                "127.0.0.1"
            },
        );
        inbound.insert("listen_port".to_owned(), Value::from(options.proxy_port));
    }

    let dns = root
        .get_mut("dns")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| "template_dns_missing".to_owned())?;
    let servers = array_mut(dns, "servers")?;
    for server in servers
        .iter_mut()
        .filter(|server| server.get("tag").and_then(Value::as_str) == Some("system"))
    {
        let server = server
            .as_object_mut()
            .ok_or_else(|| "template_system_dns_invalid".to_owned())?;
        if options.use_dhcp {
            insert_string(server, "type", "dhcp");
            server.remove("server");
            server.remove("server_port");
        } else {
            insert_string(server, "type", "udp");
            insert_string(server, "server", options.direct_dns.trim());
            server.insert("server_port".to_owned(), Value::from(53));
        }
    }
    let _ = rule_sets::inject_managed_cn_rule_sets(config, &options.managed_cn_rule_sets);
    Ok(())
}

fn runtime_node_tag(identifier: &str, original_tag: &str) -> String {
    format!("{RUNTIME_NODE_TAG_PREFIX}{identifier}:{original_tag}")
}

fn subscription_nodes(
    subscription: &SubscriptionConfigForBuild,
) -> Result<Vec<(String, Value)>, String> {
    let subscription_outbounds = subscription
        .config
        .get("outbounds")
        .and_then(Value::as_array)
        .ok_or_else(|| "subscription_config_missing".to_owned())?;
    let mut tag_map = std::collections::HashMap::<String, String>::new();

    for outbound in subscription_outbounds {
        let Some(node) = outbound.as_object() else {
            continue;
        };
        let Some(node_type) = node.get("type").and_then(Value::as_str) else {
            continue;
        };
        if matches!(
            node_type,
            "selector" | "urltest" | "direct" | "block" | "dns"
        ) {
            continue;
        }
        let Some(tag) = node
            .get("tag")
            .and_then(Value::as_str)
            .filter(|tag| !tag.is_empty())
        else {
            log::warn!("Skipping subscription outbound without a non-empty tag");
            continue;
        };
        tag_map
            .entry(tag.to_owned())
            .or_insert_with(|| runtime_node_tag(&subscription.identifier, tag));
    }

    let mut seen_original_tags = HashSet::new();
    let mut nodes = Vec::new();
    for outbound in subscription_outbounds {
        let Some(mut node) = outbound.as_object().cloned() else {
            continue;
        };
        let Some(original_tag) = node
            .get("tag")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
        else {
            continue;
        };
        let Some(runtime_tag) = tag_map.get(&original_tag).cloned() else {
            continue;
        };
        if !seen_original_tags.insert(original_tag.clone()) {
            log::warn!(
                "Skipping duplicate outbound tag in subscription {}: {}",
                subscription.identifier,
                original_tag
            );
            continue;
        }
        insert_string(&mut node, "tag", &runtime_tag);
        if let Some(detour) = node.get("detour").and_then(Value::as_str) {
            if let Some(runtime_detour) = tag_map.get(detour) {
                insert_string(&mut node, "detour", runtime_detour);
            }
        }
        insert_string(&mut node, "domain_resolver", "system");
        nodes.push((runtime_tag, Value::Object(node)));
    }
    Ok(nodes)
}

fn merge_subscription_pool(
    config: &mut Value,
    subscriptions: &[SubscriptionConfigForBuild],
    selected_identifier: &str,
) -> Result<(), String> {
    let root = object_mut(config, "root")?;
    let outbounds = array_mut(root, "outbounds")?;
    let exit_gateway = outbounds
        .iter_mut()
        .find(|outbound| {
            outbound.get("type").and_then(Value::as_str) == Some("selector")
                && outbound.get("tag").and_then(Value::as_str) == Some("ExitGateway")
        })
        .ok_or_else(|| "template_exit_gateway_missing".to_owned())?;
    let exit_gateway = exit_gateway
        .as_object_mut()
        .ok_or_else(|| "template_exit_gateway_invalid".to_owned())?;
    let selected = exit_gateway
        .entry("outbounds".to_owned())
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
        .ok_or_else(|| "template_exit_gateway_outbounds_invalid".to_owned())?;

    let mut ordered = subscriptions.iter().collect::<Vec<_>>();
    ordered.sort_by_key(|item| item.identifier != selected_identifier);
    let mut seen_identifiers = HashSet::new();
    let mut nodes = Vec::new();
    for subscription in ordered {
        if !seen_identifiers.insert(subscription.identifier.as_str()) {
            continue;
        }
        match subscription_nodes(subscription) {
            Ok(subscription_nodes) => nodes.extend(subscription_nodes),
            Err(error) => log::warn!(
                "Skipping invalid stored subscription {}: {}",
                subscription.identifier,
                error
            ),
        }
    }
    if nodes.is_empty() {
        return Err("subscription_no_usable_nodes".to_owned());
    }
    selected.extend(nodes.iter().map(|(tag, _)| Value::String(tag.clone())));
    outbounds.extend(nodes.into_iter().map(|(_, node)| node));
    Ok(())
}

#[cfg(test)]
pub(crate) fn prepare_config(
    template_config: Value,
    subscription_config: Value,
    options: &ConfigBuildOptions,
) -> Result<Value, String> {
    let subscriptions = [SubscriptionConfigForBuild {
        identifier: "selected".to_owned(),
        config: subscription_config,
    }];
    prepare_config_pool(template_config, &subscriptions, "selected", options)
}

pub(crate) fn prepare_config_pool(
    mut template_config: Value,
    subscription_configs: &[SubscriptionConfigForBuild],
    selected_identifier: &str,
    options: &ConfigBuildOptions,
) -> Result<Value, String> {
    configure_runtime(&mut template_config, options)?;
    inject_custom_rules(&mut template_config, options.custom_rules.as_ref());
    merge_subscription_pool(
        &mut template_config,
        subscription_configs,
        selected_identifier,
    )?;
    Ok(template_config)
}

/// Write a complete configuration and, when the engine is already running,
/// reload it under the native lifecycle gate.  This closes the renderer-side
/// gap where another UI action could reload sing-box between a file write and
/// a subsequent `reload_config` invoke.
#[tauri::command]
pub async fn prepare_write_and_reload_config(
    app: AppHandle,
    file_name: String,
    template_config: Value,
    selected_identifier: String,
    mode: String,
    reload_if_running: bool,
) -> Result<(), String> {
    let options = build_options_from_settings(&app, &mode)?;
    let secret = options.clash_api_secret.clone();
    let subscription_configs = subscription::subscription_configs_for_build(&app).await?;
    let config = prepare_config_pool(
        template_config,
        &subscription_configs,
        &selected_identifier,
        &options,
    )?;
    let bytes = serde_json::to_vec(&config).map_err(|e| format!("serialize configuration: {e}"))?;
    let dir = app
        .path()
        .app_config_dir()
        .map_err(|e| format!("resolve config directory: {e}"))?;
    write_atomically(&dir, &file_name, &bytes)?;

    if reload_if_running && crate::core::is_running(app.clone(), secret).await {
        crate::core::reload_config(app).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn options() -> ConfigBuildOptions {
        ConfigBuildOptions {
            log_level: "info".into(),
            db_cache_file_path: "/tmp/cache.db".into(),
            clash_api_secret: "secret".into(),
            allow_lan: false,
            proxy_port: 7890,
            use_dhcp: false,
            direct_dns: " 119.29.29.29 ".into(),
            custom_rules: Some(CustomRules {
                direct: RuleSet {
                    domain: vec!["example.cn".into()],
                    ip_cidr: vec!["10.0.0.0/8".into(), "10.240.31.0/255".into()],
                    ..Default::default()
                },
                proxy: RuleSet {
                    domain_suffix: vec![".example.com".into()],
                    ..Default::default()
                },
            }),
            managed_cn_rule_sets: rule_sets::ManagedCnRuleSetPaths {
                geoip_cn: "/tmp/geoip-cn.srs".into(),
                geosite_cn: "/tmp/geosite-cn.srs".into(),
            },
        }
    }

    fn template() -> Value {
        serde_json::json!({
            "log": {}, "experimental": {},
            "inbounds": [{"type":"mixed", "tag":"mixed"}],
            "dns": {"servers": [{"tag":"system", "type":"dhcp"}]},
            "outbounds": [{"type":"direct", "tag":"direct"}, {"type":"selector", "tag":"ExitGateway", "outbounds":[]}],
            "route": {"rule_set": [
                {"tag":"geoip-cn", "type":"remote"},
                {"tag":"geosite-cn", "type":"remote"}
            ], "rules": [
                {"domain":["reject-tag.nekopilot.invalid", "legacy.example"], "action":"reject"},
                {"domain":["direct-tag.nekopilot.invalid"]},
                {"domain":["proxy-tag.nekopilot.invalid"]},
                {"rule_set":["geoip-cn", "geosite-cn"], "outbound":"direct"}
            ]}
        })
    }

    #[test]
    fn merges_runtime_settings_nodes_and_custom_rules() {
        let subscription = serde_json::json!({"outbounds":[
            {"type":"vless", "tag":"node-a"},
            {"type":"vless", "tag":"node-a"},
            {"type":"vless", "tag":"direct"},
            {"type":"urltest", "tag":"skip"}
        ]});
        let config = prepare_config(template(), subscription, &options()).unwrap();
        assert_eq!(config["dns"]["servers"][0]["server"], "119.29.29.29");
        assert_eq!(config["inbounds"][0]["listen"], "127.0.0.1");
        assert_eq!(
            config["outbounds"][1]["outbounds"],
            serde_json::json!(["@np:selected:node-a", "@np:selected:direct"])
        );
        assert_eq!(config["outbounds"][2]["domain_resolver"], "system");
        assert_eq!(
            config["route"]["rules"][0]["domain"],
            serde_json::json!(["direct-tag.nekopilot.invalid", "example.cn"])
        );
        assert_eq!(
            config["route"]["rules"][0]["ip_cidr"],
            serde_json::json!(["10.0.0.0/8"])
        );
        assert_eq!(
            config["route"]["rules"][1]["domain_suffix"],
            serde_json::json!([".example.com"])
        );
        assert_eq!(config["route"]["rules"].as_array().unwrap().len(), 3);
        assert_eq!(
            config["route"]["rules"][2]["rule_set"],
            serde_json::json!(["geoip-cn", "geosite-cn"])
        );
        assert_eq!(config["route"]["rule_set"][0]["type"], "local");
        assert_eq!(config["route"]["rule_set"][1]["path"], "/tmp/geosite-cn.srs");
    }

    #[test]
    fn rejects_a_subscription_without_a_usable_node() {
        let subscription = serde_json::json!({"outbounds":[
            {"type":"direct", "tag":"direct"},
            {"type":"selector", "tag":"ExitGateway"}
        ]});
        assert_eq!(
            prepare_config(template(), subscription, &options()).unwrap_err(),
            "subscription_no_usable_nodes",
        );
    }

    #[test]
    fn merges_every_subscription_and_orders_the_selected_pool_first() {
        let subscriptions = vec![
            SubscriptionConfigForBuild {
                identifier: "airport-a".into(),
                config: serde_json::json!({"outbounds":[
                    {"type":"vless", "tag":"same-name"}
                ]}),
            },
            SubscriptionConfigForBuild {
                identifier: "local-b".into(),
                config: serde_json::json!({"outbounds":[
                    {"type":"anytls", "tag":"same-name"}
                ]}),
            },
        ];
        let config =
            prepare_config_pool(template(), &subscriptions, "local-b", &options()).unwrap();

        assert_eq!(
            config["outbounds"][1]["outbounds"],
            serde_json::json!(["@np:local-b:same-name", "@np:airport-a:same-name"])
        );
        assert_eq!(config["outbounds"][2]["type"], "anytls");
        assert_eq!(config["outbounds"][3]["type"], "vless");
    }
}
