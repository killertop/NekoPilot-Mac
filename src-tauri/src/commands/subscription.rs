//! Transactional subscription repository.
//!
//! The webview fetches remote subscriptions, while this module owns all
//! persistence. Keeping the database boundary in
//! Rust means a failed import can never leave metadata and config rows out of
//! sync, and renderer code no longer issues SQL directly.

use std::{collections::HashMap, path::PathBuf, str::FromStr, time::Duration};

use base64::{engine::general_purpose, Engine as _};
use percent_encoding::percent_decode_str;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sqlx::{
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous},
    FromRow, SqlitePool,
};
use tauri::{AppHandle, Manager};
use tokio::sync::OnceCell;
use url::Url;

use super::config_fetch;

const DEFAULT_OFFICIAL_WEBSITE: &str = "https://sing-box.net";
const LOCAL_PROXY_LINK_EXPIRE_TIME: i64 = 32_503_680_000_000;

const CREATE_SUBSCRIPTIONS: &str = r#"
CREATE TABLE IF NOT EXISTS subscriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    identifier TEXT NOT NULL UNIQUE,
    name TEXT,
    used_traffic INTEGER DEFAULT 0,
    total_traffic INTEGER DEFAULT 1,
    subscription_url TEXT,
    official_website TEXT,
    expire_time INTEGER DEFAULT (strftime('%s', 'now', '+30 days')),
    last_update_time INTEGER DEFAULT (strftime('%s', 'now')),
    source_type TEXT NOT NULL DEFAULT 'subscription'
)
"#;

const CREATE_SUBSCRIPTION_CONFIGS: &str = r#"
CREATE TABLE IF NOT EXISTS subscription_configs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    identifier TEXT NOT NULL,
    config_content TEXT,
    FOREIGN KEY (identifier) REFERENCES subscriptions(identifier) ON DELETE CASCADE
)
"#;

static DATABASE_POOL: OnceCell<SqlitePool> = OnceCell::const_new();

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct SubscriptionRecord {
    pub id: i64,
    pub identifier: String,
    pub name: Option<String>,
    pub used_traffic: i64,
    pub total_traffic: i64,
    pub subscription_url: Option<String>,
    pub official_website: Option<String>,
    pub expire_time: i64,
    pub last_update_time: i64,
    pub source_type: String,
}

#[derive(Debug, Clone)]
pub(crate) struct SubscriptionConfigForBuild {
    pub identifier: String,
    pub config: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubscriptionUpsert {
    pub url: String,
    pub name: Option<String>,
    pub official_website: Option<String>,
    pub used_traffic: i64,
    pub total_traffic: i64,
    pub expire_time: i64,
    pub last_update_time: i64,
    pub config: Value,
    #[serde(default)]
    pub source_type: Option<String>,
}

fn database_path(app: &AppHandle) -> Result<PathBuf, String> {
    app.path()
        .app_config_dir()
        .map(|dir| dir.join("data.db"))
        .map_err(|error| format!("resolve subscription database: {error}"))
}

fn valid_official_website(value: &str) -> bool {
    let Ok(url) = Url::parse(value.trim()) else {
        return false;
    };
    matches!(url.scheme(), "http" | "https") && url.host_str().is_some()
}

async fn database_at_path(path: &std::path::Path) -> Result<SqlitePool, String> {
    let options = SqliteConnectOptions::from_str(
        path.to_str()
            .ok_or_else(|| "subscription database path is not valid UTF-8".to_owned())?,
    )
    .map_err(|error| format!("open subscription database options: {error}"))?
    .create_if_missing(true)
    .foreign_keys(true)
    // The UI can issue a selection/store update while an import transaction
    // is committing. WAL plus a short busy wait prevents needless "database
    // is locked" failures without making a background page consume CPU.
    .journal_mode(SqliteJournalMode::Wal)
    .synchronous(SqliteSynchronous::Normal)
    .busy_timeout(Duration::from_secs(5));
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(|error| format!("open subscription database: {error}"))?;
    sqlx::query(CREATE_SUBSCRIPTIONS)
        .execute(&pool)
        .await
        .map_err(|error| format!("create subscriptions table: {error}"))?;
    sqlx::query(CREATE_SUBSCRIPTION_CONFIGS)
        .execute(&pool)
        .await
        .map_err(|error| format!("create subscription configs table: {error}"))?;
    // Existing OneBox databases predate `source_type`. Keep the migration
    // idempotent because a user can update from any older release directly.
    if let Err(error) = sqlx::query(
        "ALTER TABLE subscriptions ADD COLUMN source_type TEXT NOT NULL DEFAULT 'subscription'",
    )
    .execute(&pool)
    .await
    {
        if !error.to_string().contains("duplicate column name") {
            return Err(format!("add subscription source type: {error}"));
        }
    }

    // Normalize legacy databases before enforcing the invariants used by the
    // current upsert path. Keeping only the newest row matches the historical
    // read order and prevents duplicate node pools from increasing build time.
    let mut migration = pool
        .begin()
        .await
        .map_err(|error| format!("begin subscription migration: {error}"))?;
    sqlx::query(
        "DELETE FROM subscriptions WHERE subscription_url IS NOT NULL AND id NOT IN (SELECT MAX(id) FROM subscriptions WHERE subscription_url IS NOT NULL GROUP BY subscription_url)",
    )
    .execute(&mut *migration)
    .await
    .map_err(|error| format!("deduplicate legacy subscriptions: {error}"))?;
    sqlx::query(
        "DELETE FROM subscription_configs WHERE identifier NOT IN (SELECT identifier FROM subscriptions)",
    )
    .execute(&mut *migration)
    .await
    .map_err(|error| format!("remove orphaned subscription configs: {error}"))?;
    sqlx::query(
        "DELETE FROM subscription_configs WHERE id NOT IN (SELECT MAX(id) FROM subscription_configs GROUP BY identifier)",
    )
    .execute(&mut *migration)
    .await
    .map_err(|error| format!("deduplicate legacy subscription configs: {error}"))?;
    sqlx::query(
        "CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_url_unique ON subscriptions(subscription_url) WHERE subscription_url IS NOT NULL",
    )
    .execute(&mut *migration)
    .await
    .map_err(|error| format!("index subscription URLs: {error}"))?;
    sqlx::query(
        "CREATE UNIQUE INDEX IF NOT EXISTS subscription_configs_identifier_unique ON subscription_configs(identifier)",
    )
    .execute(&mut *migration)
    .await
    .map_err(|error| format!("index subscription configs: {error}"))?;
    migration
        .commit()
        .await
        .map_err(|error| format!("commit subscription migration: {error}"))?;
    Ok(pool)
}

async fn database(app: &AppHandle) -> Result<SqlitePool, String> {
    let path = database_path(app)?;
    let pool = DATABASE_POOL
        .get_or_try_init(|| async { database_at_path(&path).await })
        .await?;
    Ok(pool.clone())
}

pub fn has_usable_node(config: &Value) -> bool {
    const NON_NODE_TYPES: [&str; 5] = ["selector", "urltest", "direct", "block", "dns"];
    config
        .get("outbounds")
        .and_then(Value::as_array)
        .is_some_and(|outbounds| {
            outbounds.iter().any(|outbound| {
                outbound
                    .get("tag")
                    .and_then(Value::as_str)
                    .is_some_and(|tag| !tag.trim().is_empty())
                    && outbound
                        .get("type")
                        .and_then(Value::as_str)
                        .is_some_and(|kind| !NON_NODE_TYPES.contains(&kind))
            })
        })
}

#[derive(Debug)]
struct ParsedProxyLink {
    tag: String,
    outbound: Value,
}

fn link_parameters(url: &Url) -> HashMap<String, String> {
    url.query_pairs()
        .map(|(key, value)| (key.into_owned(), value.into_owned()))
        .collect()
}

fn nonempty(value: Option<&String>) -> Option<&str> {
    value
        .map(String::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn node_tag(protocol: &str, label: Option<&str>, server: &str) -> String {
    let label = label
        .map(str::trim)
        .filter(|label| !label.is_empty())
        .unwrap_or(server);
    // Prefixing the user-provided name avoids collisions with template tags
    // such as `direct` and `ExitGateway`.
    format!(
        "{} · {}",
        protocol.to_ascii_uppercase(),
        label.chars().take(96).collect::<String>()
    )
}

fn decoded_fragment(url: &Url) -> Option<String> {
    let fragment = url.fragment()?.trim();
    if fragment.is_empty() {
        return None;
    }
    percent_decode_str(fragment)
        .decode_utf8()
        .ok()
        .map(|value| value.into_owned())
}

fn decoded_uri_component(value: &str) -> Result<String, String> {
    percent_decode_str(value)
        .decode_utf8()
        .map(|value| value.into_owned())
        .map_err(|_| "invalid_proxy_link".to_owned())
}

fn add_tls(
    outbound: &mut Map<String, Value>,
    params: &HashMap<String, String>,
    server: &str,
    default_tls: bool,
) -> Result<(), String> {
    let security =
        nonempty(params.get("security")).unwrap_or(if default_tls { "tls" } else { "none" });
    if !matches!(security, "tls" | "reality") {
        return Ok(());
    }
    let mut tls = Map::new();
    tls.insert("enabled".into(), Value::Bool(true));
    let server_name = nonempty(params.get("sni")).unwrap_or(server);
    // AnyTLS specifies that an IP address must not be sent as SNI. The same
    // safeguard is correct for the other TLS-backed outbound protocols too.
    if server_name.parse::<std::net::IpAddr>().is_err() {
        tls.insert("server_name".into(), Value::String(server_name.to_owned()));
    }
    if matches!(
        nonempty(params.get("insecure")).or_else(|| nonempty(params.get("allowInsecure"))),
        Some("1" | "true")
    ) {
        tls.insert("insecure".into(), Value::Bool(true));
    }
    if let Some(alpn) = nonempty(params.get("alpn")) {
        let values: Vec<Value> = alpn
            .split(',')
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| Value::String(value.to_owned()))
            .collect();
        if !values.is_empty() {
            tls.insert("alpn".into(), Value::Array(values));
        }
    }
    if let Some(fingerprint) = nonempty(params.get("fp")) {
        tls.insert(
            "utls".into(),
            serde_json::json!({"enabled": true, "fingerprint": fingerprint}),
        );
    }
    if security == "reality" {
        let public_key = nonempty(params.get("pbk"))
            .ok_or_else(|| "proxy_link_missing_reality_public_key".to_owned())?;
        let mut reality = Map::new();
        reality.insert("enabled".into(), Value::Bool(true));
        reality.insert("public_key".into(), Value::String(public_key.to_owned()));
        if let Some(short_id) = nonempty(params.get("sid")) {
            reality.insert("short_id".into(), Value::String(short_id.to_owned()));
        }
        tls.insert("reality".into(), Value::Object(reality));
    }
    outbound.insert("tls".into(), Value::Object(tls));
    Ok(())
}

fn add_transport(outbound: &mut Map<String, Value>, params: &HashMap<String, String>) {
    let transport_type = nonempty(params.get("type")).unwrap_or("tcp");
    let path = nonempty(params.get("path")).unwrap_or("/");
    let host = nonempty(params.get("host"))
        .and_then(|value| value.split(',').next())
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let transport = match transport_type {
        "ws" | "websocket" => {
            let mut transport = serde_json::json!({"type": "ws", "path": path});
            if let Some(host) = host {
                transport["headers"] = serde_json::json!({"Host": host});
            }
            Some(transport)
        }
        "grpc" => Some(serde_json::json!({
            "type": "grpc",
            "service_name": nonempty(params.get("serviceName")).unwrap_or_default(),
        })),
        "httpupgrade" => Some(serde_json::json!({
            "type": "httpupgrade",
            "path": path,
            "host": host.unwrap_or_default(),
        })),
        _ => None,
    };
    if let Some(transport) = transport {
        outbound.insert("transport".into(), transport);
    }
}

fn parse_vless_or_trojan(link: &str, protocol: &str) -> Result<ParsedProxyLink, String> {
    let url = Url::parse(link).map_err(|_| "invalid_proxy_link".to_owned())?;
    let server = url.host_str().ok_or("proxy_link_missing_server")?;
    let server_port = url.port().ok_or("proxy_link_missing_port")?;
    let credential = decoded_uri_component(url.username().trim())?;
    if credential.is_empty() {
        return Err("proxy_link_missing_credential".to_owned());
    }
    let params = link_parameters(&url);
    let label = decoded_fragment(&url);
    let tag = node_tag(protocol, label.as_deref(), server);
    let mut outbound = Map::new();
    outbound.insert("type".into(), Value::String(protocol.to_owned()));
    outbound.insert("tag".into(), Value::String(tag.clone()));
    outbound.insert("server".into(), Value::String(server.to_owned()));
    outbound.insert("server_port".into(), Value::from(server_port));
    if protocol == "vless" {
        outbound.insert("uuid".into(), Value::String(credential.clone()));
        if let Some(flow) = nonempty(params.get("flow")) {
            outbound.insert("flow".into(), Value::String(flow.to_owned()));
        }
        if let Some(packet_encoding) = nonempty(params.get("packetEncoding")) {
            outbound.insert(
                "packet_encoding".into(),
                Value::String(packet_encoding.to_owned()),
            );
        }
        add_tls(&mut outbound, &params, server, false)?;
    } else {
        outbound.insert("password".into(), Value::String(credential));
        add_tls(&mut outbound, &params, server, true)?;
    }
    add_transport(&mut outbound, &params);
    Ok(ParsedProxyLink {
        tag,
        outbound: Value::Object(outbound),
    })
}

fn parse_anytls(link: &str) -> Result<ParsedProxyLink, String> {
    let url = Url::parse(link).map_err(|_| "invalid_proxy_link".to_owned())?;
    let server = url.host_str().ok_or("proxy_link_missing_server")?;
    // AnyTLS URI defines 443 as the default port when it is omitted.
    let server_port = url.port().unwrap_or(443);
    let password = decoded_uri_component(url.username().trim())?;
    if password.is_empty() {
        return Err("proxy_link_missing_credential".to_owned());
    }
    let mut params = link_parameters(&url);
    // AnyTLS is always TLS-backed. Ignore a foreign `security=none` query
    // rather than importing a node that cannot connect.
    params.insert("security".to_owned(), "tls".to_owned());
    let label = decoded_fragment(&url);
    let tag = node_tag("anytls", label.as_deref(), server);
    let mut outbound = Map::new();
    outbound.insert("type".into(), Value::String("anytls".to_owned()));
    outbound.insert("tag".into(), Value::String(tag.clone()));
    outbound.insert("server".into(), Value::String(server.to_owned()));
    outbound.insert("server_port".into(), Value::from(server_port));
    outbound.insert("password".into(), Value::String(password));
    add_tls(&mut outbound, &params, server, true)?;
    Ok(ParsedProxyLink {
        tag,
        outbound: Value::Object(outbound),
    })
}

fn decode_base64_text(encoded: &str, error: &str) -> Result<String, String> {
    let encoded = encoded
        .chars()
        .filter(|character| !character.is_ascii_whitespace())
        .collect::<String>();
    let decoded = general_purpose::URL_SAFE_NO_PAD
        .decode(&encoded)
        .or_else(|_| general_purpose::URL_SAFE.decode(&encoded))
        .or_else(|_| general_purpose::STANDARD_NO_PAD.decode(&encoded))
        .or_else(|_| general_purpose::STANDARD.decode(&encoded))
        .map_err(|_| error.to_owned())?;
    String::from_utf8(decoded).map_err(|_| error.to_owned())
}

pub(crate) fn decode_subscription_payload(body: &[u8]) -> Result<Value, String> {
    if let Ok(json) = serde_json::from_slice::<Value>(body) {
        return Ok(json);
    }

    let text = std::str::from_utf8(body)
        .map(str::trim)
        .map_err(|_| "subscription_response_invalid_format".to_owned())?;
    if text.is_empty() {
        return Err("subscription_response_invalid_format".to_owned());
    }
    let contains_plain_link = text.lines().any(|line| line.trim().contains("://"));
    let links = if contains_plain_link {
        text.to_owned()
    } else {
        decode_base64_text(text, "subscription_response_invalid_format")?
    };

    let mut outbounds = Vec::new();
    for line in links.lines().map(str::trim).filter(|line| !line.is_empty()) {
        match parse_proxy_link(line) {
            Ok(parsed) => outbounds.push(parsed.outbound),
            Err(error) => {
                let scheme = line
                    .split_once("://")
                    .map(|(scheme, _)| scheme)
                    .unwrap_or("?");
                log::warn!("Skipping unsupported subscription node scheme={scheme}: {error}");
            }
        }
    }
    if outbounds.is_empty() {
        return Err("subscription_no_usable_nodes".to_owned());
    }
    Ok(serde_json::json!({ "outbounds": outbounds }))
}

fn parse_shadowsocks(link: &str) -> Result<ParsedProxyLink, String> {
    let url = Url::parse(link).map_err(|_| "invalid_proxy_link".to_owned())?;
    let params = link_parameters(&url);
    if nonempty(params.get("plugin")).is_some() {
        // sing-box plugins require protocol-specific translation. Refuse to
        // save a node that would later fail at connect time.
        return Err("unsupported_shadowsocks_plugin".to_owned());
    }
    let server = url.host_str().ok_or("proxy_link_missing_server")?;
    let server_port = url.port().ok_or("proxy_link_missing_port")?;
    let username = decoded_uri_component(url.username().trim())?;
    if username.is_empty() {
        return Err("proxy_link_missing_credential".to_owned());
    }
    let (method, password) = if let Some(password) = url.password() {
        (username, decoded_uri_component(password)?)
    } else {
        let credentials = decode_base64_text(&username, "invalid_proxy_link")?;
        let (method, password) = credentials
            .split_once(':')
            .ok_or("proxy_link_missing_credential")?;
        (method.to_owned(), password.to_owned())
    };
    if method.trim().is_empty() || password.trim().is_empty() {
        return Err("proxy_link_missing_credential".to_owned());
    }
    let label = decoded_fragment(&url);
    let tag = node_tag("shadowsocks", label.as_deref(), server);
    Ok(ParsedProxyLink {
        tag: tag.clone(),
        outbound: serde_json::json!({
            "type": "shadowsocks",
            "tag": tag,
            "server": server,
            "server_port": server_port,
            "method": method,
            "password": password,
        }),
    })
}

fn decode_vmess_payload(encoded: &str) -> Result<Value, String> {
    let decoded = decode_base64_text(encoded, "invalid_vmess_link")?;
    serde_json::from_str(&decoded).map_err(|_| "invalid_vmess_link".to_owned())
}

fn vmess_field<'a>(payload: &'a Value, key: &str) -> Option<&'a str> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn parse_vmess(link: &str) -> Result<ParsedProxyLink, String> {
    let encoded = link.strip_prefix("vmess://").ok_or("invalid_vmess_link")?;
    let payload = decode_vmess_payload(encoded)?;
    let server = vmess_field(&payload, "add").ok_or("proxy_link_missing_server")?;
    let server_port = vmess_field(&payload, "port")
        .and_then(|port| port.parse::<u16>().ok())
        .ok_or("proxy_link_missing_port")?;
    let uuid = vmess_field(&payload, "id").ok_or("proxy_link_missing_credential")?;
    let tag = node_tag("vmess", vmess_field(&payload, "ps"), server);
    let mut params = HashMap::new();
    for (source, target) in [
        ("net", "type"),
        ("host", "host"),
        ("path", "path"),
        ("tls", "security"),
        ("sni", "sni"),
        ("alpn", "alpn"),
        ("fp", "fp"),
    ] {
        if let Some(value) = vmess_field(&payload, source) {
            params.insert(target.to_owned(), value.to_owned());
        }
    }
    let mut outbound = serde_json::json!({
        "type": "vmess",
        "tag": tag,
        "server": server,
        "server_port": server_port,
        "uuid": uuid,
        "security": vmess_field(&payload, "scy").unwrap_or("auto"),
    })
    .as_object()
    .cloned()
    .ok_or("invalid_vmess_link")?;
    if let Some(alter_id) = vmess_field(&payload, "aid").and_then(|value| value.parse::<u16>().ok())
    {
        outbound.insert("alter_id".into(), Value::from(alter_id));
    }
    add_tls(&mut outbound, &params, server, false)?;
    add_transport(&mut outbound, &params);
    Ok(ParsedProxyLink {
        tag,
        outbound: Value::Object(outbound),
    })
}

fn parse_proxy_link(link: &str) -> Result<ParsedProxyLink, String> {
    let link = link.trim();
    let scheme = link
        .split_once("://")
        .map(|(scheme, _)| scheme.to_ascii_lowercase());
    match scheme.as_deref() {
        Some("vless") => parse_vless_or_trojan(link, "vless"),
        Some("trojan") => parse_vless_or_trojan(link, "trojan"),
        Some("anytls") => parse_anytls(link),
        Some("vmess") => parse_vmess(link),
        Some("ss") => parse_shadowsocks(link),
        _ => Err("unsupported_proxy_link".to_owned()),
    }
}

#[tauri::command]
pub async fn list_subscriptions(app: AppHandle) -> Result<Vec<SubscriptionRecord>, String> {
    let pool = database(&app).await?;
    sqlx::query_as::<_, SubscriptionRecord>(
        "SELECT id, identifier, name, used_traffic, total_traffic, subscription_url, official_website, expire_time, last_update_time, source_type FROM subscriptions ORDER BY id DESC",
    )
    .fetch_all(&pool)
    .await
    .map_err(|error| format!("list subscriptions: {error}"))
}

async fn upsert_into_database(
    pool: &SqlitePool,
    subscription: SubscriptionUpsert,
) -> Result<String, String> {
    let url = subscription.url.trim();
    if url.is_empty() {
        return Err("subscription_url_empty".to_owned());
    }
    if !has_usable_node(&subscription.config) {
        return Err("subscription_no_usable_nodes".to_owned());
    }
    let config_content = serde_json::to_string(&subscription.config)
        .map_err(|error| format!("serialize subscription config: {error}"))?;
    let name = subscription
        .name
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let source_type = match subscription.source_type.as_deref() {
        Some("local_link") => "local_link",
        _ => "subscription",
    };
    let official_website = subscription
        .official_website
        .as_deref()
        .map(str::trim)
        .filter(|value| valid_official_website(value))
        .map(str::to_owned)
        .or_else(|| (source_type == "subscription").then(|| DEFAULT_OFFICIAL_WEBSITE.to_owned()));
    let mut transaction = pool
        .begin()
        .await
        .map_err(|error| format!("begin subscription transaction: {error}"))?;

    // Older releases allowed duplicate URLs. Collapse them in the same
    // transaction before updating the surviving, newest record.
    let existing = sqlx::query_scalar::<_, String>(
        "SELECT identifier FROM subscriptions WHERE subscription_url = ? ORDER BY id DESC LIMIT 1",
    )
    .bind(url)
    .fetch_optional(&mut *transaction)
    .await
    .map_err(|error| format!("find subscription: {error}"))?;

    let identifier = if let Some(identifier) = existing {
        sqlx::query("DELETE FROM subscriptions WHERE subscription_url = ? AND identifier != ?")
            .bind(url)
            .bind(&identifier)
            .execute(&mut *transaction)
            .await
            .map_err(|error| format!("deduplicate subscription: {error}"))?;
        if let Some(name) = name {
            sqlx::query(
                "UPDATE subscriptions SET name = ?, official_website = ?, used_traffic = ?, total_traffic = ?, expire_time = ?, last_update_time = ?, source_type = ? WHERE identifier = ?",
            )
            .bind(name)
            .bind(official_website.as_deref())
            .bind(subscription.used_traffic)
            .bind(subscription.total_traffic)
            .bind(subscription.expire_time)
            .bind(subscription.last_update_time)
            .bind(source_type)
            .bind(&identifier)
            .execute(&mut *transaction)
            .await
            .map_err(|error| format!("update subscription: {error}"))?;
        } else {
            sqlx::query(
                "UPDATE subscriptions SET official_website = ?, used_traffic = ?, total_traffic = ?, expire_time = ?, last_update_time = ?, source_type = ? WHERE identifier = ?",
            )
            .bind(official_website.as_deref())
            .bind(subscription.used_traffic)
            .bind(subscription.total_traffic)
            .bind(subscription.expire_time)
            .bind(subscription.last_update_time)
            .bind(source_type)
            .bind(&identifier)
            .execute(&mut *transaction)
            .await
            .map_err(|error| format!("update subscription: {error}"))?;
        }
        sqlx::query("DELETE FROM subscription_configs WHERE identifier = ?")
            .bind(&identifier)
            .execute(&mut *transaction)
            .await
            .map_err(|error| format!("replace subscription config: {error}"))?;
        identifier
    } else {
        let identifier = uuid::Uuid::new_v4().simple().to_string();
        sqlx::query(
            "INSERT INTO subscriptions (identifier, name, subscription_url, official_website, used_traffic, total_traffic, expire_time, last_update_time, source_type) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&identifier)
        .bind(name.unwrap_or("配置"))
        .bind(url)
        .bind(official_website.as_deref())
        .bind(subscription.used_traffic)
        .bind(subscription.total_traffic)
        .bind(subscription.expire_time)
        .bind(subscription.last_update_time)
        .bind(source_type)
        .execute(&mut *transaction)
        .await
        .map_err(|error| format!("insert subscription: {error}"))?;
        identifier
    };

    sqlx::query("INSERT INTO subscription_configs (identifier, config_content) VALUES (?, ?)")
        .bind(&identifier)
        .bind(config_content)
        .execute(&mut *transaction)
        .await
        .map_err(|error| format!("insert subscription config: {error}"))?;
    transaction
        .commit()
        .await
        .map_err(|error| format!("commit subscription transaction: {error}"))?;
    Ok(identifier)
}

#[tauri::command]
pub async fn upsert_subscription(
    app: AppHandle,
    subscription: SubscriptionUpsert,
) -> Result<String, String> {
    let pool = database(&app).await?;
    upsert_into_database(&pool, subscription).await
}

fn content_disposition_filename(header: Option<&String>) -> Option<String> {
    let header = header?;
    let mut plain_filename = None;
    for field in header.split(';') {
        let Some((key, raw_value)) = field.split_once('=') else {
            continue;
        };
        let key = key.trim().to_ascii_lowercase();
        let raw_value = raw_value.trim().trim_matches('"');
        if raw_value.is_empty() {
            continue;
        }
        if key == "filename*" {
            // RFC 5987: UTF-8''percent-encoded-name
            let encoded = raw_value
                .split_once("''")
                .map(|(_, value)| value)
                .unwrap_or(raw_value);
            if let Ok(value) = percent_decode_str(encoded).decode_utf8() {
                let value = value.trim();
                if !value.is_empty() {
                    return Some(value.to_owned());
                }
            }
        } else if key == "filename" {
            plain_filename = Some(raw_value.to_owned());
        }
    }
    plain_filename
}

fn import_subscription_name(
    name: Option<String>,
    content_disposition: Option<&String>,
) -> Option<String> {
    let name = name.filter(|value| !value.trim().is_empty());
    if matches!(name.as_deref(), Some(value) if value != "默认配置") {
        return name;
    }
    content_disposition_filename(content_disposition).or(Some("配置".to_owned()))
}

fn parse_subscription_userinfo(header: Option<&String>) -> (i64, i64) {
    let Some(header) = header else {
        return (0, 0);
    };
    let mut values = HashMap::new();
    for item in header.split(';') {
        let Some((key, value)) = item.split_once('=') else {
            continue;
        };
        if let Ok(value) = value.trim().parse::<u64>() {
            values.insert(key.trim(), value.min(i64::MAX as u64) as i64);
        }
    }
    let used = values
        .get("upload")
        .copied()
        .unwrap_or_default()
        .saturating_add(values.get("download").copied().unwrap_or_default());
    (used, values.get("total").copied().unwrap_or_default())
}

fn subscription_expiry_millis(header: Option<&String>) -> i64 {
    header
        .and_then(|header| {
            header.split(';').find_map(|item| {
                let (key, value) = item.split_once('=')?;
                (key.trim() == "expire")
                    .then(|| value.trim().parse::<i64>().ok())
                    .flatten()
            })
        })
        .unwrap_or_default()
        .saturating_mul(1_000)
}

/// Imports a remote subscription entirely in Rust. This keeps potentially
/// large subscription JSON in the native process instead of serializing it
/// through the WebView just to persist it in SQLite.
#[tauri::command]
pub async fn import_subscription(
    app: AppHandle,
    url: String,
    name: Option<String>,
    user_agent: String,
) -> Result<String, String> {
    let fetched = config_fetch::fetch_subscription_config(&app, &url, &user_agent).await?;
    if fetched.status != 200 {
        return Err("subscription_no_usable_nodes".to_owned());
    }
    let config = fetched
        .data
        .ok_or_else(|| "subscription_no_usable_nodes".to_owned())?;
    if !has_usable_node(&config) {
        return Err("subscription_no_usable_nodes".to_owned());
    }
    let (used_traffic, total_traffic) =
        parse_subscription_userinfo(fetched.headers.get("subscription-userinfo"));
    let pool = database(&app).await?;
    upsert_into_database(
        &pool,
        SubscriptionUpsert {
            url,
            name: import_subscription_name(name, fetched.headers.get("content-disposition")),
            official_website: fetched.headers.get("official-website").cloned(),
            used_traffic,
            total_traffic,
            expire_time: subscription_expiry_millis(fetched.headers.get("subscription-userinfo")),
            last_update_time: chrono::Utc::now().timestamp_millis(),
            config,
            source_type: Some("subscription".to_owned()),
        },
    )
    .await
}

/// Refreshes a remote subscription entirely in Rust.  The renderer receives
/// only completion/failure, never the potentially large subscription JSON.
#[tauri::command]
pub async fn refresh_subscription(
    app: AppHandle,
    identifier: String,
    user_agent: String,
) -> Result<String, String> {
    let pool = database(&app).await?;
    let (url, source_type): (Option<String>, String) = sqlx::query_as(
        "SELECT subscription_url, source_type FROM subscriptions WHERE identifier = ?",
    )
    .bind(&identifier)
    .fetch_optional(&pool)
    .await
    .map_err(|error| format!("find subscription for refresh: {error}"))?
    .ok_or_else(|| "subscription_not_exist".to_owned())?;
    if source_type != "subscription" {
        return Err("local_subscription_not_updatable".to_owned());
    }
    let url = url.ok_or_else(|| "subscription_url_empty".to_owned())?;
    let fetched = config_fetch::fetch_subscription_config(&app, &url, &user_agent).await?;
    if fetched.status != 200 {
        return Err(format!(
            "subscription_refresh_http_status_{}",
            fetched.status
        ));
    }
    let config = fetched
        .data
        .ok_or_else(|| "subscription_no_usable_nodes".to_owned())?;
    if !has_usable_node(&config) {
        return Err("subscription_no_usable_nodes".to_owned());
    }
    let (used_traffic, total_traffic) =
        parse_subscription_userinfo(fetched.headers.get("subscription-userinfo"));
    let identifier = upsert_into_database(
        &pool,
        SubscriptionUpsert {
            url,
            name: None,
            official_website: fetched.headers.get("official-website").cloned(),
            used_traffic,
            total_traffic,
            expire_time: subscription_expiry_millis(fetched.headers.get("subscription-userinfo")),
            last_update_time: chrono::Utc::now().timestamp_millis(),
            config,
            source_type: Some("subscription".to_owned()),
        },
    )
    .await?;
    Ok(identifier)
}

/// Imports a standalone proxy URI as a local node. Unlike a
/// subscription URL, the URI is parsed entirely on-device and never fetched
/// over HTTP. The stored config has exactly one usable outbound node.
#[tauri::command]
pub async fn import_proxy_link(
    app: AppHandle,
    link: String,
    name: Option<String>,
) -> Result<String, String> {
    let parsed = parse_proxy_link(&link)?;
    let pool = database(&app).await?;
    upsert_into_database(
        &pool,
        SubscriptionUpsert {
            url: link.trim().to_owned(),
            name: name
                .filter(|value| !value.trim().is_empty())
                .or(Some(parsed.tag.clone())),
            official_website: None,
            used_traffic: 0,
            total_traffic: 1,
            expire_time: LOCAL_PROXY_LINK_EXPIRE_TIME,
            last_update_time: chrono::Utc::now().timestamp_millis(),
            config: serde_json::json!({"outbounds": [parsed.outbound]}),
            source_type: Some("local_link".to_owned()),
        },
    )
    .await
}

#[tauri::command]
pub async fn rename_subscription(
    app: AppHandle,
    identifier: String,
    name: String,
) -> Result<(), String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("subscription_name_empty".to_owned());
    }
    let pool = database(&app).await?;
    sqlx::query("UPDATE subscriptions SET name = ? WHERE identifier = ?")
        .bind(name)
        .bind(identifier)
        .execute(&pool)
        .await
        .map_err(|error| format!("rename subscription: {error}"))?;
    Ok(())
}

#[tauri::command]
pub async fn delete_subscription(app: AppHandle, identifier: String) -> Result<(), String> {
    let pool = database(&app).await?;
    let mut transaction = pool
        .begin()
        .await
        .map_err(|error| format!("begin delete subscription: {error}"))?;
    sqlx::query("DELETE FROM subscription_configs WHERE identifier = ?")
        .bind(&identifier)
        .execute(&mut *transaction)
        .await
        .map_err(|error| format!("delete subscription config: {error}"))?;
    sqlx::query("DELETE FROM subscriptions WHERE identifier = ?")
        .bind(identifier)
        .execute(&mut *transaction)
        .await
        .map_err(|error| format!("delete subscription: {error}"))?;
    transaction
        .commit()
        .await
        .map_err(|error| format!("commit delete subscription: {error}"))?;
    Ok(())
}

#[tauri::command]
pub async fn get_subscription_config(app: AppHandle, identifier: String) -> Result<Value, String> {
    let pool = database(&app).await?;
    let raw = sqlx::query_scalar::<_, String>(
        "SELECT config_content FROM subscription_configs WHERE identifier = ? ORDER BY id DESC LIMIT 1",
    )
    .bind(identifier)
    .fetch_optional(&pool)
    .await
    .map_err(|error| format!("get subscription config: {error}"))?
    .ok_or_else(|| "subscription_not_exist".to_owned())?;
    serde_json::from_str(&raw).map_err(|error| format!("parse stored subscription config: {error}"))
}

/// Loads every usable configuration directly inside the native process.
/// Keeping the aggregate node pool out of the WebView avoids serializing a
/// potentially large set of airport nodes through the JavaScript bridge.
pub(crate) async fn subscription_configs_for_build(
    app: &AppHandle,
) -> Result<Vec<SubscriptionConfigForBuild>, String> {
    let pool = database(app).await?;
    let rows = sqlx::query_as::<_, (String, String)>(
        "SELECT subscriptions.identifier, subscription_configs.config_content \
         FROM subscriptions \
         INNER JOIN subscription_configs \
           ON subscription_configs.identifier = subscriptions.identifier \
         ORDER BY subscriptions.id DESC, subscription_configs.id DESC",
    )
    .fetch_all(&pool)
    .await
    .map_err(|error| format!("list subscription configs: {error}"))?;

    let mut configs = Vec::with_capacity(rows.len());
    for (identifier, raw) in rows {
        match serde_json::from_str(&raw) {
            Ok(config) => configs.push(SubscriptionConfigForBuild { identifier, config }),
            Err(error) => {
                log::warn!("Skipping malformed stored subscription config {identifier}: {error}")
            }
        }
    }
    Ok(configs)
}

#[tauri::command]
pub async fn get_subscription_url(app: AppHandle, identifier: String) -> Result<String, String> {
    let pool = database(&app).await?;
    sqlx::query_scalar::<_, String>(
        "SELECT subscription_url FROM subscriptions WHERE identifier = ?",
    )
    .bind(identifier)
    .fetch_optional(&pool)
    .await
    .map_err(|error| format!("get subscription url: {error}"))?
    .ok_or_else(|| "subscription_not_exist".to_owned())
}

#[cfg(test)]
mod tests {
    use base64::{engine::general_purpose, Engine as _};

    use super::{
        content_disposition_filename, database_at_path, decode_subscription_payload,
        has_usable_node, import_subscription_name, parse_proxy_link, parse_subscription_userinfo,
        subscription_expiry_millis, upsert_into_database, valid_official_website,
        SubscriptionUpsert,
    };

    #[test]
    fn official_website_accepts_only_http_urls_with_a_host() {
        assert!(valid_official_website("https://example.com/path"));
        assert!(valid_official_website("http://127.0.0.1:8080"));
        assert!(!valid_official_website("javascript:alert(1)"));
        assert!(!valid_official_website("https-not-a-url"));
        assert!(!valid_official_website("file:///tmp/index.html"));
    }

    #[test]
    fn subscription_payload_accepts_json_plain_links_and_base64_links() {
        let json = br#"{"outbounds":[{"type":"vless","tag":"JSON"}]}"#;
        assert_eq!(
            decode_subscription_payload(json).unwrap()["outbounds"][0]["tag"],
            "JSON"
        );

        let link =
            "vless://00000000-0000-0000-0000-000000000001@example.com:443?security=tls#Tokyo";
        let plain = decode_subscription_payload(link.as_bytes()).unwrap();
        assert_eq!(plain["outbounds"].as_array().unwrap().len(), 1);
        assert_eq!(plain["outbounds"][0]["type"], "vless");

        let encoded = general_purpose::STANDARD.encode(format!("unsupported://node\n{link}\n"));
        let decoded = decode_subscription_payload(encoded.as_bytes()).unwrap();
        assert_eq!(decoded["outbounds"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn subscription_payload_rejects_an_all_unsupported_list() {
        let encoded = general_purpose::STANDARD.encode("hysteria2://unsupported.example:443");
        assert_eq!(
            decode_subscription_payload(encoded.as_bytes()),
            Err("subscription_no_usable_nodes".to_owned())
        );
    }

    #[test]
    fn validates_a_real_node_not_a_group() {
        assert!(has_usable_node(
            &serde_json::json!({"outbounds": [{"type":"vless", "tag":"JP"}]})
        ));
        assert!(!has_usable_node(
            &serde_json::json!({"outbounds": [{"type":"selector", "tag":"Proxy"}]})
        ));
        assert!(!has_usable_node(
            &serde_json::json!({"outbounds": [{"type":"vless", "tag":""}]})
        ));
    }

    #[test]
    fn parses_remote_subscription_metadata_without_js_number_rounding() {
        let header = "upload=100; download=200; total=1000; expire=1900000000".to_owned();
        assert_eq!(parse_subscription_userinfo(Some(&header)), (300, 1000));
        assert_eq!(subscription_expiry_millis(Some(&header)), 1_900_000_000_000);
    }

    #[test]
    fn subscription_import_name_preserves_explicit_name_and_decodes_remote_filename() {
        let header = "attachment; filename*=UTF-8''NekoPilot%20Nodes".to_owned();
        assert_eq!(
            content_disposition_filename(Some(&header)),
            Some("NekoPilot Nodes".to_owned())
        );
        assert_eq!(
            import_subscription_name(Some("My nodes".to_owned()), Some(&header)),
            Some("My nodes".to_owned())
        );
        assert_eq!(
            import_subscription_name(None, Some(&header)),
            Some("NekoPilot Nodes".to_owned())
        );
    }

    #[test]
    fn parses_vless_reality_and_websocket_links() {
        let parsed = parse_proxy_link(
            "vless://8f5c8f1b-1111-2222-3333-123456789abc@example.com:443?encryption=none&security=reality&sni=example.com&fp=chrome&pbk=public-key&sid=abcd&type=ws&host=cdn.example.com&path=%2Fedge#Tokyo",
        )
        .unwrap();
        assert_eq!(parsed.outbound["type"], "vless");
        assert_eq!(parsed.outbound["server"], "example.com");
        assert_eq!(
            parsed.outbound["tls"]["reality"]["public_key"],
            "public-key"
        );
        assert_eq!(parsed.outbound["transport"]["type"], "ws");
        assert_eq!(parsed.tag, "VLESS · Tokyo");
        assert_eq!(
            parsed.outbound["transport"]["headers"]["Host"],
            "cdn.example.com"
        );
        assert_eq!(
            parse_proxy_link("vless://id@example.com:443?security=reality").unwrap_err(),
            "proxy_link_missing_reality_public_key",
        );
    }

    #[test]
    fn parses_trojan_and_vmess_links() {
        let trojan =
            parse_proxy_link("trojan://secret@example.com:443?sni=example.com#Trojan").unwrap();
        assert_eq!(trojan.outbound["type"], "trojan");
        assert_eq!(trojan.outbound["tls"]["enabled"], true);

        let encoded =
            parse_proxy_link("trojan://p%40ss%3Aword@example.com:443?sni=example.com#Hong%20Kong")
                .unwrap();
        assert_eq!(encoded.tag, "TROJAN · Hong Kong");
        assert_eq!(encoded.outbound["password"], "p@ss:word");

        let vmess_payload = base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            br#"{"v":"2","ps":"VMess","add":"example.com","port":"443","id":"8f5c8f1b-1111-2222-3333-123456789abc","aid":"0","scy":"auto","net":"ws","host":"cdn.example.com","path":"/edge","tls":"tls","sni":"example.com"}"#,
        );
        let vmess = parse_proxy_link(&format!("vmess://{vmess_payload}")).unwrap();
        assert_eq!(vmess.outbound["type"], "vmess");
        assert_eq!(vmess.outbound["transport"]["path"], "/edge");
    }

    #[test]
    fn parses_anytls_links_with_standard_tls_parameters() {
        let parsed = parse_proxy_link(
            "anytls://test-password@134.195.209.158:443?insecure=1&allowInsecure=1#Test%20AnyTLS",
        )
        .unwrap();
        assert_eq!(parsed.tag, "ANYTLS · Test AnyTLS");
        assert_eq!(parsed.outbound["type"], "anytls");
        assert_eq!(parsed.outbound["server"], "134.195.209.158");
        assert_eq!(parsed.outbound["server_port"], 443);
        assert_eq!(parsed.outbound["password"], "test-password");
        assert_eq!(parsed.outbound["tls"]["enabled"], true);
        assert_eq!(parsed.outbound["tls"]["insecure"], true);
        assert!(parsed.outbound["tls"].get("server_name").is_none());

        let default_port =
            parse_proxy_link("anytls://password@example.com?sni=edge.example.com").unwrap();
        assert_eq!(default_port.outbound["server_port"], 443);
        assert_eq!(
            default_port.outbound["tls"]["server_name"],
            "edge.example.com"
        );
        let encoded_password = parse_proxy_link("anytls://p%40ss@example.com#Hong%20Kong").unwrap();
        assert_eq!(encoded_password.tag, "ANYTLS · Hong Kong");
        assert_eq!(encoded_password.outbound["password"], "p@ss");
    }

    #[test]
    fn parses_shadowsocks_sip002_link() {
        let parsed =
            parse_proxy_link("ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@example.com:443#Tokyo").unwrap();
        assert_eq!(parsed.outbound["type"], "shadowsocks");
        assert_eq!(parsed.outbound["method"], "aes-256-gcm");
        assert_eq!(parsed.outbound["password"], "password");
        assert_eq!(parsed.outbound["server"], "example.com");
    }

    #[test]
    fn initializes_the_native_subscription_schema() {
        tauri::async_runtime::block_on(async {
            let dir = tempfile::tempdir().unwrap();
            let pool = database_at_path(&dir.path().join("data.db")).await.unwrap();
            let tables: Vec<String> = sqlx::query_scalar(
                "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
            )
            .fetch_all(&pool)
            .await
            .unwrap();
            assert!(tables.iter().any(|table| table == "subscriptions"));
            assert!(tables.iter().any(|table| table == "subscription_configs"));
            pool.close().await;
        });
    }

    #[test]
    fn schema_enforces_one_subscription_and_config_per_source() {
        tauri::async_runtime::block_on(async {
            let dir = tempfile::tempdir().unwrap();
            let pool = database_at_path(&dir.path().join("data.db")).await.unwrap();
            sqlx::query(
                "INSERT INTO subscriptions (identifier, subscription_url) VALUES ('first', 'https://example.com/sub')",
            )
            .execute(&pool)
            .await
            .unwrap();
            assert!(sqlx::query(
                "INSERT INTO subscriptions (identifier, subscription_url) VALUES ('second', 'https://example.com/sub')",
            )
            .execute(&pool)
            .await
            .is_err());

            sqlx::query(
                "INSERT INTO subscription_configs (identifier, config_content) VALUES ('first', '{}')",
            )
            .execute(&pool)
            .await
            .unwrap();
            assert!(sqlx::query(
                "INSERT INTO subscription_configs (identifier, config_content) VALUES ('first', '{}')",
            )
            .execute(&pool)
            .await
            .is_err());
            pool.close().await;
        });
    }

    #[test]
    fn upsert_is_transactional_and_preserves_name_on_refresh() {
        tauri::async_runtime::block_on(async {
            let dir = tempfile::tempdir().unwrap();
            let pool = database_at_path(&dir.path().join("data.db")).await.unwrap();
            let first = SubscriptionUpsert {
                url: "https://example.com/sub".into(),
                name: Some("Original".into()),
                official_website: None,
                used_traffic: 1,
                total_traffic: 10,
                expire_time: 100,
                last_update_time: 1000,
                config: serde_json::json!({"outbounds":[{"type":"vless","tag":"first"}]}),
                source_type: None,
            };
            let identifier = upsert_into_database(&pool, first).await.unwrap();
            let refreshed = SubscriptionUpsert {
                url: "https://example.com/sub".into(),
                name: None,
                official_website: Some("https://example.com".into()),
                used_traffic: 2,
                total_traffic: 20,
                expire_time: 200,
                last_update_time: 2000,
                config: serde_json::json!({"outbounds":[{"type":"vless","tag":"second"}]}),
                source_type: None,
            };
            assert_eq!(
                upsert_into_database(&pool, refreshed).await.unwrap(),
                identifier
            );
            let row: (String, i64, String) = sqlx::query_as(
                "SELECT name, used_traffic, (SELECT config_content FROM subscription_configs WHERE identifier = subscriptions.identifier) FROM subscriptions WHERE identifier = ?",
            )
            .bind(&identifier)
            .fetch_one(&pool)
            .await
            .unwrap();
            assert_eq!(row.0, "Original");
            assert_eq!(row.1, 2);
            assert!(row.2.contains("second"));
            pool.close().await;
        });
    }
}
