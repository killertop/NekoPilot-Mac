use log::LevelFilter;
use tauri::{AppHandle, Builder, Manager, Wry};
use tauri_plugin_autostart::MacosLauncher;
use tauri_plugin_log::{RotationStrategy, Target, TargetKind, TimezoneStrategy};

// OneBox.log rotation policy — rotate when the active file exceeds 50 MB,
// keep all rotated files (renamed to OneBox_YYYY-MM-DD_HH-MM-SS.log). A
// startup sweep in `core::log::cleanup_old_onebox_logs` deletes rotated
// files older than 7 days. Uncompressed — triage speed trumps disk cost.
const ONEBOX_LOG_MAX_FILE_SIZE: u128 = 50 * 1024 * 1024;

#[allow(unused_variables)]
pub fn register_plugins(builder: Builder<Wry>) -> Builder<Wry> {
    builder
        .plugin(tauri_plugin_single_instance::init(
            |app: &AppHandle, args, _cwd| {
                // On Windows and Linux, deep links arrive as CLI args to a new
                // process. single_instance kills that process and gives us its
                // args here. We must forward the URL manually so on_open_url fires.
                #[cfg(any(windows, target_os = "linux"))]
                {
                    use tauri::Emitter;
                    if let Some(url_str) = args.iter().skip(1).find(|a| a.contains("://")) {
                        let _ = app.emit("deep-link://new-url", vec![url_str.as_str()]);
                    }
                }
                show_window(app);
            },
        ))
        .plugin(tauri_plugin_deep_link::init())
        .plugin({
            let targets = ["nekopilot_lib", "tauri_plugin_deep_link"];
            tauri_plugin_log::Builder::new()
                .filter(move |metadata| {
                    targets
                        .iter()
                        .any(|&target| metadata.target().starts_with(target))
                })
                .level(LevelFilter::Info)
                .timezone_strategy(TimezoneStrategy::UseLocal)
                .max_file_size(ONEBOX_LOG_MAX_FILE_SIZE)
                .rotation_strategy(RotationStrategy::KeepAll)
                .targets([
                    Target::new(TargetKind::Stdout),
                    Target::new(TargetKind::LogDir { file_name: None }),
                ])
                .build()
        })
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_os::init())
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            Some(vec![]),
        ))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
}

fn show_window(app: &AppHandle) {
    let windows = app.webview_windows();

    if let Some(window) = windows.values().next() {
        if let Err(error) = window.set_focus() {
            log::warn!("failed to focus existing window: {error}");
        }
    }

    if let Some(main_window) = app.get_webview_window("main") {
        #[cfg(any(target_os = "windows", target_os = "linux"))]
        {
            if let Err(error) = main_window.unminimize() {
                log::warn!("failed to unminimize main window: {error}");
            }
        }
        if let Err(error) = main_window.show() {
            log::warn!("failed to show main window: {error}");
        }
        if let Err(error) = main_window.set_focus() {
            log::warn!("failed to focus main window: {error}");
        }
    }
}
