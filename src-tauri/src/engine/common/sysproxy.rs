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

#[cfg(target_os = "macos")]
use tauri::Manager;
use tauri::{AppHandle, Emitter};

#[cfg(target_os = "macos")]
use std::path::{Path, PathBuf};
#[cfg(target_os = "macos")]
use std::process::Command;
#[cfg(target_os = "macos")]
use std::sync::{Mutex, OnceLock};

use crate::{core::mixed_proxy_port, engine::EVENT_TAURI_LOG};

const PROXY_HOST: &str = "127.0.0.1";
#[cfg(target_os = "macos")]
const PROXY_OWNER_MARKER_FILE: &str = "system-proxy-owner.json";
#[cfg(target_os = "macos")]
const PROXY_OWNER_ID: &str = "dev.nekopilot.desktop";
#[cfg(target_os = "macos")]
const PROXY_OWNER_MARKER_VERSION: u8 = 2;

/// Resolve the same active network service that `set_system_proxy` will use.
///
/// This is deliberately read-only.  After macOS wakes, lifecycle events can
/// arrive before the default route has been recreated; waiting for this lookup
/// avoids stopping a working proxy only to fail while applying it again.
#[cfg(target_os = "macos")]
pub(crate) fn active_macos_proxy_service() -> anyhow::Result<String> {
    onebox_sysproxy_rs::active_network_service().map_err(|error| anyhow::anyhow!(error))
}

// The system proxy is global state. Keep the exact port and durable marker
// path so shutdown never disables another local proxy that merely shares
// 127.0.0.1, while a later process can recover after SIGKILL/power loss.
#[cfg(target_os = "macos")]
#[derive(Debug, Default, PartialEq, Eq)]
struct ManagedProxyOwnership {
    port: Option<u16>,
    marker_path: Option<PathBuf>,
}

#[cfg(target_os = "macos")]
static MANAGED_PROXY_OWNERSHIP: OnceLock<Mutex<ManagedProxyOwnership>> = OnceLock::new();

#[cfg(target_os = "macos")]
fn managed_proxy_ownership() -> &'static Mutex<ManagedProxyOwnership> {
    MANAGED_PROXY_OWNERSHIP.get_or_init(|| Mutex::new(ManagedProxyOwnership::default()))
}

#[cfg(target_os = "macos")]
#[derive(Debug, serde::Deserialize, serde::Serialize, PartialEq, Eq)]
struct ProxyOwnerMarker {
    version: u8,
    owner: String,
    host: String,
    port: u16,
    pid: u32,
    executable: String,
    session_id: String,
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum MarkerProcessIdentity {
    Dead,
    SameExecutable,
    DifferentExecutable,
    Unknown,
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ExistingMarkerAction {
    Reuse,
    Clear,
    Block,
}

#[cfg(target_os = "macos")]
fn proxy_owner_session_id() -> &'static str {
    static SESSION_ID: OnceLock<String> = OnceLock::new();
    SESSION_ID.get_or_init(|| uuid::Uuid::new_v4().to_string())
}

#[cfg(target_os = "macos")]
fn current_executable_identity() -> anyhow::Result<String> {
    let path = std::env::current_exe()
        .map_err(|error| anyhow::anyhow!("resolve current executable: {error}"))?;
    let path = std::fs::canonicalize(&path).unwrap_or(path);
    Ok(path.to_string_lossy().into_owned())
}

#[cfg(target_os = "macos")]
fn proxy_owner_marker_path(app: &AppHandle) -> anyhow::Result<PathBuf> {
    Ok(app
        .path()
        .app_config_dir()
        .map_err(|error| anyhow::anyhow!("resolve proxy marker directory: {error}"))?
        .join(PROXY_OWNER_MARKER_FILE))
}

#[cfg(target_os = "macos")]
fn proxy_owner_marker_valid(marker: &ProxyOwnerMarker) -> bool {
    marker.version == PROXY_OWNER_MARKER_VERSION
        && marker.owner == PROXY_OWNER_ID
        && marker.host == PROXY_HOST
        && marker.port != 0
        && marker.pid != 0
        && Path::new(&marker.executable).is_absolute()
        && marker.executable.len() <= 3072
        && uuid::Uuid::parse_str(&marker.session_id).is_ok()
}

#[cfg(target_os = "macos")]
fn read_proxy_owner_marker(path: &Path) -> anyhow::Result<Option<ProxyOwnerMarker>> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(anyhow::anyhow!("read proxy ownership marker: {error}")),
    };
    if bytes.len() > 4096 {
        return Err(anyhow::anyhow!("proxy ownership marker is too large"));
    }
    let marker: ProxyOwnerMarker = serde_json::from_slice(&bytes)
        .map_err(|error| anyhow::anyhow!("parse proxy ownership marker: {error}"))?;
    if !proxy_owner_marker_valid(&marker) {
        return Err(anyhow::anyhow!(
            "proxy ownership marker identity is invalid"
        ));
    }
    Ok(Some(marker))
}

#[cfg(target_os = "macos")]
fn persist_proxy_owner_marker(
    directory: &Path,
    marker: &ProxyOwnerMarker,
) -> anyhow::Result<PathBuf> {
    let bytes = serde_json::to_vec(marker)
        .map_err(|error| anyhow::anyhow!("serialize proxy ownership marker: {error}"))?;
    crate::commands::config_write::write_atomically(directory, PROXY_OWNER_MARKER_FILE, &bytes)
        .map_err(|error| anyhow::anyhow!("persist proxy ownership marker: {error}"))?;
    Ok(directory.join(PROXY_OWNER_MARKER_FILE))
}

#[cfg(target_os = "macos")]
fn remove_proxy_owner_marker(path: &Path) -> anyhow::Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(anyhow::anyhow!("remove proxy ownership marker: {error}")),
    }
    if let Some(directory) = path.parent() {
        if let Ok(file) = std::fs::OpenOptions::new().read(true).open(directory) {
            file.sync_all()
                .map_err(|error| anyhow::anyhow!("sync proxy marker directory: {error}"))?;
        }
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn marker_process_identity(marker: &ProxyOwnerMarker) -> MarkerProcessIdentity {
    if unsafe { libc::kill(marker.pid as i32, 0) } != 0 {
        return match std::io::Error::last_os_error().raw_os_error() {
            Some(libc::ESRCH) => MarkerProcessIdentity::Dead,
            Some(libc::EPERM) => MarkerProcessIdentity::Unknown,
            _ => MarkerProcessIdentity::Unknown,
        };
    }

    let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let length = unsafe {
        libc::proc_pidpath(
            marker.pid as libc::c_int,
            buffer.as_mut_ptr().cast(),
            buffer.len() as u32,
        )
    };
    if length <= 0 {
        return MarkerProcessIdentity::Unknown;
    }
    let length = length as usize;
    let end = buffer[..length]
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(length);
    let actual = PathBuf::from(String::from_utf8_lossy(&buffer[..end]).into_owned());
    let actual = std::fs::canonicalize(&actual).unwrap_or(actual);
    if actual == Path::new(&marker.executable) {
        MarkerProcessIdentity::SameExecutable
    } else {
        MarkerProcessIdentity::DifferentExecutable
    }
}

#[cfg(target_os = "macos")]
fn marker_requires_recovery(
    marker_pid: u32,
    current_pid: u32,
    identity: MarkerProcessIdentity,
) -> bool {
    // A marker already present during this process's setup necessarily came
    // from an earlier run, even in the rare case that macOS recycled its PID.
    marker_pid == current_pid
        || matches!(
            identity,
            MarkerProcessIdentity::Dead | MarkerProcessIdentity::DifferentExecutable
        )
}

#[cfg(target_os = "macos")]
fn existing_marker_action(
    marker: &ProxyOwnerMarker,
    current_pid: u32,
    current_session: &str,
    requested_port: u16,
    identity: MarkerProcessIdentity,
) -> ExistingMarkerAction {
    if marker.session_id == current_session {
        if marker.port == requested_port {
            ExistingMarkerAction::Reuse
        } else {
            ExistingMarkerAction::Clear
        }
    } else if marker_requires_recovery(marker.pid, current_pid, identity) {
        ExistingMarkerAction::Clear
    } else {
        ExistingMarkerAction::Block
    }
}

#[cfg(target_os = "macos")]
fn activate_proxy_ownership(port: u16, marker_path: PathBuf) {
    let mut ownership = managed_proxy_ownership()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    ownership.port = Some(port);
    ownership.marker_path = Some(marker_path);
}

/// Recover a proxy left by a previous NekoPilot process. The private marker
/// proves application ownership; `clear_managed_proxy_port` additionally
/// requires each live macOS proxy setting to still match 127.0.0.1 and the
/// exact recorded port before disabling it.
#[cfg(target_os = "macos")]
pub(crate) fn recover_stale_system_proxy(app: &AppHandle) -> anyhow::Result<bool> {
    let marker_path = proxy_owner_marker_path(app)?;
    let Some(marker) = read_proxy_owner_marker(&marker_path)? else {
        return Ok(false);
    };
    let current_pid = std::process::id();
    let identity = marker_process_identity(&marker);
    if !marker_requires_recovery(marker.pid, current_pid, identity) {
        log::info!(
            "[proxy-recovery] marker pid={} identity={:?}; leaving proxy untouched",
            marker.pid,
            identity
        );
        return Ok(false);
    }

    log::warn!(
        "[proxy-recovery] clearing stale NekoPilot proxy host={} port={} prior_pid={}",
        marker.host,
        marker.port,
        marker.pid
    );
    activate_proxy_ownership(marker.port, marker_path);
    platform_clear_system_proxy()?;
    Ok(true)
}

#[cfg(target_os = "macos")]
fn record_proxy_ownership(app: &AppHandle, port: u16) -> anyhow::Result<()> {
    let directory = app
        .path()
        .app_config_dir()
        .map_err(|error| anyhow::anyhow!("resolve proxy marker directory: {error}"))?;
    let current_pid = std::process::id();
    let current_session = proxy_owner_session_id();
    let current_executable = current_executable_identity()?;

    // Do not overwrite a live marker from another process. A stale marker is
    // cleared first so changing the configured mixed port cannot strand the
    // previous value forever.
    let marker_path = directory.join(PROXY_OWNER_MARKER_FILE);
    if let Some(existing) = read_proxy_owner_marker(&marker_path)? {
        let identity = marker_process_identity(&existing);
        match existing_marker_action(&existing, current_pid, current_session, port, identity) {
            ExistingMarkerAction::Reuse => {}
            ExistingMarkerAction::Clear => {
                activate_proxy_ownership(existing.port, marker_path.clone());
                platform_clear_system_proxy()?;
            }
            ExistingMarkerAction::Block => {
                return Err(anyhow::anyhow!(
                    "system proxy ownership marker pid={} identity={identity:?} is still active or inconclusive",
                    existing.pid
                ));
            }
        }
    }

    let marker = ProxyOwnerMarker {
        version: PROXY_OWNER_MARKER_VERSION,
        owner: PROXY_OWNER_ID.to_owned(),
        host: PROXY_HOST.to_owned(),
        port,
        pid: current_pid,
        executable: current_executable,
        session_id: current_session.to_owned(),
    };
    let marker_path = persist_proxy_owner_marker(&directory, &marker)?;
    activate_proxy_ownership(port, marker_path);
    Ok(())
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
    // Record ownership before applying the multi-step macOS networksetup
    // mutation. The upstream setter can fail after changing only some proxy
    // kinds; persisting afterwards would lose crash-recovery proof.
    #[cfg(target_os = "macos")]
    record_proxy_ownership(app, proxy_port)?;

    // networksetup is synchronous and can take noticeable time while macOS is
    // rebuilding network services after wake. Keep it off Tokio's async
    // workers so state events, tray updates and cancellation remain responsive.
    let apply_result =
        tokio::task::spawn_blocking(move || platform_set_system_proxy(proxy_port, DEFAULT_BYPASS))
            .await
            .map_err(|error| anyhow::anyhow!("join system proxy setup: {error}"))?;
    if let Err(apply_error) = apply_result {
        #[cfg(target_os = "macos")]
        {
            let rollback_result = tokio::task::spawn_blocking(platform_clear_system_proxy)
                .await
                .map_err(|error| anyhow::anyhow!("join system proxy rollback: {error}"))?;
            if let Err(rollback_error) = rollback_result {
                return Err(anyhow::anyhow!(
                    "set system proxy failed: {apply_error}; rollback failed: {rollback_error}"
                ));
            }
        }
        return Err(anyhow::anyhow!("set system proxy failed: {apply_error}"));
    }
    log::info!("Proxy set to {}:{}", PROXY_HOST, proxy_port);
    Ok(())
}

/// Clear whatever proxy was set. On macOS this disables the proxy on every
/// service still pointing at OneBox (handles an interface switch since start);
/// on other platforms it flips the active service's `enable` to false.
pub(crate) async fn clear_system_proxy(app: &AppHandle) -> anyhow::Result<()> {
    let _ = app.emit(EVENT_TAURI_LOG, (0, "Start unset system proxy"));
    let clear_result = tokio::task::spawn_blocking(platform_clear_system_proxy)
        .await
        .map_err(|error| anyhow::anyhow!("join system proxy cleanup: {error}"))?;
    if let Err(e) = clear_result {
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
    clear_owned_proxy_with(
        managed_proxy_ownership(),
        clear_managed_proxy_port,
        remove_proxy_owner_marker,
    )
}

#[cfg(target_os = "macos")]
fn clear_owned_proxy_with(
    managed: &Mutex<ManagedProxyOwnership>,
    clear: impl FnOnce(u16) -> anyhow::Result<()>,
    remove_marker: impl FnOnce(&Path) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    // Keep the ownership lock for the complete clear operation. A concurrent
    // start uses the same port, so comparing only the numeric value after an
    // unlocked networksetup call could accidentally erase the newer start's
    // ownership record.
    let mut current = managed.lock().unwrap_or_else(|error| error.into_inner());
    let (port, marker_path) = match (current.port, current.marker_path.as_deref()) {
        (None, None) => return Ok(()),
        (Some(port), Some(marker_path)) => (port, marker_path),
        _ => {
            return Err(anyhow::anyhow!(
                "incomplete in-memory proxy ownership record"
            ));
        }
    };
    // Preserve the ownership proof until every matching service has been
    // cleared successfully. If networksetup fails during shutdown, the
    // caller can retry instead of seeing `None` and silently leaving a dead
    // system proxy behind.
    clear(port)?;
    remove_marker(marker_path)?;
    *current = ManagedProxyOwnership::default();
    Ok(())
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
    use super::{
        clear_owned_proxy_with, existing_marker_action, marker_requires_recovery,
        persist_proxy_owner_marker, proxy_owner_marker_valid, proxy_settings_match_managed_port,
        ExistingMarkerAction, ManagedProxyOwnership, MarkerProcessIdentity, ProxyOwnerMarker,
        PROXY_HOST, PROXY_OWNER_ID, PROXY_OWNER_MARKER_VERSION,
    };
    use std::path::PathBuf;
    use std::sync::Mutex;

    fn marker(port: u16, pid: u32, session_id: &str) -> ProxyOwnerMarker {
        ProxyOwnerMarker {
            version: PROXY_OWNER_MARKER_VERSION,
            owner: PROXY_OWNER_ID.to_owned(),
            host: PROXY_HOST.to_owned(),
            port,
            pid,
            executable: "/Applications/NekoPilot.app/Contents/MacOS/NekoPilot".to_owned(),
            session_id: session_id.to_owned(),
        }
    }

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

    #[test]
    fn failed_proxy_cleanup_keeps_ownership_for_a_retry() {
        let directory = tempfile::tempdir().unwrap();
        let marker_path = directory.path().join("system-proxy-owner.json");
        std::fs::write(&marker_path, b"marker").unwrap();
        let ownership = Mutex::new(ManagedProxyOwnership {
            port: Some(16789),
            marker_path: Some(marker_path.clone()),
        });
        assert!(clear_owned_proxy_with(
            &ownership,
            |_| Err(anyhow::anyhow!("networksetup failed")),
            |_| Ok(()),
        )
        .is_err());
        assert_eq!(
            *ownership.lock().unwrap(),
            ManagedProxyOwnership {
                port: Some(16789),
                marker_path: Some(marker_path.clone()),
            }
        );
        assert!(marker_path.exists());

        clear_owned_proxy_with(
            &ownership,
            |_| Ok(()),
            |path| {
                std::fs::remove_file(path)?;
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(*ownership.lock().unwrap(), ManagedProxyOwnership::default());
        assert!(!marker_path.exists());
    }

    #[test]
    fn marker_removal_failure_keeps_ownership_for_a_retry() {
        let marker_path = PathBuf::from("/not-removed/system-proxy-owner.json");
        let ownership = Mutex::new(ManagedProxyOwnership {
            port: Some(16789),
            marker_path: Some(marker_path.clone()),
        });
        assert!(clear_owned_proxy_with(
            &ownership,
            |_| Ok(()),
            |_| Err(anyhow::anyhow!("marker removal failed")),
        )
        .is_err());
        assert_eq!(ownership.lock().unwrap().port, Some(16789));
        assert_eq!(
            ownership.lock().unwrap().marker_path.as_ref(),
            Some(&marker_path)
        );
    }

    #[test]
    fn durable_marker_is_private_and_identity_checked() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let marker = marker(16789, 42, "d84d74df-8c21-4bc3-b35b-2683c03e19b3");
        assert!(proxy_owner_marker_valid(&marker));
        let path = persist_proxy_owner_marker(directory.path(), &marker).unwrap();
        let mode = std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        let mut wrong_owner = marker;
        wrong_owner.owner = "other.app".to_owned();
        assert!(!proxy_owner_marker_valid(&wrong_owner));
    }

    #[test]
    fn startup_recovers_only_a_stale_marker() {
        assert!(!marker_requires_recovery(
            41,
            42,
            MarkerProcessIdentity::SameExecutable
        ));
        assert!(!marker_requires_recovery(
            41,
            42,
            MarkerProcessIdentity::Unknown
        ));
        assert!(marker_requires_recovery(
            41,
            42,
            MarkerProcessIdentity::Dead
        ));
        assert!(marker_requires_recovery(
            41,
            42,
            MarkerProcessIdentity::DifferentExecutable
        ));
        // A marker that predates setup is stale even if macOS recycled the
        // old process's PID for this process.
        assert!(marker_requires_recovery(
            42,
            42,
            MarkerProcessIdentity::SameExecutable
        ));
    }

    #[test]
    fn changed_port_clears_old_ownership_before_replacing_marker() {
        let session = "d84d74df-8c21-4bc3-b35b-2683c03e19b3";
        let old = marker(16789, 42, session);
        assert_eq!(
            existing_marker_action(
                &old,
                42,
                session,
                16789,
                MarkerProcessIdentity::SameExecutable,
            ),
            ExistingMarkerAction::Reuse
        );
        assert_eq!(
            existing_marker_action(
                &old,
                42,
                session,
                26789,
                MarkerProcessIdentity::SameExecutable,
            ),
            ExistingMarkerAction::Clear
        );
    }

    #[test]
    fn recycled_pid_is_not_mistaken_for_a_live_nekopilot_owner() {
        let old = marker(16789, 41, "d84d74df-8c21-4bc3-b35b-2683c03e19b3");
        let current_session = "7f839f34-b8d4-4bfd-9d87-bbe759af8e89";
        assert_eq!(
            existing_marker_action(
                &old,
                42,
                current_session,
                16789,
                MarkerProcessIdentity::DifferentExecutable,
            ),
            ExistingMarkerAction::Clear
        );
        assert_eq!(
            existing_marker_action(
                &old,
                42,
                current_session,
                16789,
                MarkerProcessIdentity::SameExecutable,
            ),
            ExistingMarkerAction::Block
        );
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
