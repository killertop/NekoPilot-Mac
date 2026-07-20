mod log;
pub(crate) mod monitor;

pub use self::log::cleanup_old_app_logs;

use lazy_static::lazy_static;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Manager};

use crate::app::state::AppData;
use crate::engine::state_machine::{transition, EngineState, EngineStateCell, Intent};
use crate::engine::{readiness, EVENT_STATUS_CHANGED};
use crate::engine::{EngineManager, PlatformEngine};
use tauri::Emitter;
use tauri_plugin_shell::process::CommandChild;

// ── Diagnostics ──────────────────────────────────────────────────────
//
// Lifecycle calls (`start` / `stop` / `reload_config` and the lifecycle-
// driven restart path in `app/setup.rs`) can fire concurrently from
// multiple triggers — user clicks, Wi-Fi switch debounce, watchdog,
// tray toggles. When one of them ends in "mixed port is occupied", the
// only way to tell *which* path collided is if every entry records an
// `action=N` token, plus a snapshot of `ProcessManager` (child PID,
// liveness) and the port listener state. These helpers are the raw
// inputs for that snapshot — cheap, no behaviour change.

/// Monotonic per-process action counter. Prefix lifecycle log lines
/// with `action=N` so overlapping calls from independent triggers can
/// be untangled purely from the log stream.
pub(crate) fn next_action_token() -> u64 {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    COUNTER.fetch_add(1, Ordering::Relaxed)
}

/// NekoPilot's default HTTP/SOCKS mixed inbound. This deliberately avoids
/// common proxy ports such as 7890 and 1080 to reduce collisions with other
/// proxy clients and local development services.
pub(crate) const DEFAULT_MIXED_PROXY_PORT: u16 = 16789;

/// Default Clash API / external-controller port used when the config does not
/// explicitly provide one.  Keep it distinct from OneBox's long-standing
/// 9191 default so both clients can run on the same Mac.
pub(crate) const CLASH_API_PORT: u16 = 19191;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct EnginePorts {
    pub(crate) mixed_proxy: u16,
    pub(crate) clash_api: u16,
}

impl Default for EnginePorts {
    fn default() -> Self {
        Self {
            mixed_proxy: DEFAULT_MIXED_PROXY_PORT,
            clash_api: CLASH_API_PORT,
        }
    }
}

/// Parse the ports sing-box will actually bind from the exact config passed to
/// the engine. This must not assume `appConfigDir/config.json`: tests, manual
/// proxy mode and custom-port users can start a different config file.
pub(crate) fn engine_ports_from_config_path(config_path: &str) -> EnginePorts {
    let Ok(text) = std::fs::read_to_string(config_path) else {
        return EnginePorts::default();
    };
    let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else {
        return EnginePorts::default();
    };
    let mixed_proxy = json
        .get("inbounds")
        .and_then(|v| v.as_array())
        .and_then(|inbounds| {
            inbounds.iter().find_map(|ib| {
                let is_mixed = ib.get("type").and_then(|v| v.as_str()) == Some("mixed")
                    && ib.get("tag").and_then(|v| v.as_str()) == Some("mixed");
                if !is_mixed {
                    return None;
                }
                ib.get("listen_port")
                    .and_then(|v| v.as_u64())
                    .and_then(|port| u16::try_from(port).ok())
                    .filter(|port| *port > 0)
            })
        })
        .unwrap_or(DEFAULT_MIXED_PROXY_PORT);
    let clash_api = json
        .pointer("/experimental/clash_api/external_controller")
        .and_then(|value| value.as_str())
        .and_then(|address| address.rsplit_once(':'))
        .and_then(|(_, port)| port.parse::<u16>().ok())
        .filter(|port| *port > 0)
        .unwrap_or(CLASH_API_PORT);
    EnginePorts {
        mixed_proxy,
        clash_api,
    }
}

fn configured_engine_ports(app: &AppHandle) -> EnginePorts {
    let path = ProcessManager::acquire().config_path.clone();
    if let Some(path) = path {
        return engine_ports_from_config_path(&path);
    }
    let Ok(config_dir) = app.path().app_config_dir() else {
        return EnginePorts::default();
    };
    engine_ports_from_config_path(config_dir.join("config.json").to_string_lossy().as_ref())
}

pub(crate) fn mixed_proxy_port(app: &AppHandle) -> u16 {
    configured_engine_ports(app).mixed_proxy
}

fn canonical_engine_config_path(
    config_dir: &std::path::Path,
    requested_path: &std::path::Path,
) -> Result<std::path::PathBuf, String> {
    let config_dir = std::fs::canonicalize(config_dir)
        .map_err(|error| format!("resolve engine config directory: {error}"))?;
    let expected = config_dir.join("config.json");
    let requested = std::fs::canonicalize(requested_path)
        .map_err(|error| format!("resolve engine config path: {error}"))?;
    if requested != expected || !requested.is_file() {
        return Err("engine_config_path_not_allowed".to_owned());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&requested, std::fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("secure engine config: {error}"))?;
    }
    Ok(requested)
}

fn validate_engine_config_path(app: &AppHandle, path: &str) -> Result<String, String> {
    let config_dir = app
        .path()
        .app_config_dir()
        .map_err(|error| format!("resolve engine config directory: {error}"))?;
    canonical_engine_config_path(&config_dir, std::path::Path::new(path))
        .map(|path| path.to_string_lossy().into_owned())
}

#[tauri::command]
pub fn get_clash_api_port(app: AppHandle) -> u16 {
    configured_engine_ports(&app).clash_api
}

/// Best-effort check: is *something* already listening on
/// 127.0.0.1:<mixed port> right now? A successful connect
/// means the port is bound — used as a pre-flight before spawning a
/// fresh sing-box and as a post-flight after `pkill -HUP` to detect
/// a failed rebind.
pub(crate) fn probe_port_listening(port: u16) -> bool {
    use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream};
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
    TcpStream::connect_timeout(&addr, Duration::from_millis(100)).is_ok()
}

/// `kill(pid, 0)` probe — returns true if the PID still refers to a
/// live process we have permission to signal. Useful to distinguish
/// "ProcessManager still holds a handle but the process is already
/// dead" from "the process is genuinely alive and we're about to
/// spawn on top of it".
#[cfg(unix)]
pub(crate) fn pid_is_alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

#[cfg(not(unix))]
pub(crate) fn pid_is_alive(_pid: u32) -> bool {
    true
}

/// Result of an OS-level process query after a consuming termination call.
/// Ownership can be released only for `Exited`; both an observed live process
/// and an inconclusive query must remain attached to `ProcessManager`.
#[cfg(any(target_os = "windows", test))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ProcessExitObservation {
    Alive,
    Exited,
    Unknown,
}

#[cfg(any(target_os = "windows", test))]
impl ProcessExitObservation {
    pub(crate) fn retains_ownership(self) -> bool {
        !matches!(self, Self::Exited)
    }

    /// `OpenProcess` reports ERROR_INVALID_PARAMETER when the PID no longer
    /// exists. Other failures (notably ACCESS_DENIED) are inconclusive and
    /// must retain ownership.
    pub(crate) fn from_windows_open_failure(pid_no_longer_exists: bool) -> Self {
        if pid_no_longer_exists {
            Self::Exited
        } else {
            Self::Unknown
        }
    }
}

/// True when a failed `kill(pid, SIGTERM)` failed with `ESRCH` — the process
/// is already gone. That is the desired outcome of a stop, not a failure, so
/// callers log it at debug rather than error.
#[cfg(target_os = "linux")]
pub(crate) fn sigterm_target_already_exited(raw_os_error: Option<i32>) -> bool {
    raw_os_error == Some(libc::ESRCH)
}

/// Snapshot of `ProcessManager` for a single log line. `(child_pid,
/// child_pid_alive, mode)`.
fn pm_snapshot() -> (Option<u32>, Option<bool>, Option<ProxyMode>) {
    let mgr = ProcessManager::acquire();
    let pid = mgr
        .child
        .as_ref()
        .map(|child| child.pid())
        .or(mgr.owned_pid);
    let alive = pid.map(pid_is_alive);
    let mode = mgr.mode.as_ref().map(|m| (**m).clone());
    (pid, alive, mode)
}

// ── ProcessManager ────────────────────────────────────────────────────
//
// ProxyMode lives in `engine` since the mode is an engine-level concept;
// this module re-exports it so existing `core::ProxyMode` paths continue
// to work.
pub use crate::engine::ProxyMode;

pub(crate) struct ProcessManager {
    pub(crate) child: Option<CommandChild>,
    /// PID retained independently from `CommandChild`. On Windows the shell
    /// plugin consumes the child handle when `kill()` is called, so this is
    /// the ownership proof that prevents a failed stop from being reset to
    /// Idle while the same process may still be alive.
    pub(crate) owned_pid: Option<u32>,
    pub(crate) mode: Option<Arc<ProxyMode>>,
    pub(crate) config_path: Option<Arc<String>>,
    /// Stable identity of the currently owned engine process. Unlike the
    /// state-machine epoch, this value does not change when Starting becomes
    /// Running or Running becomes Stopping.
    pub(crate) session_epoch: Option<u64>,
    pub(crate) is_stopping: bool,
}

impl ProcessManager {
    /// Lock the global PROCESS_MANAGER, recovering from poison.
    pub(crate) fn acquire() -> std::sync::MutexGuard<'static, ProcessManager> {
        PROCESS_MANAGER.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Reset to idle defaults. Platform engines are expected to have
    /// already torn down their own private state (macOS bypass-router
    /// watchdog, Linux DNS-override stash, …) via `stop` or
    /// `on_process_terminated` before this runs.
    pub(crate) fn reset(&mut self) {
        self.child = None;
        self.owned_pid = None;
        self.mode = None;
        self.config_path = None;
        self.session_epoch = None;
        self.is_stopping = false;
    }
}

lazy_static! {
    pub(crate) static ref PROCESS_MANAGER: Arc<Mutex<ProcessManager>> =
        Arc::new(Mutex::new(ProcessManager {
            child: None,
            owned_pid: None,
            mode: None,
            config_path: None,
            session_epoch: None,
            is_stopping: false,
    }));
    /// Native authority for every engine mutation. Frontend queues cannot
    /// protect lifecycle calls coming from the tray, wake listener, or another
    /// WebView, so start/stop/reload and automatic restart serialize here.
    static ref LIFECYCLE_GATE: tokio::sync::Mutex<()> = tokio::sync::Mutex::new(());
}

// ── Start-time port guard ─────────────────────────────────────────────

/// Ports that must be free before spawning sing-box: the mixed proxy port and
/// the clash API / external-controller port. Deduped so a configuration where
/// the two coincide only triggers a single cleanup pass.
fn ports_to_free(mixed_port: u16, clash_api_port: u16) -> Vec<u16> {
    let mut ports = vec![mixed_port];
    if mixed_port != clash_api_port {
        ports.push(clash_api_port);
    }
    ports
}

/// Reject a busy port before spawning sing-box. Process cleanup is deliberately
/// kept out of the start path: only the UI's repair flow may stop a positively
/// identified NekoPilot orphan, never an arbitrary local listener.
async fn ensure_port_free_for_spawn(action: u64, port: u16) -> Result<(), String> {
    if !probe_port_listening(port) {
        return Ok(());
    }
    ::log::warn!(
        "[start] action={action} :{port} already has a listener on entry — previous sing-box still bound?"
    );
    Err(format!(
        "{}:{}: port is already occupied; NekoPilot will not terminate another application",
        crate::commands::prestart::PORT_OCCUPIED_CANNOT_START,
        port,
    ))
}

// ── Tauri Commands ────────────────────────────────────────────────────

#[tauri::command]
pub async fn start(app: tauri::AppHandle, path: String, mode: ProxyMode) -> Result<(), String> {
    let _lifecycle_guard = LIFECYCLE_GATE.lock().await;
    let path = validate_engine_config_path(&app, &path)?;
    start_inner(app, path, mode).await
}

async fn start_inner(app: tauri::AppHandle, path: String, mode: ProxyMode) -> Result<(), String> {
    let action = next_action_token();
    let (pm_pid, pm_alive, pm_mode) = pm_snapshot();
    let ports = engine_ports_from_config_path(&path);
    let mixed_port = ports.mixed_proxy;
    let clash_api_port = ports.clash_api;
    let port_listening = probe_port_listening(mixed_port);
    let clash_listening = probe_port_listening(clash_api_port);
    let cur_state_kind = app.state::<EngineStateCell>().snapshot().kind();
    ::log::info!(
        "[start] action={action} mode={:?} state={} pm_child_pid={:?} pm_child_alive={:?} pm_mode={:?} :{mixed_port}_listener={} :{clash_api_port}_listener={}",
        mode, cur_state_kind, pm_pid, pm_alive, pm_mode, port_listening, clash_listening
    );
    // A child owned by this process can still be alive before its listeners
    // are ready. Reject it before the port probes so a second start can never
    // overwrite the only handle to the first child.
    if matches!(pm_alive, Some(true)) {
        ::log::warn!(
            "[start] action={action} rejected: owned child pid={:?} is already alive",
            pm_pid
        );
        return Err("engine_already_active".to_owned());
    }

    // A listener on either required port means sing-box would hit EADDRINUSE.
    // Refuse safely; do not kill a process whose ownership cannot be proved.
    for port in ports_to_free(mixed_port, clash_api_port) {
        ensure_port_free_for_spawn(action, port).await?;
    }
    {
        let cur = app.state::<EngineStateCell>().snapshot();
        if !matches!(cur, EngineState::Idle { .. } | EngineState::Failed { .. }) {
            ::log::warn!(
                "[start] action={action} engine in {} state without a live child, recovering to Idle",
                cur.kind()
            );
            let _ = transition(&app, Intent::MarkIdle);
        }
    }
    let mode_label = match mode {
        ProxyMode::TunProxy => "tun",
        ProxyMode::SystemProxy | ProxyMode::ManualProxy => "mixed",
    };
    if let Err(e) = transition(
        &app,
        Intent::Start {
            mode: mode_label.into(),
        },
    ) {
        return Err(format!("state transition rejected: {}", e));
    }
    let start_epoch = app.state::<EngineStateCell>().snapshot().epoch();

    // All privilege escalation, DNS overrides, sing-box spawn, per-mode
    // watchdogs, and ProcessManager seeding live inside the platform engine.
    // core just drives state-machine transitions and hands off to the
    // readiness prober once the spawn call returns.
    if let Err(e) = PlatformEngine::start(&app, mode.clone(), path, start_epoch).await {
        ::log::error!(
            "[start] action={action} PlatformEngine::start failed: {}",
            e
        );
        // Start can fail partway through (e.g. proxy set fails after the
        // child has already spawned). Ask the platform to tear down whatever
        // it did set up so we don't leak a half-started engine.
        let cleanup_error = PlatformEngine::stop(&app).await.err();
        let (_, cleanup_alive, _) = pm_snapshot();
        if !matches!(cleanup_alive, Some(true)) {
            ProcessManager::acquire().reset();
        } else {
            ::log::error!(
                "[start] action={action} cleanup left the spawned child alive; retaining its handle"
            );
        }
        if let Some(cleanup_error) = cleanup_error {
            ::log::error!(
                "[start] action={action} cleanup after failed start also failed: {cleanup_error}"
            );
            crate::engine::cleanup_on_shutdown();
        }
        let _ = transition(&app, Intent::Fail { reason: e.clone() });
        return Err(e);
    }

    // Platform-specific settle window before readiness probing — TUN
    // round-trips through the privileged companion, SystemProxy just
    // spawns a user-mode sidecar.
    tokio::time::sleep(PlatformEngine::start_settle_delay(&mode)).await;
    let (post_pid, post_alive, _) = pm_snapshot();
    ::log::info!(
        "[start] action={action} spawn returned, handing off to readiness prober (pm_child_pid={:?} alive={:?})",
        post_pid, post_alive
    );
    readiness::spawn(app.clone(), start_epoch, clash_api_port);
    Ok(())
}

#[tauri::command]
pub async fn stop(app: tauri::AppHandle) -> Result<(), String> {
    let _lifecycle_guard = LIFECYCLE_GATE.lock().await;
    stop_inner(app).await
}

async fn stop_inner(app: tauri::AppHandle) -> Result<(), String> {
    let action = next_action_token();
    let (pm_pid, pm_alive, pm_mode) = pm_snapshot();
    let mixed_port = mixed_proxy_port(&app);
    let is_stopping_before = ProcessManager::acquire().is_stopping;
    let cur_state_kind = app.state::<EngineStateCell>().snapshot().kind();
    ::log::info!(
        "[stop] action={action} state={} pm_child_pid={:?} pm_child_alive={:?} pm_mode={:?} is_stopping_before={}",
        cur_state_kind, pm_pid, pm_alive, pm_mode, is_stopping_before
    );

    {
        let cur = app.state::<EngineStateCell>().snapshot();
        match cur {
            EngineState::Running { .. } | EngineState::Starting { .. } => {
                let _ = transition(&app, Intent::Stop);
            }
            _ => {}
        }
    }

    // Platform engine signals sing-box to stop, clears the system proxy if
    // applicable, and transitions whatever per-mode state it owns. Actual
    // process exit is observed asynchronously by the process monitor which
    // then calls PlatformEngine::on_process_terminated for DNS restore.
    let mut platform_stop_error = PlatformEngine::stop(&app).await.err();
    if let Some(e) = platform_stop_error.as_ref() {
        ::log::error!(
            "[stop] action={action} PlatformEngine::stop returned error: {}",
            e
        );
        // Retry the shutdown-specific system-proxy cleanup while the process
        // manager still retains its mode. Resetting first would erase the
        // ownership proof and could leave macOS pointing at a dead proxy.
        crate::engine::cleanup_on_shutdown();
    }

    // Wait briefly for the owned process and listener to disappear. macOS
    // sends SIGTERM without consuming the CommandChild handle, so a process
    // that ignores the graceful signal can be identified and terminated with
    // SIGKILL without guessing which process owns the port.
    let mut port_listening = probe_port_listening(mixed_port);
    #[cfg(target_os = "macos")]
    let mut owned_pid_alive = pm_pid.is_some_and(pid_is_alive);
    let mut waited_ms = 0u64;
    while (port_listening || {
        #[cfg(target_os = "macos")]
        {
            owned_pid_alive
        }
        #[cfg(not(target_os = "macos"))]
        {
            false
        }
    }) && waited_ms < 500
    {
        tokio::time::sleep(Duration::from_millis(100)).await;
        waited_ms += 100;
        port_listening = probe_port_listening(mixed_port);
        #[cfg(target_os = "macos")]
        {
            owned_pid_alive = pm_pid.is_some_and(pid_is_alive);
        }
    }

    #[cfg(target_os = "macos")]
    if owned_pid_alive {
        let pid = pm_pid.expect("checked above");
        ::log::warn!("[stop] action={action} pid={pid} ignored SIGTERM; escalating to SIGKILL");
        if unsafe { libc::kill(pid as i32, libc::SIGKILL) } == 0
            || std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
        {
            while (port_listening || owned_pid_alive) && waited_ms < 1_500 {
                tokio::time::sleep(Duration::from_millis(100)).await;
                waited_ms += 100;
                port_listening = probe_port_listening(mixed_port);
                owned_pid_alive = pid_is_alive(pid);
            }
        } else {
            let error = std::io::Error::last_os_error();
            ::log::error!("[stop] action={action} failed to SIGKILL pid={pid}: {error}");
            let force_error = format!("failed to force-stop sing-box: {error}");
            platform_stop_error = Some(match platform_stop_error.take() {
                Some(previous) => format!("{previous}; {force_error}"),
                None => force_error,
            });
        }
    }

    let mut post_stop_state = app.state::<EngineStateCell>().snapshot();
    let (_, child_alive_after_stop, mode_after_stop) = pm_snapshot();
    let child_survived = matches!(child_alive_after_stop, Some(true));
    if platform_stop_error.is_some() && child_survived {
        let mode_label = match mode_after_stop {
            Some(ProxyMode::TunProxy) => "tun",
            _ => "mixed",
        };
        if matches!(post_stop_state, EngineState::Stopping { .. }) {
            let _ = transition(
                &app,
                Intent::RollbackToRunning {
                    mode: mode_label.to_owned(),
                },
            );
        }
        ::log::error!(
            "[stop] action={action} child is still alive after stop failure; preserving process ownership"
        );
    } else {
        // Stop owns the terminal state transition. The asynchronous monitor
        // may arrive before or after this point; its stable session guard
        // makes both orders safe and avoids leaving macOS stuck in Stopping.
        if matches!(post_stop_state, EngineState::Stopping { .. }) {
            let _ = transition(&app, Intent::MarkIdle);
            post_stop_state = app.state::<EngineStateCell>().snapshot();
        }
        if !matches!(
            post_stop_state,
            EngineState::Starting { .. } | EngineState::Running { .. }
        ) {
            ProcessManager::acquire().reset();
        }
    }

    if port_listening {
        ::log::warn!(
            "[stop] action={action} returning with :{mixed_port} STILL LISTENING after {waited_ms}ms — pm_child_pid={:?} may have survived SIGTERM",
            pm_pid
        );
    } else if waited_ms > 0 {
        ::log::info!("[stop] action={action} returned, :{mixed_port} released after {waited_ms}ms");
    } else {
        ::log::info!("[stop] action={action} returned, :{mixed_port} released");
    }
    app.emit(EVENT_STATUS_CHANGED, ()).ok();
    if let Some(error) = platform_stop_error {
        Err(error)
    } else {
        Ok(())
    }
}

/// Restart only if the engine session observed by the lifecycle listener is
/// still current. The check, stop and start share one native lock so a manual
/// user stop can never be followed by a stale wake task that turns the proxy
/// back on again.
pub(crate) async fn restart_if_running(
    app: tauri::AppHandle,
    path: String,
    mode: ProxyMode,
    expected_epoch: u64,
) -> Result<bool, String> {
    let _lifecycle_guard = LIFECYCLE_GATE.lock().await;
    let current = app.state::<EngineStateCell>().snapshot();
    if !matches!(current, EngineState::Running { .. }) || current.epoch() != expected_epoch {
        ::log::info!(
            "[restart] skipped stale request expected_epoch={} current_state={} current_epoch={}",
            expected_epoch,
            current.kind(),
            current.epoch()
        );
        return Ok(false);
    }
    stop_inner(app.clone()).await?;
    start_inner(app, path, mode).await?;
    Ok(true)
}

#[tauri::command]
pub async fn is_running(app: AppHandle, secret: String) -> bool {
    let app_data = app.state::<AppData>();
    app_data.set_clash_secret(Some(secret));
    let state = app.state::<EngineStateCell>().snapshot();
    matches!(state, EngineState::Running { .. })
}

#[tauri::command]
pub fn get_engine_state(app: AppHandle) -> EngineState {
    app.state::<EngineStateCell>().snapshot()
}

#[tauri::command]
pub fn clear_engine_error(app: AppHandle) {
    let cur = app.state::<EngineStateCell>().snapshot();
    if matches!(cur, EngineState::Failed { .. }) {
        let _ = transition(&app, Intent::ClearFailure);
    }
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
pub fn get_running_config() -> Option<(ProxyMode, String)> {
    let manager = ProcessManager::acquire();
    match (manager.mode.as_ref(), manager.config_path.as_ref()) {
        (Some(mode), Some(path)) => Some(((**mode).clone(), (**path).clone())),
        _ => None,
    }
}

#[tauri::command]
pub async fn reload_config(app: tauri::AppHandle) -> Result<String, String> {
    let _lifecycle_guard = LIFECYCLE_GATE.lock().await;
    let action = next_action_token();
    let (pm_pid, pm_alive, pm_mode) = pm_snapshot();
    let mixed_port = mixed_proxy_port(&app);
    let port_listening = probe_port_listening(mixed_port);
    ::log::info!(
        "[reload] action={action} entry pm_child_pid={:?} pm_child_alive={:?} pm_mode={:?} :{mixed_port}_listener={}",
        pm_pid, pm_alive, pm_mode, port_listening
    );
    if !port_listening {
        ::log::warn!(
            "[reload] action={action} :{mixed_port} NOT listening on entry — sing-box may already be down; SIGHUP will no-op"
        );
    }

    #[cfg(any(unix, target_os = "windows"))]
    {
        let needs_proxy_reset = {
            let manager = ProcessManager::acquire();
            match manager.mode.as_ref().map(|m| m.as_ref()) {
                Some(ProxyMode::TunProxy) => false,
                Some(ProxyMode::SystemProxy) => true,
                Some(ProxyMode::ManualProxy) => false,
                None => {
                    ::log::warn!("[reload] action={action} rejected: no running process");
                    return Err("No running process found".to_string());
                }
            }
        };

        ::log::info!("[reload] action={action} dispatching PlatformEngine::restart");
        PlatformEngine::restart(&app).await?;

        if needs_proxy_reset {
            ::log::info!(
                "[reload] action={action} SystemProxy — sleeping 500ms for sing-box rebind, then re-apply proxy"
            );
            tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
            let still_listening = probe_port_listening(mixed_port);
            if !still_listening {
                // Decisive signal: SIGHUP was sent, 500ms later the port
                // has no listener. Either (a) sing-box's Close()+create()
                // cycle hasn't rebound yet (bind failed, Close took too
                // long, log.Fatal exit), or (b) sing-box died outright.
                ::log::warn!(
                    "[reload] action={action} :{mixed_port} NOT listening 500ms after SIGHUP — sing-box rebind FAILED or process died"
                );
                if let Err(error) = crate::engine::clear_system_proxy(&app).await {
                    ::log::error!(
                        "[reload] action={action} failed to clear proxy after rebind failure: {error}"
                    );
                }
                return Err("Config reload failed: mixed proxy listener did not recover".to_owned());
            } else {
                ::log::info!(
                    "[reload] action={action} :{mixed_port} listener up 500ms after SIGHUP"
                );
            }
            if let Err(e) = crate::engine::apply_system_proxy(&app).await {
                ::log::error!(
                    "[reload] action={action} re-apply system proxy failed: {}",
                    e
                );
                return Err(format!("Config reloaded but failed to reset proxy: {}", e));
            }
            ::log::info!("[reload] action={action} system proxy re-applied");
        }

        ::log::info!("[reload] action={action} done");
        Ok("Configuration reloaded successfully".to_string())
    }

    #[cfg(not(any(unix, target_os = "windows")))]
    {
        Err("SIGHUP signal is not supported on this platform".to_string())
    }
}

// ── Tests ─────────────────────────────────────────────────────────────

#[cfg(test)]
mod port_guard_tests {
    use super::{
        canonical_engine_config_path, engine_ports_from_config_path, ports_to_free, EnginePorts,
        ProcessExitObservation, CLASH_API_PORT,
    };
    use std::fs;
    use tempfile::NamedTempFile;

    #[test]
    fn distinct_ports_yield_both_in_order() {
        assert_eq!(
            ports_to_free(6661, CLASH_API_PORT),
            vec![6661, CLASH_API_PORT]
        );
        assert_eq!(
            ports_to_free(6789, CLASH_API_PORT),
            vec![6789, CLASH_API_PORT]
        );
    }

    #[test]
    fn coinciding_port_is_deduped() {
        assert_eq!(
            ports_to_free(CLASH_API_PORT, CLASH_API_PORT),
            vec![CLASH_API_PORT]
        );
    }

    #[test]
    fn process_ownership_is_released_only_after_confirmed_exit() {
        assert!(!ProcessExitObservation::Exited.retains_ownership());
        assert!(ProcessExitObservation::Alive.retains_ownership());
        assert!(ProcessExitObservation::Unknown.retains_ownership());
        assert_eq!(
            ProcessExitObservation::from_windows_open_failure(true),
            ProcessExitObservation::Exited
        );
        assert_eq!(
            ProcessExitObservation::from_windows_open_failure(false),
            ProcessExitObservation::Unknown
        );
    }

    #[test]
    fn parsed_ports_follow_the_config_file() {
        let file = NamedTempFile::new().unwrap();
        fs::write(
            file.path(),
            r#"{"inbounds":[{"type":"mixed","tag":"mixed","listen_port":6790}],"experimental":{"clash_api":{"external_controller":"127.0.0.1:9291"}}}"#,
        )
        .unwrap();
        assert_eq!(
            engine_ports_from_config_path(file.path().to_str().unwrap()),
            EnginePorts {
                mixed_proxy: 6790,
                clash_api: 9291
            },
        );
    }

    #[test]
    fn engine_config_must_be_the_real_config_file_in_its_private_directory() {
        let directory = tempfile::tempdir().unwrap();
        let expected = directory.path().join("config.json");
        let other = directory.path().join("other.json");
        fs::write(&expected, "{}").unwrap();
        fs::write(&other, "{}").unwrap();
        let expected_canonical = fs::canonicalize(&expected).unwrap();
        assert_eq!(
            canonical_engine_config_path(directory.path(), &expected).unwrap(),
            expected_canonical
        );
        assert_eq!(
            canonical_engine_config_path(directory.path(), &other),
            Err("engine_config_path_not_allowed".to_owned())
        );
    }
}

#[cfg(all(test, target_os = "linux"))]
mod sigterm_classify_tests {
    use super::sigterm_target_already_exited;

    #[test]
    fn esrch_means_already_exited() {
        assert!(sigterm_target_already_exited(Some(libc::ESRCH)));
    }

    #[test]
    fn other_errno_is_a_real_failure() {
        assert!(!sigterm_target_already_exited(Some(libc::EPERM)));
    }

    #[test]
    fn no_errno_is_not_already_exited() {
        assert!(!sigterm_target_already_exited(None));
    }
}

#[cfg(test)]
mod tests {
    use super::log::*;
    use std::fs;
    use std::path::Path;
    use tempfile::TempDir;

    #[test]
    fn test_today_date_string_format() {
        let date = today_date_string();
        assert_eq!(date.len(), 10);
        assert_eq!(date.as_bytes()[4], b'-');
        assert_eq!(date.as_bytes()[7], b'-');

        let parts: Vec<&str> = date.split('-').collect();
        assert_eq!(parts.len(), 3);

        let year: i32 = parts[0].parse().expect("year should be a number");
        let month: i32 = parts[1].parse().expect("month should be a number");
        let day: i32 = parts[2].parse().expect("day should be a number");

        assert!((2024..=2100).contains(&year));
        assert!((1..=12).contains(&month));
        assert!((1..=31).contains(&day));
    }

    #[test]
    fn test_cleanup_old_singbox_logs_removes_old_files() {
        let tmp = TempDir::new().unwrap();

        let old_file = tmp.path().join("sing-box-2020-01-01.log");
        fs::write(&old_file, "old log").unwrap();
        let ten_days_ago =
            std::time::SystemTime::now() - std::time::Duration::from_secs(10 * 86400);
        filetime::set_file_mtime(
            &old_file,
            filetime::FileTime::from_system_time(ten_days_ago),
        )
        .unwrap();

        let new_file = tmp.path().join("sing-box-2099-01-01.log");
        fs::write(&new_file, "new log").unwrap();

        let other_file = tmp.path().join("other.log");
        fs::write(&other_file, "other").unwrap();

        cleanup_old_singbox_logs(tmp.path(), 7);

        assert!(!old_file.exists(), "old log should be removed");
        assert!(new_file.exists(), "new log should be kept");
        assert!(other_file.exists(), "non-matching file should be kept");
    }

    #[test]
    fn test_cleanup_old_singbox_logs_nonexistent_dir() {
        cleanup_old_singbox_logs(Path::new("/nonexistent/dir/abc123"), 7);
    }

    #[test]
    fn test_write_singbox_log() {
        let tmp = TempDir::new().unwrap();
        let log_path = tmp.path().join("test.log");

        let mut writer = Some(open_singbox_log_writer(&log_path).unwrap());

        write_singbox_log(&mut writer, "hello line 1");
        write_singbox_log(&mut writer, "hello line 2");
        drop(writer);

        let content = fs::read_to_string(&log_path).unwrap();
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0], "hello line 1");
        assert_eq!(lines[1], "hello line 2");
    }

    #[test]
    fn test_write_singbox_log_none_writer() {
        let mut writer: Option<SingboxLogWriter> = None;
        write_singbox_log(&mut writer, "should not panic");
    }

    #[test]
    fn test_write_singbox_log_stops_at_daily_cap() {
        let tmp = TempDir::new().unwrap();
        let log_path = tmp.path().join("capped.log");
        let file = std::fs::File::create(&log_path).unwrap();
        file.set_len(MAX_ACTIVE_SINGBOX_LOG_BYTES - 2).unwrap();
        drop(file);

        let mut writer = Some(open_singbox_log_writer(&log_path).unwrap());
        write_singbox_log(&mut writer, "first line");
        write_singbox_log(&mut writer, "must not grow");
        flush_singbox_log(&mut writer);
        assert_eq!(
            std::fs::metadata(log_path).unwrap().len(),
            MAX_ACTIVE_SINGBOX_LOG_BYTES
        );
    }
}
