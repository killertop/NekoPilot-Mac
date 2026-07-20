//! Subscription-host SHA256 whitelist — refreshed in the background from
//! sing-box.net and consumed by `config_fetch::verify_domain_sha256`.
//!
//! A compile-time constant list of hashes ships in the binary; at runtime
//! we additionally pull a live list so new hosts can be approved without
//! a client update. The live list is persisted via `tauri-plugin-store`
//! so an offline restart still has the last known whitelist on hand.

use std::collections::HashSet;

use serde_json::json;
use tauri::{AppHandle, Wry};
use tauri_plugin_http::reqwest;
use tauri_plugin_store::StoreExt;

/// Compile-time known-good SHA256 list. Add entries here as hosts are
/// approved in-tree; the remote list is the looser/faster path.
///
/// Each entry is the SHA256 of an approved suffix label (never the full
/// hostname in plaintext). `config_fetch::verify_hostname` enumerates
/// suffix candidates shortest-first and returns true on the first match,
/// so broader entries approve broader subtrees. Never record the
/// pre-image of any entry in this file, other source, or commit history.
pub(crate) const KNOWN_HOST_SHA256_LIST: &[&str] = &[
    "183a5526e76751b07cd57236bc8f253d5424e02a3fc7da7c30f80919e975125a",
    "59fe86216c23236fb4c6ab50cd8d1e261b7cad754e3e7cab33058df5b32d12e1",
    "61e245b4e5c234b00865ab0f47ad1cc4a9b37dbc50159febea7e6dcaee8ce050",
];

const WHITELIST_REMOTE_URL: &str = "https://www.sing-box.net/verified_subscriptions_sha256.txt";
const WHITELIST_STORE_NAME: &str = "whitelist_cache.json";
const WHITELIST_KEY_HASHES: &str = "hashes";
const WHITELIST_KEY_UPDATED_AT: &str = "updated_at";
/// Minimum age (seconds) before the cache is considered stale and re-fetched.
const WHITELIST_TTL_SECS: u64 = 24 * 3600;
/// How often the background task wakes up to check staleness.
const WHITELIST_CHECK_INTERVAL_SECS: u64 = 6 * 3600;
const MAX_WHITELIST_RESPONSE_BYTES: usize = 512 * 1024;
const MAX_WHITELIST_ENTRIES: usize = 4_096;

fn now_unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn is_valid_sha256_hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn normalize_whitelist_hashes<'a>(
    values: impl IntoIterator<Item = &'a str>,
) -> Result<Vec<String>, &'static str> {
    let mut seen = HashSet::new();
    let mut hashes = Vec::new();
    for value in values {
        let value = value.trim();
        if value.is_empty() || value.starts_with('#') {
            continue;
        }
        if !is_valid_sha256_hex(value) {
            return Err("whitelist_invalid_hash");
        }
        if seen.insert(value.to_owned()) {
            if hashes.len() >= MAX_WHITELIST_ENTRIES {
                return Err("whitelist_too_many_entries");
            }
            hashes.push(value.to_owned());
        }
    }
    if hashes.is_empty() {
        return Err("whitelist_empty");
    }
    Ok(hashes)
}

async fn fetch_whitelist_from_remote() -> Option<Vec<String>> {
    let client = match reqwest::ClientBuilder::new()
        .timeout(std::time::Duration::from_secs(10))
        .no_proxy()
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            log::warn!("[WHITELIST] Failed to build HTTP client: {}", e);
            return None;
        }
    };
    match client.get(WHITELIST_REMOTE_URL).send().await {
        Ok(mut resp) if resp.status().is_success() => {
            if resp
                .content_length()
                .is_some_and(|length| length > MAX_WHITELIST_RESPONSE_BYTES as u64)
            {
                log::warn!("[WHITELIST] Remote response is too large");
                return None;
            }
            let mut body = Vec::new();
            loop {
                match resp.chunk().await {
                    Ok(Some(chunk)) => {
                        let Some(next_len) = body.len().checked_add(chunk.len()) else {
                            log::warn!("[WHITELIST] Remote response size overflow");
                            return None;
                        };
                        if next_len > MAX_WHITELIST_RESPONSE_BYTES {
                            log::warn!("[WHITELIST] Remote response exceeded size limit");
                            return None;
                        }
                        body.extend_from_slice(&chunk);
                    }
                    Ok(None) => break,
                    Err(e) => {
                        log::warn!("[WHITELIST] Failed to read response body: {}", e);
                        return None;
                    }
                }
            }
            let text = match std::str::from_utf8(&body) {
                Ok(text) => text,
                Err(_) => {
                    log::warn!("[WHITELIST] Remote response is not UTF-8");
                    return None;
                }
            };
            match normalize_whitelist_hashes(text.lines()) {
                Ok(hashes) => {
                    log::info!("[WHITELIST] Fetched {} entries from remote", hashes.len());
                    Some(hashes)
                }
                Err(error) => {
                    log::warn!("[WHITELIST] Rejected remote response: {error}");
                    None
                }
            }
        }
        Ok(resp) => {
            log::warn!(
                "[WHITELIST] Remote returned unexpected status {}",
                resp.status()
            );
            None
        }
        Err(e) => {
            log::warn!("[WHITELIST] Remote fetch failed: {}", e);
            None
        }
    }
}

fn open_whitelist_store(
    app: &AppHandle<Wry>,
) -> Option<std::sync::Arc<tauri_plugin_store::Store<Wry>>> {
    match app.store(WHITELIST_STORE_NAME) {
        Ok(s) => Some(s),
        Err(e) => {
            log::warn!("[WHITELIST] Failed to open store: {}", e);
            None
        }
    }
}

pub(crate) fn load_whitelist_hashes(app: &AppHandle<Wry>) -> Vec<String> {
    open_whitelist_store(app)
        .and_then(|s| s.get(WHITELIST_KEY_HASHES))
        .and_then(|v| serde_json::from_value::<Vec<String>>(v).ok())
        .and_then(|hashes| normalize_whitelist_hashes(hashes.iter().map(String::as_str)).ok())
        .unwrap_or_default()
}

fn load_whitelist_timestamp(app: &AppHandle<Wry>) -> Option<u64> {
    open_whitelist_store(app)
        .and_then(|s| s.get(WHITELIST_KEY_UPDATED_AT))
        .and_then(|v| v.as_u64())
}

fn save_whitelist_cache(app: &AppHandle<Wry>, hashes: &[String]) {
    let Some(store) = open_whitelist_store(app) else {
        return;
    };
    store.set(WHITELIST_KEY_HASHES, json!(hashes));
    store.set(WHITELIST_KEY_UPDATED_AT, json!(now_unix_secs()));
    if let Err(e) = store.save() {
        log::warn!("[WHITELIST] Failed to persist store to disk: {}", e);
    }
}

async fn refresh_whitelist_if_stale(app: &AppHandle<Wry>) {
    let stale = match load_whitelist_timestamp(app) {
        None => true,
        Some(ts) => whitelist_cache_is_stale(now_unix_secs(), ts),
    };
    if !stale {
        log::debug!("[WHITELIST] Cache is fresh, skipping refresh");
        return;
    }
    log::info!("[WHITELIST] Cache is stale, fetching from remote...");
    match fetch_whitelist_from_remote().await {
        Some(hashes) => save_whitelist_cache(app, &hashes),
        None => log::warn!("[WHITELIST] Remote fetch failed, retaining existing cache"),
    }
}

fn whitelist_cache_is_stale(now: u64, timestamp: u64) -> bool {
    timestamp > now || now - timestamp >= WHITELIST_TTL_SECS
}

/// Call once during app setup. Refreshes the remote whitelist every 24 h
/// via a background loop that wakes every `WHITELIST_CHECK_INTERVAL_SECS`.
pub fn spawn_whitelist_refresh_task(app: AppHandle<Wry>) {
    tauri::async_runtime::spawn(async move {
        loop {
            refresh_whitelist_if_stale(&app).await;
            tokio::time::sleep(std::time::Duration::from_secs(
                WHITELIST_CHECK_INTERVAL_SECS,
            ))
            .await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hash(byte: char) -> String {
        std::iter::repeat_n(byte, 64).collect()
    }

    #[test]
    fn remote_hashes_are_validated_deduplicated_and_nonempty() {
        let a = hash('a');
        let b = hash('b');
        let input = format!("# comment\n{a}\n{a}\n{b}\n");
        assert_eq!(
            normalize_whitelist_hashes(input.lines()).unwrap(),
            vec![a, b]
        );
        assert!(normalize_whitelist_hashes(["", "# comment"]).is_err());
        assert!(normalize_whitelist_hashes([hash('A').as_str()]).is_err());
        assert!(normalize_whitelist_hashes(["xyz"]).is_err());
    }

    #[test]
    fn remote_hash_count_is_bounded() {
        let hashes = (0..=MAX_WHITELIST_ENTRIES)
            .map(|index| format!("{index:064x}"))
            .collect::<Vec<_>>();
        assert!(normalize_whitelist_hashes(hashes.iter().map(String::as_str)).is_err());
    }

    #[test]
    fn future_cache_timestamp_is_treated_as_stale() {
        assert!(whitelist_cache_is_stale(100, 101));
        assert!(!whitelist_cache_is_stale(100, 100));
        assert!(whitelist_cache_is_stale(100 + WHITELIST_TTL_SECS, 100));
    }
}
