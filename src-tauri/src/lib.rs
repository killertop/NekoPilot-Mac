mod app;
mod commands;
mod core;
pub mod engine;
mod utils;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Windows 提权 helper 分支:父进程通过 ShellExecuteExW runas 用同一 exe
    // 带 `--onebox-tun-helper <sub> [args...]` 重启自己;elevated 子进程在
    // 这里直接进入 helper 逻辑执行 DNS 覆写 / 启停 sing-box,完成后 exit,
    // 不会进入 tauri::Builder 初始化,避免弹第二个 GUI 窗口。
    #[cfg(target_os = "windows")]
    {
        let raw_args: Vec<String> = std::env::args().collect();
        if let Some(pos) = raw_args.iter().position(|a| a == "--onebox-tun-helper") {
            let helper_args: Vec<String> = raw_args[pos + 1..].to_vec();
            let code = engine::windows::native::run_helper(&helper_args);
            std::process::exit(code);
        }
    }

    // On Linux/GNOME Wayland, tao creates a GTK HeaderBar for CSD which is
    // noticeably thicker than the X11 WM-provided titlebar. Inject custom
    // CSS before window creation to slim it down.
    #[cfg(target_os = "linux")]
    {
        use gtk::prelude::CssProviderExt;
        gtk::init().ok();
        let css = gtk::CssProvider::new();
        let _ = css.load_from_data(
            b"headerbar { min-height: 0; padding-top: 0; padding-bottom: 0; }
              headerbar .title { font-size: 0.9em; }
              headerbar button { min-height: 0; min-width: 0; padding: 2px 4px; margin: 0; }",
        );
        gtk::StyleContext::add_provider_for_screen(
            &gdk::Screen::default().expect("no default screen"),
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }

    let builder = tauri::Builder::default();

    app::plugins::register_plugins(builder)
        .invoke_handler(tauri::generate_handler![
            commands::network::get_lan_ip,
            commands::node_delay::measure_offline_node_delay,
            commands::dns::get_optimal_local_dns_server,
            commands::config_fetch::verify_deep_link_url,
            commands::config_build::prepare_write_and_reload_config,
            commands::config_build::list_runtime_nodes,
            commands::subscription::list_subscriptions,
            commands::subscription::upsert_subscription,
            commands::subscription::import_subscription,
            commands::subscription::import_proxy_link,
            commands::subscription::rename_subscription,
            commands::subscription::delete_subscription,
            commands::subscription::get_subscription_config,
            commands::subscription::get_subscription_url,
            commands::subscription::refresh_subscription,
            commands::settings::get_setting,
            commands::settings::set_setting,
            commands::settings::delete_setting,
            commands::settings::list_setting_keys,
            commands::settings::get_or_create_clash_api_secret,
            core::stop,
            core::start,
            core::is_running,
            core::get_clash_api_port,
            core::get_engine_state,
            core::clear_engine_error,
            core::reload_config,
            commands::shell::version,
            commands::shell::read_logs,
            commands::shell::get_tray_icon,
            commands::shell::get_app_version,
            commands::shell::get_pending_deep_link,
            commands::theme::set_native_window_theme,
            commands::prestart::prestart_check,
            commands::prestart::kill_orphans,
        ])
        .setup(app::setup::app_setup)
        .on_menu_event(app::events::on_menu_event)
        .on_window_event(app::events::on_window_event)
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(app::events::on_run_event)
}
