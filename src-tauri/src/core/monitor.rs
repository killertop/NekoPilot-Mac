use std::sync::Arc;
use tauri::Emitter;
use tauri::Manager;

use crate::app::state::{AppData, LogType};
use crate::engine::state_machine::{transition, EngineState, EngineStateCell, Intent};
use crate::engine::{EngineManager, PlatformEngine, EVENT_STATUS_CHANGED};

use super::log::{create_singbox_log_writer, flush_singbox_log, write_singbox_log};
use super::{ProcessManager, ProxyMode};

/// Spawn the sing-box stdout/stderr monitor as a tokio task.
/// Routes output to log file + frontend events, and handles termination.
///
/// `child_pid` is the OS pid of the process Tauri spawned — on macOS
/// / Windows SystemProxy and Linux SystemProxy it's sing-box itself,
/// on Linux TUN it's `pkexec` (sing-box runs as its child). It's only
/// used as a stable identifier in log lines so Terminated / stderr
/// bind-error / spawn entries can be correlated across the full log.
pub(crate) fn spawn_process_monitor(
    app: tauri::AppHandle,
    mut rx: tauri::async_runtime::Receiver<tauri_plugin_shell::process::CommandEvent>,
    mode: Arc<ProxyMode>,
    child_pid: u32,
    spawn_epoch: u64,
) {
    let mut singbox_log = create_singbox_log_writer(&app);
    let spawn_at = std::time::Instant::now();
    log::info!(
        "[sing-box] monitor attached pid={} mode={:?}",
        child_pid,
        mode
    );
    tokio::spawn(async move {
        let mut terminated = false;
        let app_status_data = app.state::<AppData>();

        while let Some(event) = rx.recv().await {
            if terminated {
                if let tauri_plugin_shell::process::CommandEvent::Stdout(line)
                | tauri_plugin_shell::process::CommandEvent::Stderr(line) = event
                {
                    let line_str = String::from_utf8_lossy(&line);
                    write_singbox_log(&mut singbox_log, &line_str);
                }
                continue;
            }
            match event {
                tauri_plugin_shell::process::CommandEvent::Stdout(line) => {
                    log::debug!("[sing-box-event] pid={} Stdout", child_pid);
                    let line_str = String::from_utf8_lossy(&line);
                    write_singbox_log(&mut singbox_log, &line_str);
                }
                tauri_plugin_shell::process::CommandEvent::Stderr(line) => {
                    log::debug!("[sing-box-event] pid={} Stderr", child_pid);
                    let line_str = String::from_utf8_lossy(&line);
                    write_singbox_log(&mut singbox_log, &line_str);
                    scan_stderr_for_bind_error(child_pid, &line_str);
                    app_status_data.write(line_str.to_string(), LogType::Info);
                }
                tauri_plugin_shell::process::CommandEvent::Error(err) => {
                    log::debug!("[sing-box-event] pid={} Error", child_pid);
                    log::error!("[sing-box] pid={} process error: {}", child_pid, err);
                    write_singbox_log(&mut singbox_log, &format!("[ERROR] {}", err));
                    flush_singbox_log(&mut singbox_log);
                    app_status_data.write(err.to_string(), LogType::Error);
                }
                tauri_plugin_shell::process::CommandEvent::Terminated(payload) => {
                    terminated = true;
                    flush_singbox_log(&mut singbox_log);
                    let runtime = spawn_at.elapsed();
                    log::info!(
                        "[sing-box] pid={} terminated runtime={:.2}s code={:?} signal={:?}",
                        child_pid,
                        runtime.as_secs_f64(),
                        payload.code,
                        payload.signal
                    );
                    #[allow(unused_variables)]
                    let adjusted_payload = {
                        #[cfg(target_os = "windows")]
                        {
                            let is_stopping = {
                                let manager = ProcessManager::acquire();
                                manager.is_stopping
                            };
                            if is_stopping && payload.code == Some(1) {
                                log::info!(
                                    "[monitor] windows code remap applied orig_code=1 new_code=0 is_stopping=true pid={}",
                                    child_pid
                                );
                                tauri_plugin_shell::process::TerminatedPayload {
                                    code: Some(0),
                                    signal: payload.signal,
                                }
                            } else {
                                log::debug!(
                                    "[monitor] windows code remap not applied pid={} is_stopping={} code={:?}",
                                    child_pid, is_stopping, payload.code
                                );
                                payload
                            }
                        }
                        #[cfg(not(target_os = "windows"))]
                        payload
                    };
                    handle_process_termination(&app, &mode, adjusted_payload, spawn_epoch).await;
                }
                _ => {
                    log::debug!("[sing-box-event] pid={} other event received", child_pid);
                }
            }
        }
    });
}

/// Sing-box emits `listen tcp 127.0.0.1:16789: bind: address already in
/// use` (or the platform's localized equivalent) on stderr when its
/// Mixed inbound's `listenConfig.Listen()` returns EADDRINUSE. The raw
/// line goes to sing-box.log regardless; we additionally echo a
/// prominent warn to the main OneBox.log so triage doesn't need to
/// cross-reference two files.
fn scan_stderr_for_bind_error(pid: u32, line: &str) {
    if is_tcp_listener_bind_error(line) {
        log::warn!("[sing-box] pid={} BIND FAILED: {}", pid, line.trim_end());
    }
}

fn is_tcp_listener_bind_error(line: &str) -> bool {
    let line = line.to_ascii_lowercase();
    line.contains("listen tcp")
        && (line.contains("address already in use")
            || line.contains("eaddrinuse")
            || line.contains("bind:"))
}

/// Returns `true` when a termination event no longer belongs to the engine
/// process currently owned by ProcessManager. The state-machine epoch cannot
/// be used here: it intentionally changes as a single process moves through
/// Starting, Running and Stopping.
#[inline]
pub(crate) fn session_guard_stale(spawn_epoch: u64, active_session: Option<u64>) -> bool {
    active_session != Some(spawn_epoch)
}

/// Handle sing-box process termination (intentional stop or crash).
/// Cleans up DNS, proxy, and transitions the state machine.
pub(crate) async fn handle_process_termination(
    app_handle: &tauri::AppHandle,
    process_mode: &Arc<ProxyMode>,
    payload: tauri_plugin_shell::process::TerminatedPayload,
    spawn_epoch: u64,
) {
    // Serialize termination cleanup with user/tray start, stop, reload and
    // wake-driven restart. Without this lock, an old event can pass its guard,
    // then reset ProcessManager after a new child has already been seeded.
    let _lifecycle_guard = super::LIFECYCLE_GATE.lock().await;
    let active_session = ProcessManager::acquire().session_epoch;
    if session_guard_stale(spawn_epoch, active_session) {
        log::info!(
            "[monitor] guard: stale session captured={} active={:?} mode={:?} code={:?} — skipping cleanup",
            spawn_epoch, active_session, process_mode, payload.code
        );
        // A late Terminated event from the previous sing-box must be entirely
        // invisible to the current session. Continuing below would still emit
        // status-changed and transition a newer Starting/Running engine to
        // Idle or Failed even though its cleanup was skipped.
        return;
    }

    // Phase 1: confirm the exiting process belongs to the mode we think is
    // active, and decide whether this was a user-initiated stop. Do NOT
    // reset ProcessManager yet — the platform's on_process_terminated hook
    // below may need to read teardown state (e.g. Linux dns_override) that
    // lives there.
    let (pm_pid, manager_mode, matches, is_stopping) = {
        let manager = ProcessManager::acquire();
        let pm_pid = manager
            .child
            .as_ref()
            .map(|child| child.pid())
            .or(manager.owned_pid);
        let manager_mode = manager.mode.as_ref().map(|m| (**m).clone());
        let matches = manager
            .mode
            .as_ref()
            .map(|m| **m == **process_mode)
            .unwrap_or(false);
        let is_stopping = manager.is_stopping;
        (pm_pid, manager_mode, matches, is_stopping)
    };
    let engine_state = app_handle
        .state::<crate::engine::state_machine::EngineStateCell>()
        .snapshot();
    log::info!(
        "[monitor] handle_process_termination entry pid={:?} code={:?} signal={:?} is_stopping={} process_mode={:?} manager_mode={:?} engine_state={}",
        pm_pid, payload.code, payload.signal, is_stopping,
        process_mode, manager_mode, engine_state.kind()
    );
    let (should_cleanup, was_user_initiated_stop) = if matches {
        log::info!("Cleaning up resources after process termination");
        log::info!(
            "[monitor] should_cleanup=true is_stopping={} mode={:?}",
            is_stopping,
            process_mode
        );
        (true, is_stopping)
    } else {
        log::info!(
            "[monitor] should_cleanup=false reason=mode_mismatch process_mode={:?} manager_mode={:?}",
            process_mode, manager_mode
        );
        (false, false)
    };

    // Only run cleanup when the mode matches and the event belongs to the
    // current engine session.
    if should_cleanup {
        if matches!(**process_mode, ProxyMode::SystemProxy) {
            if let Err(e) = crate::engine::clear_system_proxy(app_handle).await {
                log::error!("Failed to unset proxy after process termination: {}", e);
            }
        }

        if matches!(**process_mode, ProxyMode::TunProxy) {
            PlatformEngine::on_process_terminated(app_handle, was_user_initiated_stop);
        }

        // Phase 2: now that platform teardown has run and consumed whatever state
        // it needed, reset ProcessManager. The old `reset()` return value is
        // ignored — dns_override consumption is a platform concern.
        ProcessManager::acquire().reset();
    }

    if let Err(e) = app_handle.emit(EVENT_STATUS_CHANGED, payload.clone()) {
        log::error!("Failed to emit status-changed event: {}", e);
    }

    let cur = app_handle.state::<EngineStateCell>().snapshot();
    match cur {
        EngineState::Stopping { .. } => {
            log::info!(
                "[monitor] intent=MarkIdle reason=user_stop engine_state={} code={:?}",
                cur.kind(),
                payload.code
            );
            let _ = transition(app_handle, Intent::MarkIdle);
        }
        EngineState::Running { .. } | EngineState::Starting { .. } => {
            let code = payload.code.unwrap_or(-1);
            if code == 0 {
                log::info!(
                    "[monitor] intent=MarkIdle reason=clean_exit engine_state={} code=0",
                    cur.kind()
                );
                let _ = transition(app_handle, Intent::MarkIdle);
            } else {
                log::info!(
                    "[monitor] intent=Fail reason=unexpected_exit engine_state={} code={}",
                    cur.kind(),
                    code
                );
                let _ = transition(
                    app_handle,
                    Intent::Fail {
                        reason: format!("sing-box exited unexpectedly (code={})", code),
                    },
                );
            }
        }
        _ => {
            log::info!(
                "[monitor] intent=none engine_state={} code={:?} no transition taken",
                cur.kind(),
                payload.code
            );
        }
    }
}

#[cfg(test)]
mod session_guard_tests {
    use super::session_guard_stale;

    #[test]
    fn same_session_is_not_stale() {
        assert!(!session_guard_stale(5, Some(5)));
    }

    #[test]
    fn superseded_session_is_stale() {
        assert!(session_guard_stale(1, Some(3)));
    }

    #[test]
    fn cleared_session_is_stale() {
        assert!(session_guard_stale(3, None));
    }
}

#[cfg(test)]
mod bind_error_tests {
    use super::is_tcp_listener_bind_error;

    #[test]
    fn recognizes_local_tcp_listener_collision() {
        assert!(is_tcp_listener_bind_error(
            "listen tcp 127.0.0.1:16789: bind: address already in use"
        ));
    }

    #[test]
    fn ignores_nested_udp_dns_errors() {
        assert!(!is_tcp_listener_bind_error(
            "lookup example.com: listen udp4 0.0.0.0:68: bind: address already in use"
        ));
    }
}
