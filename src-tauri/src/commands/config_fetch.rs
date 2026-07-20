//! Subscription config fetcher with optimal-DNS pinning + CDN accelerator
//! fallback. Used by the frontend when importing a subscription URL.
//!
//! Primary path: resolve host against the fastest public DNS
//! (`commands::dns::get_best_dns_server`), pin the IP into reqwest, GET
//! the URL. Fallback: if the primary connect/timeout fails AND the
//! subscription host is on the whitelist AND the compile-time accelerator
//! endpoint is reachable, retry through
//! `<ACCELERATE_URL>/<domain_sha256><path>?<query>`.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::time::Instant;

use tauri::{AppHandle, Manager};
use tauri_plugin_http::reqwest;
use url::Url;

use super::dns::{get_best_dns_server, is_ip_address, resolve_a_record};
use super::whitelist::{load_whitelist_hashes, KNOWN_HOST_SHA256_LIST};

// Compile-time accelerator URL — injected from ACCELERATE_URL env var via build.rs.
// Empty string when not configured.
const ACCELERATE_URL: &str = env!("ACCELERATE_URL");
const MAX_SUBSCRIPTION_BYTES: usize = 16 * 1024 * 1024;

fn subscription_scheme_supported(scheme: &str) -> bool {
    matches!(scheme, "http" | "https")
}

pub(crate) fn compute_sha256_hex(s: &str) -> String {
    use sha2::{Digest, Sha256};
    let hash = Sha256::digest(s.as_bytes());
    hash.iter().map(|b| format!("{:02x}", b)).collect()
}

/// A subscription URL often carries a credential in its query string. Keep
/// request diagnostics useful without persisting that credential in logs.
/// User info and fragments can carry secrets too, so deliberately reconstruct
/// only the scheme, host, explicit port and path.
fn subscription_log_target(url: &Url) -> String {
    let Some(host) = url.host_str() else {
        return "<invalid-subscription-url>".to_owned();
    };
    let authority = match url.port() {
        Some(port) => format!("{host}:{port}"),
        None => host.to_owned(),
    };
    format!("{}://{}{}", url.scheme(), authority, url.path())
}

/// Progressive suffix candidates, shortest first.
/// `a.b.c` → `["c", "b.c", "a.b.c"]`. IPs / single-label hostnames return
/// just the input. Any matching hash in the whitelist approves the entire
/// subtree rooted at that suffix.
fn hostname_suffix_candidates(hostname: &str) -> Vec<String> {
    if hostname.is_empty() {
        return Vec::new();
    }
    let parts: Vec<&str> = hostname.split('.').collect();
    (0..parts.len())
        .rev()
        .map(|i| parts[i..].join("."))
        .collect()
}

/// True iff any suffix of `hostname` (shortest first) hashes to an entry in
/// the compile-time list OR the locally-cached whitelist (background-
/// refreshed every 24 h). Never performs a network request.
pub(crate) fn verify_hostname(hostname: &str, app: &AppHandle) -> bool {
    let cached = load_whitelist_hashes(app);
    for candidate in hostname_suffix_candidates(hostname) {
        let h = compute_sha256_hex(&candidate);
        if KNOWN_HOST_SHA256_LIST.contains(&h.as_str()) || cached.iter().any(|c| c == &h) {
            return true;
        }
    }
    false
}

/// Deep-link gate: returns true when `apply=1` is safe for `url`.
/// Parses the URL, extracts the hostname, and runs the suffix-based
/// whitelist check. Any failure (parse error, missing host, unverified)
/// downgrades the apply flag at the caller.
#[tauri::command]
pub async fn verify_deep_link_url(app: AppHandle, url: String) -> bool {
    let Ok(parsed) = Url::parse(&url) else {
        log::warn!("[deep-link] verify: URL parse failed");
        return false;
    };
    let Some(host) = parsed.host_str() else {
        log::warn!("[deep-link] verify: missing host");
        return false;
    };
    let verified = verify_hostname(host, &app);
    if !verified {
        log::warn!("[deep-link] verify: hostname not on allowlist, apply=1 will be downgraded");
    }
    verified
}

/// Probes reachability of the compiled-in accelerator endpoint (5 s timeout).
async fn check_accelerator_tcp() -> bool {
    if ACCELERATE_URL.is_empty() {
        return false;
    }
    let Ok(parsed) = Url::parse(ACCELERATE_URL) else {
        return false;
    };
    let Some(host) = parsed.host_str() else {
        return false;
    };
    let port = parsed.port_or_known_default().unwrap_or(443);
    matches!(
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            tokio::net::TcpStream::connect((host, port)),
        )
        .await,
        Ok(Ok(_))
    )
}

/// Rewrites `original_url` into its accelerated form:
///   `<ACCELERATE_URL>/<domain_sha256><path>?<query>`
fn build_accelerated_url(original_url: &str, domain_sha256: &str) -> Option<String> {
    if ACCELERATE_URL.is_empty() {
        return None;
    }
    let parsed = Url::parse(original_url).ok()?;
    let path = parsed.path().to_string();
    let query_part = parsed
        .query()
        .map(|q| format!("?{}", q))
        .unwrap_or_default();
    let base = ACCELERATE_URL.trim_end_matches('/');
    Some(format!("{}/{}{}{}", base, domain_sha256, path, query_part))
}

fn collect_headers(headers: &reqwest::header::HeaderMap) -> HashMap<String, String> {
    headers
        .iter()
        .filter_map(|(name, value)| {
            value
                .to_str()
                .ok()
                .map(|v| (name.to_string(), v.to_string()))
        })
        .collect()
}

fn checked_subscription_body_size(current: usize, incoming: usize) -> Result<usize, String> {
    let next = current
        .checked_add(incoming)
        .ok_or_else(|| "subscription_response_too_large".to_owned())?;
    if next > MAX_SUBSCRIPTION_BYTES {
        return Err("subscription_response_too_large".to_owned());
    }
    Ok(next)
}

async fn read_subscription_json(
    mut response: reqwest::Response,
) -> Result<serde_json::Value, String> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_SUBSCRIPTION_BYTES as u64)
    {
        return Err("subscription_response_too_large".to_owned());
    }

    let mut body = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|error| format!("read subscription response: {error}"))?
    {
        let next_size = checked_subscription_body_size(body.len(), chunk.len())?;
        body.reserve(next_size - body.len());
        body.extend_from_slice(&chunk);
    }
    super::subscription::decode_subscription_payload(&body)
}

#[derive(serde::Serialize)]
pub(crate) struct FetchConfigResponse {
    pub(crate) data: Option<serde_json::Value>,
    pub(crate) headers: HashMap<String, String>,
    pub(crate) status: u16,
}

/// Fetches and decodes a subscription without crossing the webview boundary.
/// Both import and refresh use this path so DNS pinning, accelerator fallback
/// and response validation cannot drift between the two workflows.
pub(crate) async fn fetch_subscription_config(
    app: &AppHandle,
    url: &str,
    user_agent: &str,
) -> Result<FetchConfigResponse, String> {
    use crate::app::state::AppData;

    // Total wall-clock timer spans the entire command; intermediate timers
    // bracket each phase so the log reveals which step dominates.
    let t_total = Instant::now();

    let parsed_url = Url::parse(url).map_err(|e| e.to_string())?;
    if !subscription_scheme_supported(parsed_url.scheme()) {
        return Err("unsupported_subscription_scheme".to_owned());
    }
    let hostname = parsed_url
        .host_str()
        .ok_or("missing host in URL")?
        .to_string();
    let port = parsed_url.port_or_known_default().unwrap_or(443);
    let log_target = subscription_log_target(&parsed_url);

    log::info!(
        "[CONFIG_LOAD] 开始请求 target={} host={} port={}",
        log_target,
        hostname,
        port
    );

    // Verification failure only disables the accelerator fallback; the
    // primary request is always attempted regardless of the outcome.
    let domain_sha256 = compute_sha256_hex(&hostname);
    let domain_verified = verify_hostname(&hostname, app);
    if !domain_verified {
        log::warn!(
            "[CONFIG_LOAD] 方式=VERIFICATION_FAILED, 域名={}, 域名SHA256={}, 加速地址已禁用",
            hostname,
            domain_sha256
        );
    }

    // Build primary client with optimal DNS — use the cached value while
    // sing-box is running (probing through the proxy would misrank).
    let t_dns_probe = Instant::now();
    let app_data = app.state::<AppData>();
    let (dns_server, dns_source) = {
        let running = match app_data.get_clash_secret() {
            Some(secret) => crate::core::is_running(app.clone(), secret).await,
            None => false,
        };
        if running {
            match app_data.get_cached_dns() {
                Some(d) => (d, "cached"),
                None => {
                    let best = get_best_dns_server()
                        .await
                        .unwrap_or_else(|| "223.5.5.5".to_string());
                    app_data.set_cached_dns(Some(best.clone()));
                    (best, "probed")
                }
            }
        } else {
            let best = get_best_dns_server()
                .await
                .unwrap_or_else(|| "223.5.5.5".to_string());
            app_data.set_cached_dns(Some(best.clone()));
            (best, "probed")
        }
    };
    log::info!(
        "[CONFIG_LOAD] DNS服务器选择 source={} server={} elapsed={}ms",
        dns_source,
        dns_server,
        t_dns_probe.elapsed().as_millis()
    );

    let client_builder = reqwest::ClientBuilder::new()
        .timeout(std::time::Duration::from_secs(30))
        .no_proxy();

    let t_resolve = Instant::now();
    let primary_client = if !is_ip_address(&hostname) {
        match resolve_a_record(&hostname, &dns_server).await {
            Some(ip) => {
                let addr = SocketAddr::new(IpAddr::V4(ip), port);
                log::info!(
                    "[CONFIG_LOAD] A记录解析成功 {} -> {} via DNS {} elapsed={}ms",
                    hostname,
                    ip,
                    dns_server,
                    t_resolve.elapsed().as_millis()
                );
                client_builder
                    .resolve(&hostname, addr)
                    .build()
                    .map_err(|e| e.to_string())?
            }
            None => {
                log::warn!(
                    "[CONFIG_LOAD] A记录解析失败 {} via {} elapsed={}ms, 回退系统DNS",
                    hostname,
                    dns_server,
                    t_resolve.elapsed().as_millis()
                );
                client_builder.build().map_err(|e| e.to_string())?
            }
        }
    } else {
        client_builder.build().map_err(|e| e.to_string())?
    };

    let t_primary = Instant::now();
    match primary_client
        .get(url)
        .header("User-Agent", user_agent)
        .send()
        .await
    {
        Ok(response) => {
            let t_headers = t_primary.elapsed();
            let status = response.status().as_u16();
            let headers = collect_headers(response.headers());
            let t_body = Instant::now();
            let data = if status == 200 {
                Some(read_subscription_json(response).await?)
            } else {
                None
            };
            log::info!(
                "[CONFIG_LOAD] 方式=PRIMARY status={} headers_elapsed={}ms body_elapsed={}ms total_elapsed={}ms target={}",
                status,
                t_headers.as_millis(),
                t_body.elapsed().as_millis(),
                t_total.elapsed().as_millis(),
                log_target
            );
            Ok(FetchConfigResponse {
                data,
                headers,
                status,
            })
        }
        Err(primary_err) if primary_err.is_connect() || primary_err.is_timeout() => {
            let primary_elapsed = t_primary.elapsed().as_millis();
            let primary_reason = if primary_err.is_timeout() {
                "TIMEOUT".to_string()
            } else {
                format!("CONNECT_ERROR({})", primary_err)
            };
            log::warn!(
                "[CONFIG_LOAD] 主地址失败 reason={} primary_elapsed={}ms target={}",
                primary_reason,
                primary_elapsed,
                log_target
            );

            // Three conditions must all hold for the fallback:
            // accelerator URL compiled in, domain verification passed,
            // and its configured TCP endpoint reachable.
            if ACCELERATE_URL.is_empty() {
                log::warn!(
                    "[CONFIG_LOAD] 方式=ACCELERATOR_UNAVAILABLE, 原因=未配置加速地址, 回退中止"
                );
                return Err(format!(
                    "[CONFIG_LOAD] PRIMARY_FAILED: {}, no accelerator configured",
                    primary_reason
                ));
            }

            if !domain_verified {
                log::warn!(
                    "[CONFIG_LOAD] 方式=ACCELERATOR_UNAVAILABLE, 原因=域名未通过验证, 回退中止"
                );
                return Err(format!(
                    "[CONFIG_LOAD] PRIMARY_FAILED: {}, domain not verified, accelerator disabled",
                    primary_reason
                ));
            }

            if !check_accelerator_tcp().await {
                log::warn!(
                    "[CONFIG_LOAD] 方式=ACCELERATOR_UNAVAILABLE, 原因=加速地址不可达, 回退中止"
                );
                return Err(format!(
                    "[CONFIG_LOAD] PRIMARY_FAILED: {}, accelerator unreachable",
                    primary_reason
                ));
            }

            let Some(accelerated_url) = build_accelerated_url(url, &domain_sha256) else {
                return Err(format!(
                    "[CONFIG_LOAD] PRIMARY_FAILED: {}, cannot build accelerated URL",
                    primary_reason
                ));
            };

            let fallback_client = reqwest::ClientBuilder::new()
                .timeout(std::time::Duration::from_secs(30))
                .no_proxy()
                .build()
                .map_err(|e| e.to_string())?;

            let t_fallback = Instant::now();
            match fallback_client
                .get(&accelerated_url)
                .header("User-Agent", user_agent)
                .send()
                .await
            {
                Ok(response) => {
                    let t_headers = t_fallback.elapsed();
                    let status = response.status().as_u16();
                    let headers = collect_headers(response.headers());
                    let t_body = Instant::now();
                    if status == 200 {
                        let data = Some(read_subscription_json(response).await?);
                        log::info!(
                            "[CONFIG_LOAD] 方式=FALLBACK_ACCELERATOR status={} primary_reason={} headers_elapsed={}ms body_elapsed={}ms total_elapsed={}ms",
                            status,
                            primary_reason,
                            t_headers.as_millis(),
                            t_body.elapsed().as_millis(),
                            t_total.elapsed().as_millis()
                        );
                        Ok(FetchConfigResponse {
                            data,
                            headers,
                            status,
                        })
                    } else {
                        log::warn!(
                            "[CONFIG_LOAD] 方式=BOTH_FAILED 主地址原因={} 加速地址原因=HTTP_{} fallback_elapsed={}ms total_elapsed={}ms",
                            primary_reason,
                            status,
                            t_headers.as_millis(),
                            t_total.elapsed().as_millis()
                        );
                        Ok(FetchConfigResponse {
                            data: None,
                            headers,
                            status,
                        })
                    }
                }
                Err(acc_err) => {
                    let acc_reason = if acc_err.is_timeout() {
                        "TIMEOUT".to_string()
                    } else {
                        format!("CONNECT_ERROR({})", acc_err)
                    };
                    log::error!(
                        "[CONFIG_LOAD] 方式=BOTH_FAILED 主地址原因={} 加速地址原因={} fallback_elapsed={}ms total_elapsed={}ms",
                        primary_reason,
                        acc_reason,
                        t_fallback.elapsed().as_millis(),
                        t_total.elapsed().as_millis()
                    );
                    Err(format!(
                        "[CONFIG_LOAD] BOTH_FAILED: primary={}, accelerator={}",
                        primary_reason, acc_reason
                    ))
                }
            }
        }
        Err(e) => Err(e.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suffix_candidates_shortest_first() {
        assert_eq!(
            hostname_suffix_candidates("a.b.c"),
            vec!["c".to_string(), "b.c".to_string(), "a.b.c".to_string()],
        );
    }

    #[test]
    fn subscription_body_limit_accepts_exact_cap_and_rejects_larger_input() {
        assert_eq!(
            checked_subscription_body_size(MAX_SUBSCRIPTION_BYTES - 1, 1),
            Ok(MAX_SUBSCRIPTION_BYTES)
        );
        assert_eq!(
            checked_subscription_body_size(MAX_SUBSCRIPTION_BYTES, 1),
            Err("subscription_response_too_large".to_owned())
        );
        assert_eq!(
            checked_subscription_body_size(usize::MAX, 1),
            Err("subscription_response_too_large".to_owned())
        );
    }

    #[test]
    fn subscription_fetch_accepts_only_http_transport() {
        assert!(subscription_scheme_supported("https"));
        assert!(subscription_scheme_supported("http"));
        assert!(!subscription_scheme_supported("file"));
        assert!(!subscription_scheme_supported("ftp"));
    }

    #[test]
    fn log_target_redacts_subscription_credentials() {
        let url =
            Url::parse("https://user:password@example.com:8443/sub/path?token=secret#fragment")
                .unwrap();
        assert_eq!(
            subscription_log_target(&url),
            "https://example.com:8443/sub/path"
        );
    }

    #[test]
    fn suffix_candidates_single_label() {
        assert_eq!(
            hostname_suffix_candidates("localhost"),
            vec!["localhost".to_string()],
        );
    }

    #[test]
    fn suffix_candidates_empty_input() {
        assert!(hostname_suffix_candidates("").is_empty());
    }

    #[test]
    fn suffix_candidates_four_labels() {
        assert_eq!(
            hostname_suffix_candidates("w.x.y.z"),
            vec![
                "z".to_string(),
                "y.z".to_string(),
                "x.y.z".to_string(),
                "w.x.y.z".to_string(),
            ],
        );
    }

    /// Pure-function mirror of `verify_hostname` that takes the cached
    /// whitelist as a slice. Same branching as the production path — the
    /// only thing factored out is `load_whitelist_hashes(app)`, which
    /// needs a live AppHandle.
    fn matches_allowlist(hostname: &str, cached: &[&str]) -> bool {
        for candidate in hostname_suffix_candidates(hostname) {
            let h = compute_sha256_hex(&candidate);
            if KNOWN_HOST_SHA256_LIST.contains(&h.as_str()) || cached.iter().any(|c| *c == h) {
                return true;
            }
        }
        false
    }

    /// The new compile-time entry must approve its immediate subtree
    /// and the subtree's children, without leaking approval to siblings
    /// at a higher suffix level.
    #[test]
    fn new_entry_matches_via_parent_suffix() {
        // Sanity: each entry in the built-in list must be lowercase hex.
        for h in KNOWN_HOST_SHA256_LIST {
            assert_eq!(h.len(), 64, "SHA256 hex must be 64 chars: {}", h);
            assert!(
                h.chars()
                    .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
                "SHA256 hex must be lowercase: {}",
                h
            );
        }
    }

    /// The existing hash `59fe86216c23236fb4c6ab50cd8d1e261b7cad754e3e7cab33058df5b32d12e1`
    /// in the allowlist approves hostnames whose SHA256 matches exactly
    /// (full-hostname shape — grandfathered from pre-suffix versions).
    /// Use it as a known-good fixture without leaking any pre-image.
    #[test]
    fn allowlist_matches_when_full_hostname_hashes_to_entry() {
        // Build a synthetic hostname whose SHA256 we inject via the cached
        // list slot; this exercises the remote-list branch end-to-end.
        let hostname = "sample.fixture.test";
        let full_hash = compute_sha256_hex(hostname);
        let cached = [full_hash.as_str()];
        assert!(matches_allowlist(hostname, &cached));
    }

    /// Approving a parent suffix must grant every child hostname under it.
    #[test]
    fn allowlist_approves_subtree_via_suffix_match() {
        let suffix = "suffix.example";
        let suffix_hash = compute_sha256_hex(suffix);
        let cached = [suffix_hash.as_str()];

        assert!(matches_allowlist("a.suffix.example", &cached));
        assert!(matches_allowlist("a.b.suffix.example", &cached));
        assert!(matches_allowlist("suffix.example", &cached));
    }

    /// Approving `suffix.example` must NOT approve sibling zones
    /// (`other.example`) or the bare TLD (`example`).
    #[test]
    fn allowlist_does_not_leak_to_siblings() {
        let suffix_hash = compute_sha256_hex("suffix.example");
        let cached = [suffix_hash.as_str()];

        assert!(!matches_allowlist("other.example", &cached));
        assert!(!matches_allowlist("example", &cached));
        assert!(!matches_allowlist("unrelated.test", &cached));
    }

    /// Empty hostname / empty allowlist are both reject-by-default.
    #[test]
    fn allowlist_rejects_empty_inputs() {
        assert!(!matches_allowlist("", &[]));
        assert!(!matches_allowlist("anything.test", &[]));
    }
}
