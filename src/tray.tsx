import { defaultWindowIcon } from "@tauri-apps/api/app";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Image } from "@tauri-apps/api/image";
import { Menu, MenuOptions } from "@tauri-apps/api/menu";
import { TrayIcon, TrayIconEvent } from "@tauri-apps/api/tray";
import { message } from "@tauri-apps/plugin-dialog";
import { type } from "@tauri-apps/plugin-os";
import { getProxyPort } from "./single/store";
import type { StatusChangedPayload } from "./types/definition";
import { ENGINE_STATE_EVENT, type EngineState } from "./types/engine-state";
import {
  copyEnvToClipboard,
  initLanguage,
  t,
  vpnServiceManager,
} from "./utils/helper";

// 常量
const PROXY_HOST = "127.0.0.1";
const TRAY_ICON_ID = "nekopilot-menu-bar";
// Native lifecycle events update the tray immediately. This is only a
// low-frequency fallback for an unexpected child-process exit.
const STATUS_POLL_INTERVAL = 10_000;

let trayInstance: TrayIcon | null = null;
let traySetupPromise: Promise<TrayIcon | null> | null = null;
let lastEngineState: EngineState["kind"] | null = null;
let statusPollerId: number | null = null;
let statusPollInFlight = false;
let toggleInFlight = false;
let trayMenuUpdatePromise: Promise<void> | null = null;
let trayMenuUpdateRequested = false;
let idleTrayIcon: Image | Uint8Array | null = null;
let runningTrayIcon: Image | null = null;

const RUNNING_ICON_COLOR = [52, 199, 89] as const;

// The Rust engine state is authoritative. Treating `Starting` as disabled
// made the tray look stale until the old 10-second fallback poll ran, even
// after macOS had already applied the system proxy.
async function getEngineState(): Promise<EngineState> {
  return await invoke<EngineState>("get_engine_state");
}

function isProxyEnabled(state: EngineState): boolean {
  return state.kind === "starting" || state.kind === "running";
}

function isStateTransitioning(state: EngineState): boolean {
  return state.kind === "starting" || state.kind === "stopping";
}

function isRunning(state: EngineState): boolean {
  return state.kind === "running";
}

// 切换代理状态
async function toggleProxyStatus(status: boolean) {
  if (toggleInFlight) return;

  toggleInFlight = true;
  try {
    if (status) {
      await vpnServiceManager.stop();
    } else {
      const configReady = await vpnServiceManager.syncConfig({
        onError: async () => {
          await message(t("connect_failed"), {
            title: t("error"),
            kind: "error",
          });
        },
      });
      if (!configReady) return;
      await vpnServiceManager.start();
    }
  } catch (error) {
    console.error("Failed to toggle proxy from the tray:", error);
    // start() already presents its actionable error. stop() has no other UI
    // caller here, so surface that failure from the tray action itself.
    if (status) {
      await message(t("connect_failed"), {
        title: t("error"),
        kind: "error",
      });
    }
  } finally {
    toggleInFlight = false;
    await updateTrayMenu();
  }
}

// 创建基础菜单项
async function createBaseMenuItems(
  state: EngineState,
): Promise<NonNullable<MenuOptions["items"]>> {
  const proxyPort = await getProxyPort();
  const enabled = isProxyEnabled(state);
  const transitioning = isStateTransitioning(state);
  return [
    {
      id: "show",
      text: t("menu_dashboard"),
    },
    {
      id: "enable",
      text: t("menu_enable_proxy"),
      checked: enabled,
      // Reject a second click while the same start/stop request is
      // still settling. This avoids queuing a contradictory lifecycle
      // operation behind the first one.
      enabled: !transitioning && !toggleInFlight,
      action: () => toggleProxyStatus(enabled),
    },
    {
      id: "copy_proxy",
      text: t("menu_copy_env"),
      action: () => copyEnvToClipboard(PROXY_HOST, proxyPort.toString()),
    },
  ];
}

// 创建托盘菜单
async function createTrayMenu(state?: EngineState) {
  await initLanguage();

  const currentState = state ?? (await getEngineState());
  lastEngineState = currentState.kind;

  const baseItems = await createBaseMenuItems(currentState);

  const menuItems = [
    ...baseItems,
    {
      id: "quit",
      text: t("menu_quit"),
    },
  ];

  return await Menu.new({ items: menuItems });
}

// 低频兜底轮询状态；正常状态变化由 engine-state 事件立即推送。
function startStatusPolling() {
  if (statusPollerId !== null) return;

  statusPollerId = window.setInterval(async () => {
    if (statusPollInFlight) return;

    statusPollInFlight = true;
    try {
      const state = await getEngineState();
      if (lastEngineState !== null && state.kind !== lastEngineState) {
        lastEngineState = state.kind;
        await updateTrayMenu();
      } else if (lastEngineState === null) {
        lastEngineState = state.kind;
      }
    } catch (error) {
      console.error("Failed to poll running status:", error);
    } finally {
      statusPollInFlight = false;
    }
  }, STATUS_POLL_INTERVAL);
}

// 处理托盘图标事件
async function handleTrayIconAction(event: TrayIconEvent) {
  if (event.type === "Leave") {
    await updateTrayMenu();
  }
}

async function getTrayIconImage(
  running: boolean,
): Promise<Image | Uint8Array | undefined> {
  const macos = type() === "macos";
  if (macos && running && runningTrayIcon) return runningTrayIcon;
  if ((!macos || !running) && idleTrayIcon) return idleTrayIcon;

  let trayIconData: Uint8Array | undefined;
  try {
    const rawTrayIconData = await invoke<number[]>("get_tray_icon");
    if (rawTrayIconData.length > 0) {
      trayIconData = new Uint8Array(rawTrayIconData);
    }
  } catch (error) {
    console.warn("Failed to decode the menu-bar icon.", error);
  }

  if (!macos) {
    const icon = trayIconData !== undefined
      ? await Image.fromBytes(trayIconData)
      : (await defaultWindowIcon()) ?? undefined;
    if (icon) idleTrayIcon = icon;
    return icon;
  }

  // Hand the untouched PNG directly to the native tray API while idle. This
  // avoids WebView image decoding on macOS, which could fall back to the
  // colourful application icon instead of the intended template mask.
  if (!trayIconData) return undefined;
  if (!running) {
    idleTrayIcon = trayIconData;
    return trayIconData;
  }

  // Keep the idle image as a macOS template so it adapts to light and dark
  // menu bars. Once sing-box is actually Running, recolor that same alpha
  // mask with the macOS system-green accent for an at-a-glance state cue.
  const icon = await Image.fromBytes(trayIconData);
  const rgba = await icon.rgba();
  for (let offset = 0; offset < rgba.length; offset += 4) {
    if (rgba[offset + 3] === 0) continue;
    rgba[offset] = RUNNING_ICON_COLOR[0];
    rgba[offset + 1] = RUNNING_ICON_COLOR[1];
    rgba[offset + 2] = RUNNING_ICON_COLOR[2];
  }
  const size = await icon.size();
  runningTrayIcon = await Image.new(rgba, size.width, size.height);
  return runningTrayIcon;
}

async function updateTrayIcon(state: EngineState) {
  if (!trayInstance) return;

  const running = isRunning(state);
  const icon = await getTrayIconImage(running);
  if (!icon) return;

  // A running icon must not be a template; macOS would otherwise turn its
  // green pixels back into the same monochrome idle icon.
  await trayInstance.setIconWithAsTemplate(
    icon,
    type() === "macos" && !running,
  );
}

// 创建托盘图标配置
async function createTrayIconOptions(menu: Menu, state: EngineState) {
  const running = isRunning(state);
  const icon = await getTrayIconImage(running);
  const options = {
    id: TRAY_ICON_ID,
    menu,
    iconAsTemplate: type() === "macos" && !running,
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
        const state = await getEngineState();
        await updateTrayIcon(state);
        // Rebind menu callbacks to this WebView context after a renderer
        // reload; the native tray item can outlive its previous JS handlers.
        await trayInstance.setMenu(await createTrayMenu(state));
        startStatusPolling();
        return trayInstance;
      }
      const state = await getEngineState();
      const menu = await createTrayMenu(state);
      const options = await createTrayIconOptions(menu, state);

      trayInstance = await TrayIcon.new(options);

      startStatusPolling();
      return trayInstance;
    } catch (error) {
      console.error("Error setting up tray icon:", error);
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
export function updateTrayMenu(): Promise<void> {
  // Starting → Running and Stopping → Idle can arrive back-to-back.
  // Collapse bursts into the newest authoritative snapshot instead of
  // rebuilding several native menus in sequence.
  trayMenuUpdateRequested = true;
  if (trayMenuUpdatePromise) return trayMenuUpdatePromise;

  const update = (async () => {
    while (trayMenuUpdateRequested) {
      trayMenuUpdateRequested = false;
      if (!trayInstance) continue;

      const state = await getEngineState();
      await updateTrayIcon(state);
      const newMenu = await createTrayMenu(state);
      await trayInstance.setMenu(newMenu);
    }
  })().catch((error) => {
    console.error("Failed to update tray menu:", error);
  });
  trayMenuUpdatePromise = update;
  void update.finally(() => {
    if (trayMenuUpdatePromise !== update) return;
    trayMenuUpdatePromise = null;
    if (trayMenuUpdateRequested) void updateTrayMenu();
  });
  return update;
}

// 处理连接失败
async function handleConnectionError() {
  const [info, error] = await Promise.all([
    invoke<string>("read_logs", { isError: false }),
    invoke<string>("read_logs", { isError: true }),
  ]);

  let msg = t("connect_failed_retry");

  if (info && info.trim().length > 0) {
    msg += `\n\n${info}`;
  }

  if (error && error.trim().length > 0) {
    msg += `\n\n${error}`;
  }

  await message(
    msg,
    { title: t("error"), kind: "error" },
  );
}

// 监听状态变化
export async function setupStatusListener() {
  // `engine-state` is emitted for Starting, Running, Stopping, Idle, and
  // Failed transitions. It is the normal immediate tray-update path;
  // polling below is only retained as a recovery path if an event is lost.
  await listen<EngineState>(ENGINE_STATE_EVENT, async () => {
    await updateTrayMenu();
  });

  await listen<StatusChangedPayload>("status-changed", async ({ payload }) => {
    if (payload?.code === 1) {
      await handleConnectionError();
    }

    await updateTrayMenu();
  });
}

// 监听错误日志事件
export async function setupTauriLogListener() {
  await listen<[code: number, message: string]>("tauri-log", ({ payload }) => {
    if (!Array.isArray(payload) || typeof payload[0] !== "number" ||
      typeof payload[1] !== "string") return;

    const [code, logMessage] = payload;
    if (code === 1) console.error(logMessage);
    else if (code >= 2) console.warn(logMessage);
  });
}
