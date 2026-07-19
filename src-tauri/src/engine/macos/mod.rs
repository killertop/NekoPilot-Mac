//! macOS engine for the certificate-free NekoPilot build.
//!
//! This target deliberately supports only user-mode mixed proxy operation.
//! It never installs a privileged helper, changes system DNS, or creates a
//! TUN device, so a local build needs no Apple signing identity.

use crate::engine::sysproxy::{clear_system_proxy, set_system_proxy};
use crate::engine::EngineManager;
use std::sync::Arc;
use tauri::AppHandle;
use tauri_plugin_shell::ShellExt;

const TUN_REMOVED_MESSAGE: &str =
    "TUN mode is unavailable in this certificate-free NekoPilot build. Use System Proxy instead.";

pub struct MacOSEngine;

impl EngineManager for MacOSEngine {
    async fn start(
        app: &AppHandle,
        mode: crate::engine::ProxyMode,
        config_path: String,
        start_epoch: u64,
    ) -> Result<(), String> {
        match mode {
            crate::engine::ProxyMode::SystemProxy | crate::engine::ProxyMode::ManualProxy => {
                let should_set_system_proxy = matches!(mode, crate::engine::ProxyMode::SystemProxy);
                let cmd = app
                    .shell()
                    .sidecar("sing-box")
                    .map_err(|e| format!("sidecar lookup failed: {e}"))?
                    .args(["run", "-c", &config_path, "--disable-color"]);
                let (rx, child) = cmd.spawn().map_err(|e| format!("spawn failed: {e}"))?;
                let child_pid = child.pid();
                crate::core::monitor::spawn_process_monitor(
                    app.clone(),
                    rx,
                    Arc::new(mode.clone()),
                    child_pid,
                    start_epoch,
                );
                {
                    let mut manager = crate::core::ProcessManager::acquire();
                    manager.mode = Some(Arc::new(mode));
                    manager.config_path = Some(Arc::new(config_path));
                    manager.child = Some(child);
                    manager.is_stopping = false;
                }
                if should_set_system_proxy {
                    set_system_proxy(app).await.map_err(|e| e.to_string())?;
                }
                Ok(())
            }
            crate::engine::ProxyMode::TunProxy => Err(TUN_REMOVED_MESSAGE.into()),
        }
    }

    async fn stop(app: &AppHandle) -> Result<(), String> {
        let (mode, child) = {
            let mut manager = crate::core::ProcessManager::acquire();
            manager.is_stopping = true;
            (manager.mode.clone(), manager.child.take())
        };
        let Some(mode) = mode else {
            return Ok(());
        };

        match mode.as_ref() {
            crate::engine::ProxyMode::SystemProxy | crate::engine::ProxyMode::ManualProxy => {
                if matches!(mode.as_ref(), crate::engine::ProxyMode::SystemProxy) {
                    let _ = clear_system_proxy(app).await;
                }
                if let Some(child) = child {
                    child
                        .kill()
                        .map_err(|e| format!("failed to stop sing-box: {e}"))?;
                }
                Ok(())
            }
            crate::engine::ProxyMode::TunProxy => Ok(()),
        }
    }

    async fn restart(_app: &AppHandle) -> Result<(), String> {
        let child_pid = {
            let manager = crate::core::ProcessManager::acquire();
            match manager.mode.as_deref() {
                Some(crate::engine::ProxyMode::TunProxy) => return Err(TUN_REMOVED_MESSAGE.into()),
                Some(_) => manager.child.as_ref().map(|child| child.pid()),
                None => return Err("No running process found".into()),
            }
        };
        let Some(child_pid) = child_pid else {
            return Err("No running sing-box process found".into());
        };
        unsafe {
            if libc::kill(child_pid as i32, libc::SIGHUP) != 0 {
                return Err(format!(
                    "failed to reload sing-box: {}",
                    std::io::Error::last_os_error()
                ));
            }
        }
        Ok(())
    }

    async fn ensure_installed(_app: &AppHandle) -> Result<(), String> {
        Err("The privileged helper has been removed from NekoPilot.".into())
    }

    async fn probe(_app: &AppHandle) -> Result<String, String> {
        Err("The privileged helper has been removed from NekoPilot.".into())
    }
}
