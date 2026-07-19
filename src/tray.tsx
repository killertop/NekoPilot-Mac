import { defaultWindowIcon } from '@tauri-apps/api/app';
import { invoke } from "@tauri-apps/api/core";
import { listen } from '@tauri-apps/api/event';
import { Image } from '@tauri-apps/api/image';
import { Menu, MenuOptions } from '@tauri-apps/api/menu';
import { TrayIcon, TrayIconEvent } from '@tauri-apps/api/tray';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { message } from '@tauri-apps/plugin-dialog';
import { type } from '@tauri-apps/plugin-os';
import { getClashApiSecret, getProxyPort } from './single/store';
import { copyEnvToClipboard, initLanguage, t, vpnServiceManager } from './utils/helper';

// 常量
const PROXY_HOST = "127.0.0.1";
const TRAY_ICON_ID = "nekopilot-menu-bar";
// Native lifecycle events update the tray immediately. This is only a
// low-frequency fallback for an unexpected child-process exit.
const STATUS_POLL_INTERVAL = 10_000;

const appWindow = getCurrentWindow();
let trayInstance: TrayIcon | null = null;
let traySetupPromise: Promise<TrayIcon | null> | null = null;
let lastStatus: boolean | null = null;
let statusPollerId: number | null = null;
let statusPollInFlight = false;

// 获取当前运行状态
async function getRunningStatus(): Promise<boolean> {
    const secret = await getClashApiSecret();
    return await invoke<boolean>("is_running", { secret });
}

// 设置窗口控制按钮事件
function setupWindowControls() {
    document
        .getElementById('titlebar-minimize')
        ?.addEventListener('click', () => appWindow.minimize());
    document
        .getElementById('titlebar-maximize')
        ?.addEventListener('click', () => appWindow.toggleMaximize());
    document
        .getElementById('titlebar-close')
        ?.addEventListener('click', () => appWindow.hide());
}

// 切换代理状态
async function toggleProxyStatus(status: boolean) {
    if (status) {
        await vpnServiceManager.stop();
    } else {
        await vpnServiceManager.syncConfig({});
        await vpnServiceManager.start();
    }
    await updateTrayMenu();
}

// 创建基础菜单项
async function createBaseMenuItems(status: boolean): Promise<NonNullable<MenuOptions['items']>> {
    const proxyPort = await getProxyPort();
    return [
        {
            id: 'show',
            text: t("menu_dashboard"),
        },
        {
            id: "enable",
            text: t("menu_enable_proxy"),
            checked: status,
            enabled: true,
            action: () => toggleProxyStatus(status),
        },
        {
            id: 'copy_proxy',
            text: t("menu_copy_env"),
            action: () => copyEnvToClipboard(PROXY_HOST, proxyPort.toString()),
        },
    ];
}

// 创建托盘菜单
async function createTrayMenu() {
    await initLanguage();

    const status = await getRunningStatus();
    lastStatus = status;

    setupWindowControls();

    const baseItems = await createBaseMenuItems(status);

    const menuItems = [
        ...baseItems,
        {
            id: 'quit',
            text: t("menu_quit"),
        },
    ];

    return await Menu.new({ items: menuItems });
}

// 低频兜底轮询状态；正常状态变化由 status-changed 事件立即推送。
function startStatusPolling() {
    if (statusPollerId !== null) return;

    statusPollerId = window.setInterval(async () => {
        if (statusPollInFlight) return;

        statusPollInFlight = true;
        try {
            const status = await getRunningStatus();
            if (lastStatus !== null && status !== lastStatus) {
                lastStatus = status;
                await updateTrayMenu();
            } else if (lastStatus === null) {
                lastStatus = status;
            }
        } catch (error) {
            console.error('Failed to poll running status:', error);
        } finally {
            statusPollInFlight = false;
        }
    }, STATUS_POLL_INTERVAL);
}

// 处理托盘图标事件
async function handleTrayIconAction(event: TrayIconEvent) {
    if (event.type === 'Leave') {
        await updateTrayMenu();
    }
}

// 创建托盘图标配置
async function createTrayIconOptions(menu: Menu) {
    // Decode the PNG before passing it to the tray API. A Rust Vec<u8> crosses
    // the IPC boundary as a number array, and supplying it directly can leave
    // macOS with an empty status item instead of an icon.
    const defaultIcon = await defaultWindowIcon();
    let icon = defaultIcon;
    try {
        const trayIconData = await invoke<number[]>('get_tray_icon', { app: appWindow });
        if (trayIconData.length > 0) {
            icon = await Image.fromBytes(new Uint8Array(trayIconData));
        }
    } catch (error) {
        console.warn('Failed to decode the menu-bar icon; using the app icon.', error);
    }

    const options = {
        id: TRAY_ICON_ID,
        menu,
        iconAsTemplate: type() === 'macos',
        tooltip: "NekoPilot",
        action: handleTrayIconAction,
    };
    return icon ? { ...options, icon } : options;
}

// 初始化托盘
export async function setupTrayIcon() {
    if (trayInstance) return trayInstance;
    if (traySetupPromise) return traySetupPromise;

    const setup = (async () => {
      try {
            // A page reload can re-evaluate this module while the native tray item
            // still exists. Reuse its stable ID instead of creating another macOS
            // status item. The promise lock above also closes the first-launch
            // race where two callers both observed a null local instance.
            const existing = await TrayIcon.getById(TRAY_ICON_ID);
            if (existing) {
                trayInstance = existing;
                startStatusPolling();
                return trayInstance;
            }
            const menu = await createTrayMenu();
            const options = await createTrayIconOptions(menu);

            trayInstance = await TrayIcon.new(options);

            startStatusPolling();
            return trayInstance;
      } catch (error) {
        console.error('Error setting up tray icon:', error);
        return null;
      }
    })();
    traySetupPromise = setup;
    void setup.finally(() => {
        if (traySetupPromise === setup) traySetupPromise = null;
    });
    return setup;
}

// 更新托盘菜单
export async function updateTrayMenu() {
    if (!trayInstance) return;

    const newMenu = await createTrayMenu();
    await trayInstance.setMenu(newMenu);
}

// 处理连接失败
async function handleConnectionError() {
    const [info, error] = await Promise.all([
        invoke<string>('read_logs', { isError: false }),
        invoke<string>('read_logs', { isError: true }),
    ]);

    console.debug({
        info,
        error,
    })
    let msg = t('connect_failed_retry');

    if (info && info.trim().length > 0) {
        msg += `\n\n${info}`;
    }

    if (error && error.trim().length > 0) {
        msg += `\n\n${error}`;
    }

    await message(
        msg,
        { title: t('error'), kind: 'error' }
    );
}

// 监听状态变化
export async function setupStatusListener() {
    await listen('status-changed', async (event) => {
        if (!event?.payload) return;

        console.log(event);

        // @ts-ignore
        if (event.payload.code === 1) {
            await handleConnectionError();
        }

        await updateTrayMenu();
    });
}

// 监听错误日志事件
export async function setupTauriLogListener() {
    await listen('tauri-log', async (event) => {
        if (!event?.payload) return;

        // @ts-ignore
        const isError = event.payload.code === 1;
        // @ts-ignore
        console[isError ? 'error' : 'log'](event);
    });
}
