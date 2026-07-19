use std::fs;
use std::io::ErrorKind;
use tauri::{AppHandle, Manager};

/// Delete legacy v1 cache files (including the historical `gloabl` typo) left over from
/// pre-v2 clients. Never fails app startup.
pub fn purge_legacy_cache_files(app: &AppHandle) {
    let config_dir = match app.path().app_config_dir() {
        Ok(dir) => dir,
        Err(e) => {
            log::warn!("[cache-migrate] cannot resolve app config dir: {}", e);
            return;
        }
    };

    // Include sqlite WAL/shm sidecars — written next to every .db.
    let legacy_names = [
        "mixed-cache-rule-v1.db",
        "mixed-cache-rule-v1.db-wal",
        "mixed-cache-rule-v1.db-shm",
        "tun-cache-rule-v1.db",
        "tun-cache-rule-v1.db-wal",
        "tun-cache-rule-v1.db-shm",
        "tun-cache-global-v1.db",
        "tun-cache-global-v1.db-wal",
        "tun-cache-global-v1.db-shm",
        "mixed-cache-gloabl-v1.db",
        "mixed-cache-gloabl-v1.db-wal",
        "mixed-cache-gloabl-v1.db-shm",
    ];

    for name in legacy_names {
        let target = config_dir.join(name);
        match fs::remove_file(&target) {
            Ok(_) => log::info!("[cache-migrate] removed legacy cache file: {:?}", target),
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(e) => log::warn!("[cache-migrate] failed to remove {:?}: {}", target, e),
        }
    }
}

pub fn show_dashboard(app: AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        #[cfg(any(target_os = "windows", target_os = "linux"))]
        if let Err(error) = w.unminimize() {
            log::warn!("failed to unminimize main window: {error}");
        }
        if let Err(error) = w.show() {
            log::warn!("failed to show main window: {error}");
        }
        if let Err(error) = w.set_focus() {
            log::warn!("failed to focus main window: {error}");
        }
    }
}
