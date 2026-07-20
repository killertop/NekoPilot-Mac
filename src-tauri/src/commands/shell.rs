use crate::{
    app::state::{AppData, LogType},
    core::stop,
};

use tauri::AppHandle;

use std::sync::atomic::{AtomicBool, Ordering};
use tauri_plugin_shell::ShellExt;

static QUIT_STARTED: AtomicBool = AtomicBool::new(false);

#[tauri::command]
pub fn get_tray_icon(app: AppHandle) -> Result<Vec<u8>, String> {
    #[cfg(target_os = "macos")]
    {
        log::info!("macos tray icon for app: {:?}", app.package_info().name);
        // A small monochrome alpha-mask made specifically for the macOS menu
        // bar. Do not use the colourful 512px app icon here: macOS template
        // icons are rendered from alpha and need a compact, transparent asset.
        Ok(include_bytes!("../../icons/menu-bar-template.png").to_vec())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let icon = app
            .default_window_icon()
            .ok_or_else(|| "default_window_icon_missing".to_owned())?;
        let rgba = icon.rgba();
        let width = icon.width();
        let height = icon.height();
        // 将 RGBA 数据转换为 PNG 格式
        let mut png_data = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut png_data, width, height);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            let mut writer = encoder
                .write_header()
                .map_err(|error| format!("encode_tray_icon_header: {error}"))?;
            writer
                .write_image_data(rgba)
                .map_err(|error| format!("encode_tray_icon_data: {error}"))?;
        }
        Ok(png_data)
    }
}

#[tauri::command]
pub fn get_app_version(app: AppHandle) -> String {
    let package_info = app.package_info();
    package_info.version.to_string() // 返回版本号，如 "1.0.0"
}

#[tauri::command]
async fn quit(app: AppHandle) {
    // 退出应用并清理资源
    log::info!("Quitting application...");
    if let Err(e) = stop(app.clone()).await {
        log::error!("Failed to stop proxy: {}", e);
    } else {
        log::info!("Proxy stopped successfully.");
    }
    // A quit request must always release the application and tray item. The
    // final RunEvent::Exit cleanup remains a last-resort proxy cleanup path.
    log::info!("Application exit requested.");
    app.exit(0);
}

pub fn sync_quit(app: AppHandle) {
    // CloseRequested, Destroyed and the tray menu can converge on the same
    // shutdown. Only the first caller may stop the child and request exit;
    // later callbacks are a consequence of that same exit, not a new quit.
    if QUIT_STARTED.swap(true, Ordering::AcqRel) {
        log::info!("Application quit already in progress; ignoring duplicate request");
        return;
    }
    tauri::async_runtime::block_on(quit(app));
}

#[tauri::command]
pub fn read_logs(app_data: tauri::State<AppData>, is_error: bool) -> String {
    let log_type = if is_error {
        LogType::Error
    } else {
        LogType::Info
    };
    app_data.read_cleared(log_type)
}

#[tauri::command]
pub fn get_pending_deep_link(
    app_data: tauri::State<AppData>,
) -> Option<crate::app::state::DeepLinkPayload> {
    if let Ok(mut pending) = app_data.pending_deep_link.lock() {
        pending.take()
    } else {
        None
    }
}

#[tauri::command]
pub async fn version(app: tauri::AppHandle) -> Result<String, String> {
    let sidecar_command = app.shell().sidecar("sing-box").map_err(|e| e.to_string())?;
    let output = sidecar_command
        .arg("version")
        .output()
        .await
        .map_err(|e| e.to_string())?;
    String::from_utf8(output.stdout).map_err(|e| e.to_string())
}
