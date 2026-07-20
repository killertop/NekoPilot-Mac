use tauri::Emitter;
use tauri::Manager;
use tauri_plugin_deep_link::DeepLinkExt;
use url::Url;

use crate::utils::show_dashboard;

/// App 初始化逻辑，对应 Builder::setup 闭包
pub fn app_setup(app: &mut tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    app.manage(crate::app::state::AppData::new());
    app.manage(crate::engine::state_machine::EngineStateCell::new());
    secure_app_config_directory(app.handle())?;
    #[cfg(target_os = "macos")]
    if let Err(error) = crate::engine::sysproxy::recover_stale_system_proxy(app.handle()) {
        // Keep startup available when macOS has not restored its network
        // services yet. The durable marker remains in place, and a later
        // SystemProxy start retries recovery before applying a new owner.
        log::warn!("[proxy-recovery] startup recovery deferred: {error}");
    }
    stop_orphan_tun_service_on_startup();

    // Remove cache files from pre-v2 releases. The v2 cache is created lazily by
    // sing-box, so no bundled cache database is needed.
    crate::utils::purge_legacy_cache_files(app.handle());

    // One-shot sweep of rotated NekoPilot.log (and legacy OneBox.log)
    // archives older than 7 days.
    // Paired with tauri-plugin-log's KeepAll rotation in `plugins.rs`.
    crate::core::cleanup_old_app_logs(app.handle());

    crate::commands::whitelist::spawn_whitelist_refresh_task(app.handle().clone());
    if let Err(error) = crate::commands::rule_sets::ensure_cn_rule_set_baseline(app.handle()) {
        log::warn!("[RULE-SETS] Failed to install bundled CN baseline: {error}");
    }
    if let Err(error) =
        crate::commands::rule_sets::migrate_current_config_to_managed_cn_rule_sets(app.handle())
    {
        log::warn!("[RULE-SETS] Failed to migrate existing config: {error}");
    }
    crate::commands::rule_sets::spawn_cn_rule_set_refresh_task(app.handle().clone());
    report_main_window_geometry(app);

    // macOS：以无 Dock 图标的附件模式运行，启动时直接显示主窗口
    // 此模式下，访达点击已运行 App 图标时触发 Reopen 事件，需要监听此事件将隐藏的主窗口重新显示
    #[cfg(target_os = "macos")]
    {
        app.set_activation_policy(tauri::ActivationPolicy::Accessory);
        if let Some(w) = app.get_webview_window("main") {
            if let Err(error) = w.show() {
                log::warn!("failed to show main window during setup: {error}");
            }
            if let Err(error) = w.set_focus() {
                log::warn!("failed to focus main window during setup: {error}");
            }
        }
    }
    // On Linux release builds the deb/rpm .desktop file already declares
    // MimeType with `Exec=… %u`, so register_all() would create a duplicate
    // handler desktop file causing the OS to prompt the user to choose.
    // Only call register_all() in debug builds (no deb install) and on
    // Windows debug builds.
    #[cfg(all(debug_assertions, any(target_os = "linux", windows)))]
    {
        app.deep_link().register_all()?;
    }

    // On Windows release builds the NSIS installer writes HKLM. But any
    // prior `tauri dev` run wrote HKCU pointing at the dev exe, and HKCU
    // wins over HKLM during protocol resolution — so deep links launch a
    // stale/missing dev binary and silently fail. Scrub HKCU so HKLM
    // becomes authoritative; no-op if HKCU was never populated.
    #[cfg(all(not(debug_assertions), windows))]
    clear_stale_hkcu_deep_link();

    register_deep_link(app);

    // Cold-start on Windows/Linux: handle_cli_arguments() runs during plugin
    // initialisation, before on_open_url is registered. Keep the first payload
    // in app state so the frontend can consume it once the webview is ready.
    #[cfg(any(windows, target_os = "linux"))]
    if let Ok(Some(urls)) = app.deep_link().get_current() {
        if let Some(payload) = urls.first().and_then(extract_deep_link_data) {
            log::info!(
                "[deep-link] cold-start config payload received bytes={} apply={}",
                payload.data.len(),
                payload.apply
            );
            store_pending_deep_link(&app.state::<crate::app::state::AppData>(), payload);
        }
    }

    Ok(())
}

fn secure_app_config_directory(app: &tauri::AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let directory = app.path().app_config_dir()?;
    secure_private_directory(&directory)?;
    Ok(())
}

fn secure_private_directory(directory: &std::path::Path) -> std::io::Result<()> {
    std::fs::create_dir_all(directory)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

#[cfg(target_os = "windows")]
fn stop_orphan_tun_service_on_startup() {
    use tun_service::scm::{self, QueriedState};

    match scm::query_state() {
        QueriedState::Running | QueriedState::StartPending => {
            log::warn!(
                "[service] OneBoxTunService was running before engine-state ownership; stopping orphan"
            );
            if let Err(e) = scm::stop_service() {
                log::warn!("[service] failed to stop orphan OneBoxTunService: {}", e);
            }
        }
        _ => {}
    }
}

#[cfg(not(target_os = "windows"))]
fn stop_orphan_tun_service_on_startup() {}

fn report_main_window_geometry(app: &tauri::App) {
    let Some(window) = app.get_webview_window("main") else {
        log::warn!("[window-geometry] main window not found during setup");
        return;
    };

    let inner = window.inner_size().ok();
    let outer = window.outer_size().ok();
    let scale_factor = window.scale_factor().ok();
    let monitor = window.current_monitor().ok().flatten();

    let monitor_summary = monitor
        .as_ref()
        .map(|m| {
            let size = m.size();
            let position = m.position();
            format!(
                "name={:?} size={}x{} position={}x{} scale_factor={}",
                m.name(),
                size.width,
                size.height,
                position.x,
                position.y,
                m.scale_factor()
            )
        })
        .unwrap_or_else(|| "none".to_string());

    log::info!(
        "[window-geometry] inner={:?} outer={:?} scale_factor={:?} monitor={}",
        inner,
        outer,
        scale_factor,
        monitor_summary
    );
}

// ── Deep Link ──────────────────────────────────────────────────────

const MAX_DEEP_LINK_DATA_BYTES: usize = 64 * 1024;

/// 从 `nekopilot://config?data=...&apply=1` 中提取参数
fn extract_deep_link_data(url: &Url) -> Option<crate::app::state::DeepLinkPayload> {
    if url.scheme() != "nekopilot" || url.host_str() != Some("config") {
        return None;
    }
    let params: std::collections::HashMap<_, _> = url.query_pairs().collect();
    let data = params.get("data")?.to_string();
    if data.is_empty() || data.len() > MAX_DEEP_LINK_DATA_BYTES {
        log::warn!(
            "[deep-link] rejected config payload bytes={} (allowed 1..={})",
            data.len(),
            MAX_DEEP_LINK_DATA_BYTES
        );
        return None;
    }
    let apply = params.get("apply").map(|v| v == "1").unwrap_or(false);
    Some(crate::app::state::DeepLinkPayload { data, apply })
}

/// 将 deep link payload 写入 pending state
fn store_pending_deep_link(
    app_data: &crate::app::state::AppData,
    payload: crate::app::state::DeepLinkPayload,
) {
    if let Ok(mut pending) = app_data.pending_deep_link.lock() {
        *pending = Some(payload);
    }
}

#[cfg(all(not(debug_assertions), windows))]
fn clear_stale_hkcu_deep_link() {
    use windows::core::PCWSTR;
    use windows::Win32::System::Registry::{RegDeleteTreeW, HKEY_CURRENT_USER};
    let path: Vec<u16> = "Software\\Classes\\nekopilot\0".encode_utf16().collect();
    let rc = unsafe { RegDeleteTreeW(HKEY_CURRENT_USER, PCWSTR(path.as_ptr())) };
    log::info!(
        "[deep-link] HKCU cleanup rc={:?} (NSIS HKLM is authoritative)",
        rc.0
    );
}

/// 注册 deep link 回调
fn register_deep_link(app: &tauri::App) {
    let handle = app.handle().clone();
    app.deep_link().on_open_url(move |event| {
        let urls = event.urls();
        log::info!("[deep-link] received {} URL(s)", urls.len());
        show_dashboard(handle.clone());

        if let Some(payload) = urls.first().and_then(extract_deep_link_data) {
            log::info!(
                "[deep-link] config payload received bytes={} apply={}",
                payload.data.len(),
                payload.apply
            );
            // 写入 state（冷/热启动都靠前端主动拉取，保证可靠）
            store_pending_deep_link(&handle.state::<crate::app::state::AppData>(), payload);
            // 发送无 payload 的信号：前端收到后主动 invoke get_pending_deep_link。
            // 若 WebView 尚未就绪（窗口从隐藏恢复时），信号可能丢失，
            // 但前端同时监听 tauri://focus 作为兜底，数据不会丢。
            handle.emit("deep_link_pending", ()).unwrap_or_else(|e| {
                log::error!("Failed to emit deep_link_pending signal: {}", e);
            });
        }
    });
}

// ── Lifecycle ──────────────────────────────────────────────────────

// 断网时长低于此值视为短暂抖动，不触发重启
#[cfg(any(target_os = "windows", target_os = "macos"))]
const MIN_OUTAGE: std::time::Duration = std::time::Duration::from_secs(2);
// NetworkUp / DidWake 后等待此时长确认系统稳定，再执行重启
#[cfg(any(target_os = "windows", target_os = "macos"))]
const DEBOUNCE_SECS: u64 = 3;
// macOS 唤醒后，默认路由和 networksetup 服务映射可能比 NetworkUp 晚到。
// 只在系统代理模式下探测；手动代理无需依赖 macOS 网络服务。
#[cfg(target_os = "macos")]
const MACOS_INTERFACE_RETRY_INTERVAL: std::time::Duration = std::time::Duration::from_secs(2);
#[cfg(target_os = "macos")]
const MACOS_INTERFACE_RETRY_ATTEMPTS: u8 = 10;
// 睡眠时长 >= 此值才触发 wake 重启。30s 足以过滤"临时锁屏-解锁"
// 但会覆盖"开会合盖几分钟"这种真实场景。
#[cfg(any(target_os = "windows", target_os = "macos"))]
const WAKE_RESTART_THRESHOLD: std::time::Duration = std::time::Duration::from_secs(30);

/// 调度引擎重启：DEBOUNCE_SECS 秒后若 epoch 未变则重启。
/// macOS 系统代理模式会先有限等待默认网络服务就绪；等待超时不停止现有引擎。
/// NetworkUp / DidWake 共用此路径，`ctx` 仅用于日志前缀区分触发源。
///
/// 调用方负责在调度前 `fetch_add(1)` 自增 epoch（幂等取消：后来的调度
/// 让之前已排队的任务读到不同 epoch，自动放弃）。
#[cfg(target_os = "macos")]
async fn wait_for_macos_proxy_service(
    epoch_arc: &std::sync::Arc<std::sync::atomic::AtomicU64>,
    current_epoch: u64,
    ctx: &str,
) -> bool {
    for attempt in 0..=MACOS_INTERFACE_RETRY_ATTEMPTS {
        if epoch_arc.load(std::sync::atomic::Ordering::Relaxed) != current_epoch {
            log::info!("[{ctx}] epoch changed while waiting for macOS network service");
            return false;
        }

        match crate::engine::sysproxy::active_macos_proxy_service() {
            Ok(service) => {
                if attempt > 0 {
                    log::info!(
                        "[{ctx}] macOS network service {service:?} ready after {}s",
                        attempt as u64 * MACOS_INTERFACE_RETRY_INTERVAL.as_secs()
                    );
                }
                return true;
            }
            Err(error) if attempt == MACOS_INTERFACE_RETRY_ATTEMPTS => {
                log::warn!(
                    "[{ctx}] macOS network service was not ready after {}s ({error}); preserving the existing engine",
                    attempt as u64 * MACOS_INTERFACE_RETRY_INTERVAL.as_secs()
                );
                return false;
            }
            Err(error) => {
                log::info!(
                    "[{ctx}] macOS network service not ready (attempt {}/{}, {error}); retrying in {}s",
                    attempt + 1,
                    MACOS_INTERFACE_RETRY_ATTEMPTS,
                    MACOS_INTERFACE_RETRY_INTERVAL.as_secs()
                );
                tokio::time::sleep(MACOS_INTERFACE_RETRY_INTERVAL).await;
            }
        }
    }

    unreachable!("the bounded retry loop always returns")
}

#[cfg(any(target_os = "windows", target_os = "macos"))]
fn schedule_engine_restart(
    handle: tauri::AppHandle,
    epoch_arc: std::sync::Arc<std::sync::atomic::AtomicU64>,
    ctx: &'static str,
) {
    let current_epoch = epoch_arc.load(std::sync::atomic::Ordering::Relaxed);
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(DEBOUNCE_SECS)).await;
        if epoch_arc.load(std::sync::atomic::Ordering::Relaxed) != current_epoch {
            log::info!("[{ctx}] epoch changed, aborting engine restart");
            return;
        }
        let engine_state = handle
            .state::<crate::engine::state_machine::EngineStateCell>()
            .snapshot();
        if !matches!(
            engine_state,
            crate::engine::state_machine::EngineState::Running { .. }
        ) {
            return;
        }
        let expected_engine_epoch = engine_state.epoch();
        let Some((mode, path)) = crate::core::get_running_config() else {
            return;
        };
        #[cfg(target_os = "macos")]
        if matches!(&mode, crate::core::ProxyMode::SystemProxy)
            && !wait_for_macos_proxy_service(&epoch_arc, current_epoch, ctx).await
        {
            return;
        }
        if epoch_arc.load(std::sync::atomic::Ordering::Relaxed) != current_epoch {
            log::info!("[{ctx}] epoch changed, aborting engine restart");
            return;
        }
        log::info!("[{ctx}] restarting engine (mode: {:?})", mode);
        match crate::core::restart_if_running(handle, path, mode, expected_engine_epoch).await {
            Ok(true) => log::info!("[{ctx}] engine restarted"),
            Ok(false) => log::info!("[{ctx}] restart skipped because engine session changed"),
            Err(e) => log::error!("[{ctx}] engine restart failed: {}", e),
        }
    });
}

/// 生命周期事件监听：仅 Windows / macOS 支持。
///
/// **macOS**：必须在 `RunEvent::Ready` 时调用，确保 delegate 安装在 Tauri/WRY 之后，
/// 不会被覆盖。
#[cfg(any(target_os = "windows", target_os = "macos"))]
pub(crate) fn spawn_lifecycle_listener(app_handle: &tauri::AppHandle) {
    let handle = app_handle.clone();

    let rx = onebox_lifecycle::Sentinel::start().into_receiver();

    if let Err(error) = std::thread::Builder::new()
        .name("lifecycle-events".into())
        .spawn(move || {
            // 网络恢复重启：防抖 + 最小断网时长双重过滤
            //
            // epoch：每次 NetworkDown 自增，用于取消正在等待的重启任务（无锁取消）。
            // network_down_at：记录断网墙钟时间，过滤短暂抖动（< MIN_OUTAGE）。
            //
            // 策略：
            //   NetworkDown → epoch++，记录断网时间，取消已排队的重启
            //   NetworkUp   → 若断网时长 < MIN_OUTAGE 则跳过（短暂抖动）
            //                 否则等待 DEBOUNCE_SECS 秒确认网络稳定，期间若再次断网
            //                 则 epoch 已变，任务自动放弃，不会触发重启
            //
            // Windows 7 / 8 / 8.1：NotifyNetworkConnectivityHintChange 不可用，
            // lifecycle 库不会产生任何 NetworkUp / NetworkDown 事件，
            // 以下逻辑永远不会被触发，行为与未启用 network feature 时完全相同。
            let network_restart_epoch = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
            let mut network_down_at: Option<std::time::SystemTime> = None;
            // WillSleep 墙钟时间。DidWake 时与此值对比判断是否需要重启引擎。
            // NWPathMonitor 在睡眠期间挂起且带 satisfied 去重，Wi-Fi
            // 不 drop 的场景（Power Nap / 电源常连）唤醒后不会补发任何事件，
            // 恢复链路完全断在这里——所以不能只依赖 NetworkUp。
            let mut will_sleep_at: Option<std::time::SystemTime> = None;

            while let Some(event) = rx.recv() {
                use onebox_lifecycle::SystemEvent;
                match event {
                    SystemEvent::ShuttingDown(shutdown_handle) => {
                        handle_shutting_down(shutdown_handle);
                    }
                    SystemEvent::WillPowerOff => {
                        handle_will_power_off();
                    }
                    SystemEvent::WillSleep => {
                        log::info!("[wake] WillSleep");
                        will_sleep_at = Some(std::time::SystemTime::now());
                    }
                    SystemEvent::DidWake => {
                        let sleep_dur = will_sleep_at
                            .take()
                            .and_then(|t| t.elapsed().ok())
                            .unwrap_or_default();
                        log::info!("[wake] DidWake — slept {:.1}s", sleep_dur.as_secs_f32());

                        // 幂等地刷一次 TUN DNS。睡眠期间 mDNSResponder 可能已被
                        // 系统回写为 DHCP 下发的服务器；这一次调用在非 TUN 模式
                        // 下是 no-op（见 on_network_up 里的 mode gate）。
                        use crate::engine::{EngineManager, PlatformEngine};
                        PlatformEngine::on_network_up(&handle);

                        if sleep_dur < WAKE_RESTART_THRESHOLD {
                            log::info!(
                                "[wake] sleep {:.1}s < threshold, skipping restart",
                                sleep_dur.as_secs_f32()
                            );
                            continue;
                        }

                        // 走和 NetworkUp 同一套 epoch + debounce：若期间又发
                        // NetworkDown/NetworkUp，epoch 自增会让本任务自动放弃。
                        network_restart_epoch.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        log::info!(
                            "[wake] sleep {:.1}s — scheduling engine restart in {}s",
                            sleep_dur.as_secs_f32(),
                            DEBOUNCE_SECS
                        );
                        schedule_engine_restart(
                            handle.clone(),
                            std::sync::Arc::clone(&network_restart_epoch),
                            "wake",
                        );
                    }
                    SystemEvent::NetworkDown => {
                        log::info!("[network] NetworkDown — cancelling any pending engine restart");
                        network_restart_epoch.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        network_down_at = Some(std::time::SystemTime::now());
                        // Release Setup DNS so OS-native captive detection on
                        // the next NetworkUp has a clean State layer to probe.
                        // macOS-only; Windows/Linux use trait default no-op.
                        // See docs/claude/dns-override.md.
                        use crate::engine::{EngineManager, PlatformEngine};
                        PlatformEngine::on_network_down(&handle);
                    }
                    SystemEvent::NetworkUp => {
                        log::info!("[network] NetworkUp");
                        // 立即重设 TUN DNS —— 幂等操作,无需防抖。Wi-Fi 切换后系统
                        // 会把活动接口 DNS 重置回 DHCP 下发的服务器,哪怕后续的
                        // engine 重启被 MIN_OUTAGE 过滤掉,这一步仍然保证 DNS 继续
                        // 指向 TUN 网关。
                        //
                        // 延迟 1s 再做一次,兜底系统在 NetworkUp 事件之后的"慢一拍"
                        // DNS 写入(DHCP 续租、IPv6 RA、NetworkManager dispatcher 等)。
                        use crate::engine::{EngineManager, PlatformEngine};
                        PlatformEngine::on_network_up(&handle);
                        let handle_for_retry = handle.clone();
                        tauri::async_runtime::spawn(async move {
                            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                            PlatformEngine::on_network_up(&handle_for_retry);
                        });
                        let down_at = match network_down_at.take() {
                            Some(t) => t,
                            // 初始快照就是 Up（应用刚启动时网络正常），忽略
                            None => continue,
                        };
                        let outage = down_at.elapsed().unwrap_or_default();
                        if outage < MIN_OUTAGE {
                            log::info!(
                                "[network] outage {:.1}s < threshold, skipping restart",
                                outage.as_secs_f32()
                            );
                            continue;
                        }
                        log::info!(
                            "[network] outage {:.1}s — scheduling engine restart in {}s",
                            outage.as_secs_f32(),
                            DEBOUNCE_SECS
                        );
                        // 取消可能被 DidWake 预先排的 wake 重启——epoch 自增一次
                        // 后新旧两个已排队任务中只有我们刚刚捕获的那个能通过检查。
                        network_restart_epoch.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        schedule_engine_restart(
                            handle.clone(),
                            std::sync::Arc::clone(&network_restart_epoch),
                            "network",
                        );
                    }
                    _ => {}
                }
            }
        })
    {
        log::error!("failed to spawn lifecycle listener: {error}");
    }
}

#[cfg(any(target_os = "windows", target_os = "macos"))]
fn handle_shutting_down(shutdown_handle: onebox_lifecycle::ShutdownHandle) {
    use crate::engine::cleanup_on_shutdown;
    log::info!("[lifecycle] received ShuttingDown event");
    cleanup_on_shutdown();
    shutdown_handle.allow();
    log::info!("[lifecycle] shutdown allowed");
}

#[cfg(any(target_os = "windows", target_os = "macos"))]
fn handle_will_power_off() {
    use crate::engine::cleanup_on_shutdown;
    log::info!("[lifecycle] received WillPowerOff event");
    cleanup_on_shutdown();
    log::info!("System proxy unset on power off");
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[cfg(unix)]
    #[test]
    fn app_config_directory_is_private_to_the_current_user() {
        let root = tempfile::tempdir().expect("temporary directory");
        let directory = root.path().join("config");
        super::secure_private_directory(&directory).expect("secure directory");
        let mode = std::fs::metadata(directory)
            .expect("directory metadata")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o700);
    }

    use super::extract_deep_link_data;
    use url::Url;

    #[test]
    fn accepts_the_nekopilot_config_scheme() {
        let url = Url::parse("nekopilot://config?data=example&apply=1").unwrap();
        let payload = extract_deep_link_data(&url).expect("valid NekoPilot deep link");
        assert_eq!(payload.data, "example");
        assert!(payload.apply);
    }

    #[test]
    fn rejects_the_removed_onebox_scheme() {
        let url = Url::parse("oneoh-networktools://config?data=example").unwrap();
        assert!(extract_deep_link_data(&url).is_none());
    }

    #[test]
    fn deep_link_payload_is_nonempty_and_bounded() {
        let empty = Url::parse("nekopilot://config?data=").unwrap();
        assert!(extract_deep_link_data(&empty).is_none());

        let exact = Url::parse(&format!(
            "nekopilot://config?data={}",
            "a".repeat(super::MAX_DEEP_LINK_DATA_BYTES)
        ))
        .unwrap();
        assert_eq!(
            extract_deep_link_data(&exact).unwrap().data.len(),
            super::MAX_DEEP_LINK_DATA_BYTES
        );

        let oversized = Url::parse(&format!(
            "nekopilot://config?data={}",
            "a".repeat(super::MAX_DEEP_LINK_DATA_BYTES + 1)
        ))
        .unwrap();
        assert!(extract_deep_link_data(&oversized).is_none());
    }
}
