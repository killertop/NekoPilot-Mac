//! Cross-platform system HTTP/SOCKS proxy override.
//!
//! All platforms shell through `onebox_sysproxy_rs` — the only thing that
//! varies is the per-OS bypass-list syntax (comma vs semicolon, glob vs CIDR)
//! and the clear strategy. The macOS service-name resolution, exit-status
//! checking, and "disable proxy on every service pointing at us" clear all
//! live in the crate (v0.0.2+), so there is no per-OS networksetup code here.
//!
//! Proxy always points at the Mixed inbound's listen port.
//!
//! `set_*` emits a frontend log line (Windows historically did, macOS
//! and Linux did not — we now do it on all three for symmetry); failure
//! returns `anyhow::Error` so callers can fall through their usual
//! state-machine error path.

use tauri::{AppHandle, Emitter};

#[cfg(target_os = "macos")]
use std::process::Command;
#[cfg(target_os = "macos")]
use std::sync::{Mutex, OnceLock};

use crate::{core::mixed_proxy_port, engine::EVENT_TAURI_LOG};

const PROXY_HOST: &str = "127.0.0.1";

/// Resolve the same active network service that `set_system_proxy` will use.
///
/// This is deliberately read-only.  After macOS wakes, lifecycle events can
/// arrive before the default route has been recreated; waiting for this lookup
/// avoids stopping a working proxy only to fail while applying it again.
#[cfg(target_os = "macos")]
pub(crate) fn active_macos_proxy_service() -> anyhow::Result<String> {
    onebox_sysproxy_rs::active_network_service().map_err(|error| anyhow::anyhow!(error))
}

// The system proxy is global state. Keep the exact port this process applied
// so shutdown never disables another local proxy that merely shares 127.0.0.1.
#[cfg(target_os = "macos")]
static MANAGED_PROXY_PORT: OnceLock<Mutex<Option<u16>>> = OnceLock::new();

#[cfg(target_os = "macos")]
fn managed_proxy_port() -> &'static Mutex<Option<u16>> {
    MANAGED_PROXY_PORT.get_or_init(|| Mutex::new(None))
}

/// Bypass-list syntax differs per platform — see the `onebox_sysproxy_rs`
/// source for exactly how it's parsed. The values below were migrated
/// verbatim from the previous per-platform duplicates.
#[cfg(target_os = "macos")]
const DEFAULT_BYPASS: &str =
    "127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,172.29.0.0/16,localhost,*.local,*.crashlytics.com,<local>";

#[cfg(target_os = "linux")]
const DEFAULT_BYPASS: &str =
    "localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,172.29.0.0/16,::1";

#[cfg(target_os = "windows")]
const DEFAULT_BYPASS: &str = "localhost;127.*;192.168.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;<local>";

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
const DEFAULT_BYPASS: &str = "localhost,127.0.0.1";

/// Apply the HTTP/SOCKS system proxy pointing at the Mixed inbound.
pub(crate) async fn set_system_proxy(app: &AppHandle) -> anyhow::Result<()> {
    let proxy_port = mixed_proxy_port(app);
    let _ = app.emit(
        EVENT_TAURI_LOG,
        (
            0,
            format!("Start set system proxy: {}:{}", PROXY_HOST, proxy_port),
        ),
    );
    platform_set_system_proxy(proxy_port, DEFAULT_BYPASS)?;
    #[cfg(target_os = "macos")]
    {
        *managed_proxy_port()
            .lock()
            .expect("managed proxy port lock") = Some(proxy_port);
    }
    log::info!("Proxy set to {}:{}", PROXY_HOST, proxy_port);
    Ok(())
}

/// Clear whatever proxy was set. On macOS this disables the proxy on every
/// service still pointing at OneBox (handles an interface switch since start);
/// on other platforms it flips the active service's `enable` to false.
pub(crate) async fn clear_system_proxy(app: &AppHandle) -> anyhow::Result<()> {
    let _ = app.emit(EVENT_TAURI_LOG, (0, "Start unset system proxy"));
    if let Err(e) = platform_clear_system_proxy() {
        let msg = format!("clear system proxy failed: {}", e);
        let _ = app.emit(EVENT_TAURI_LOG, (1, msg.clone()));
        return Err(anyhow::anyhow!(msg));
    }
    let _ = app.emit(EVENT_TAURI_LOG, (0, "System proxy unset successfully"));
    log::info!("Proxy unset");
    Ok(())
}

/// Synchronous proxy clear for shutdown / power-off hooks that run outside an
/// async runtime. Routes through the same per-platform clear as the async path
/// — notably the macOS service-name-aware clear — instead of the upstream
/// crate's `get_system_proxy`, which choked on a renamed service during
/// shutdown ("failed to parse string `port`").
pub(crate) fn clear_system_proxy_blocking() -> anyhow::Result<()> {
    platform_clear_system_proxy()
}

/// Apply the proxy on the active service. Cross-platform: macOS service
/// resolution + exit-status checking live in `onebox_sysproxy_rs`, so a failed
/// `networksetup` call now returns an error here instead of being swallowed.
fn platform_set_system_proxy(port: u16, bypass: &str) -> anyhow::Result<()> {
    let sys = onebox_sysproxy_rs::Sysproxy {
        enable: true,
        host: PROXY_HOST.to_string(),
        port,
        bypass: bypass.to_string(),
    };
    sys.set_system_proxy().map_err(|e| anyhow::anyhow!(e))
}

/// macOS: disable the proxy on every service still pointing at OneBox, so a
/// stale proxy isn't left behind if the active interface changed since start.
#[cfg(target_os = "macos")]
fn platform_clear_system_proxy() -> anyhow::Result<()> {
    let port = managed_proxy_port()
        .lock()
        .expect("managed proxy port lock")
        .take();
    let Some(port) = port else {
        return Ok(());
    };
    clear_managed_proxy_port(port)
}

#[cfg(target_os = "macos")]
fn networksetup_output(args: &[&str]) -> anyhow::Result<String> {
    let output = Command::new("networksetup")
        .args(args)
        .output()
        .map_err(|e| anyhow::anyhow!("run networksetup: {e}"))?;
    if !output.status.success() {
        return Err(anyhow::anyhow!(
            "networksetup {:?}: {}",
            args,
            String::from_utf8_lossy(&output.stderr).trim(),
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(target_os = "macos")]
fn proxy_matches_managed_port(proxy: &str, service: &str, port: u16) -> anyhow::Result<bool> {
    let output = networksetup_output(&[proxy, service])?;
    Ok(proxy_settings_match_managed_port(&output, port))
}

#[cfg(target_os = "macos")]
fn proxy_settings_match_managed_port(output: &str, port: u16) -> bool {
    let enabled = output.lines().any(|line| line.trim() == "Enabled: Yes");
    let host = output
        .lines()
        .find_map(|line| line.trim().strip_prefix("Server: "));
    let configured_port = output
        .lines()
        .find_map(|line| line.trim().strip_prefix("Port: "))
        .and_then(|value| value.parse::<u16>().ok());
    enabled && host == Some(PROXY_HOST) && configured_port == Some(port)
}

#[cfg(target_os = "macos")]
fn clear_managed_proxy_port(port: u16) -> anyhow::Result<()> {
    let services = networksetup_output(&["-listallnetworkservices"])?;
    let mut first_error = None;
    for service in services.lines().map(str::trim).filter(|service| {
        !service.is_empty() && !service.starts_with('*') && !service.starts_with("An asterisk")
    }) {
        for (get_command, set_command) in [
            ("-getwebproxy", "-setwebproxystate"),
            ("-getsecurewebproxy", "-setsecurewebproxystate"),
            ("-getsocksfirewallproxy", "-setsocksfirewallproxystate"),
        ] {
            match proxy_matches_managed_port(get_command, service, port) {
                Ok(true) => {
                    if let Err(error) = networksetup_output(&[set_command, service, "off"]) {
                        first_error.get_or_insert(error);
                    }
                }
                Ok(false) => {}
                Err(error) => {
                    first_error.get_or_insert(error);
                }
            }
        }
    }
    first_error.map_or(Ok(()), Err)
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::proxy_settings_match_managed_port;

    #[test]
    fn only_matches_the_proxy_port_owned_by_this_process() {
        let output =
            "Enabled: Yes\nServer: 127.0.0.1\nPort: 6789\nAuthenticated Proxy Enabled: 0\n";
        assert!(proxy_settings_match_managed_port(output, 6789));
        assert!(!proxy_settings_match_managed_port(output, 7890));
        assert!(!proxy_settings_match_managed_port(
            "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n",
            6789,
        ));
        assert!(!proxy_settings_match_managed_port(
            "Enabled: No\nServer: 127.0.0.1\nPort: 6789\n",
            6789,
        ));
    }
}

/// Other platforms: read the current setting and flip `enable` off, keeping any
/// non-proxy fields (bypass list) intact.
#[cfg(not(target_os = "macos"))]
fn platform_clear_system_proxy() -> anyhow::Result<()> {
    let mut sysproxy = onebox_sysproxy_rs::Sysproxy::get_system_proxy()
        .map_err(|e| anyhow::anyhow!("Sysproxy::get_system_proxy failed: {}", e))?;
    sysproxy.enable = false;
    sysproxy
        .set_system_proxy()
        .map_err(|e| anyhow::anyhow!("Sysproxy::set_system_proxy failed: {}", e))
}
