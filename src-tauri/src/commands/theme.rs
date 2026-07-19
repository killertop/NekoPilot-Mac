//! Reset NSWindow.appearance to follow macOS on macOS.
//!
//! The command clears any prior explicit appearance through AppKit so native
//! chrome inherits the operating-system setting on the next draw cycle.

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn onebox_set_window_appearance(ns_window_ptr: *mut std::ffi::c_void, theme: i32);
}

#[tauri::command]
pub fn set_native_window_theme(window: tauri::Window, theme: Option<String>) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let ns_window = window.ns_window().map_err(|e| e.to_string())?;
        let mode: i32 = match theme.as_deref() {
            Some("light") => 1,
            Some("dark") => 2,
            _ => 0, // None or unknown — inherit from OS
        };
        unsafe {
            onebox_set_window_appearance(ns_window, mode);
        }
        log::debug!(
            "[theme] native set_window_appearance label={} mode={}",
            window.label(),
            mode
        );
    }
    #[cfg(not(target_os = "macos"))]
    {
        // No-op on non-mac hosts — Linux/Windows fall back to the JS-side
        // `window.setTheme()` which does work there.
        let _ = (window, theme);
    }
    Ok(())
}
