import { invoke } from "@tauri-apps/api/core";
import * as path from "@tauri-apps/api/path";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import { arch, locale, type, version } from "@tauri-apps/plugin-os";
import { OsInfo, SING_BOX_VERSION, SSI_STORE_KEY } from "../types/definition";

import { getCurrentWindow } from "@tauri-apps/api/window";
import { message } from "@tauri-apps/plugin-dialog";
import en from "../../lang/en.json";
import zh from "../../lang/zh.json";
import { setMixedConfig } from "../config/merger/main";
import {
  getClashApiSecret,
  getLanguage,
  getSkipSystemProxy,
  getStoreValue,
  getUserAgent,
} from "../single/store";
import { createLifecycleQueue } from "./lifecycle-queue";
import { runConfigSync } from "./config-sync";
const appWindow = getCurrentWindow();
const enLang = en as Record<string, string>;
const zhLang = zh as Record<string, string>;
let currentLanguage: "zh" | "en" = "en";

const languageOptions = {
  en: enLang,
  zh: zhLang,
};

export async function initLanguage() {
  try {
    currentLanguage = await getLanguage() as "zh" | "en";
  } catch (error) {
    console.error("Failed to initialize language:", error);
    currentLanguage = "en";
  }
  return currentLanguage;
}

export async function getOsInfo() {
  const osType = type();
  const osArch = arch();
  const osVersion = version();
  const osLocale = await locale();
  const appVersion = await invoke("get_app_version") as string;

  return {
    appVersion,
    osType,
    osArch,
    osVersion,
    osLocale,
  } as OsInfo;
}

export async function copyEnvToClipboard(
  proxy_host: string,
  proxy_port: string,
) {
  const osType = type();
  let proxyConfig = "";

  if (osType === "windows") {
    proxyConfig =
      `$env:HTTP_PROXY="http://${proxy_host}:${proxy_port}"; $env:HTTPS_PROXY="http://${proxy_host}:${proxy_port}"`;
  } else {
    proxyConfig =
      `export https_proxy=http://${proxy_host}:${proxy_port} \n export http_proxy=http://${proxy_host}:${proxy_port} \n export all_proxy=socks5://${proxy_host}:${proxy_port}`;
  }

  try {
    await writeText(proxyConfig);
    console.log("Proxy configuration copied to clipboard");
  } catch (error) {
    console.error("Failed to copy proxy configuration:", error);
  }
}

export function formatOsInfo(osType: string, osArch: string) {
  let osName = osType;
  if (osType === "windows") {
    osName = "Windows";
  } else if (osType === "linux") {
    osName = "Linux";
  } else if (osType === "macos") {
    osName = "macOS";
  }
  return `${osName} ${osArch}`;
}

export async function getSingBoxUserAgent() {
  const ua = await getUserAgent();
  if (ua && ua.trim() !== "" && ua.trim() !== "default") {
    return ua;
  }
  const osInfo = await getOsInfo();

  let prefix = "SFW";
  if (osInfo.osType === "linux") {
    prefix = "SFL";
  } else if (osInfo.osType === "macos") {
    prefix = "SFM";
  }
  const version = SING_BOX_VERSION.replace("v", "");
  return `${prefix}/${osInfo.appVersion} (${osInfo.osType} ${osInfo.osArch} ${osInfo.osVersion}; sing-box ${version}; language ${osInfo.osLocale})`;
}

export async function getSingBoxConfigPath() {
  const appConfigPath = await path.appConfigDir();
  const filePath = await path.join(appConfigPath, "config.json");
  return filePath;
}

type vpnServiceManagerMode = "SystemProxy" | "ManualProxy";

type SyncConfigProps = {
  onError?: (error: any) => void | Promise<void>;
  onSuccess?: () => void | Promise<void>;
  onRequirePrivileged?: () => void;
};

const CONFIG_RELOAD_DEBOUNCE_MS = 250;

// Configuration writes and sing-box lifecycle calls must not overlap.
const lifecycleQueue = createLifecycleQueue();

type PendingConfigReload = {
  delay: number;
  promise: Promise<void>;
  resolve: () => void;
  reject: (reason: unknown) => void;
};

let pendingConfigReload: PendingConfigReload | undefined;

async function isRunning() {
  let secret = await getClashApiSecret();
  if (!secret) {
    return false;
  }
  return invoke<boolean>("is_running", { secret: secret });
}

async function compileConfig(reloadIfRunning = false) {
  const identifier = await getStoreValue(SSI_STORE_KEY);
  await setMixedConfig(identifier, reloadIfRunning);
}

async function syncConfig(props: SyncConfigProps) {
  return lifecycleQueue.run(() =>
    runConfigSync(
      () => compileConfig(false),
      {
        onSuccess: props.onSuccess,
        onError: async (error) => {
          console.error("Failed to sync VPN config:", error);
          await props.onError?.(error);
        },
      },
    )
  );
}

async function reloadEngine(delay: number) {
  if (!await isRunning()) {
    console.warn("VPN service is not running, cannot reload config");
    return;
  }

  if (delay > 0) {
    await new Promise((resolve) => setTimeout(resolve, delay));
  }

  if (type() === "windows") {
    // Windows 下的系统代理模式需要重启服务
    await invoke("stop", { app: appWindow });
    await new Promise((resolve) => setTimeout(resolve, 1000));
    await vpnServiceManager.start();
  } else {
    await invoke("reload_config");
  }
}

function syncAndReload(delay = 350): Promise<void> {
  if (pendingConfigReload) {
    pendingConfigReload.delay = Math.min(pendingConfigReload.delay, delay);
    return pendingConfigReload.promise;
  }

  let resolve!: () => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<void>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  const pending: PendingConfigReload = { delay, promise, resolve, reject };
  pendingConfigReload = pending;

  setTimeout(() => {
    if (pendingConfigReload === pending) pendingConfigReload = undefined;
    void lifecycleQueue.run(async () => {
      if (pending.delay > 0) {
        await new Promise((resolve) => setTimeout(resolve, pending.delay));
      }
      // macOS/Linux use a single Rust command for write + reload. Windows
      // still requires its platform-specific stop/start path.
      const nativeReload = type() !== "windows";
      await compileConfig(nativeReload);
      if (!nativeReload) {
        await reloadEngine(0);
      }
    }).then(pending.resolve, pending.reject);
  }, CONFIG_RELOAD_DEBOUNCE_MS);

  return promise;
}

export const vpnServiceManager = {
  start: async () => {
    try {
      const configPath = await getSingBoxConfigPath();
      const skipSystemProxy = await getSkipSystemProxy();
      const mode: vpnServiceManagerMode = skipSystemProxy
        ? "ManualProxy"
        : "SystemProxy";
      console.log("启动VPN服务");
      console.log("模式:", mode);
      console.log("配置文件路径:", configPath);

      await invoke("start", { app: appWindow, path: configPath, mode: mode });
    } catch (error: any) {
      console.error("Failed to start VPN service:", error);
      const errorText = String(error?.message ?? error ?? "");
      const occupiedPort = errorText.match(/PORT_OCCUPIED_CANNOT_START:(\d+)/)
        ?.[1];
      if (occupiedPort) {
        await message(
          t(
            "port_occupied_cannot_start",
            { port: occupiedPort },
            "Port {{port}} is occupied and NekoPilot cannot stop the process. Startup aborted.",
          ),
          { title: t("error"), kind: "error" },
        );
        throw error;
      }
      // 如果是权限问题，抛出特定错误让上层处理
      if (errorText.includes("REQUIRE_PRIVILEGE")) {
        throw new Error("REQUIRE_PRIVILEGE");
      }
      await message(t("start_vpn_failed", "Failed to start VPN service"), {
        title: t("error"),
        kind: "error",
      });
      throw error;
    }
  },
  /**
   * 停止VPN服务
   *
   * 此方法调用后端命令停止用户态 sing-box。
   */
  stop: async () => {
    await invoke("stop", { app: appWindow });
  },

  reload: async (delay: number) =>
    lifecycleQueue.run(() => reloadEngine(delay)),
  syncAndReload,
  is_running: async () => await isRunning(),
  syncConfig: syncConfig,
};

// 同步版本的翻译函数
export function t(
  id: string,
  params?: Record<string, any> | string,
  defaultMessage?: string,
): string {
  let translation = languageOptions[currentLanguage][id];

  // 兼容 t('id', 'defaultMessage') 写法
  let realParams: Record<string, any> | undefined;
  let realDefaultMessage: string | undefined;

  if (typeof params === "string") {
    realDefaultMessage = params;
  } else {
    realParams = params;
    realDefaultMessage = defaultMessage;
  }

  if (!translation) {
    console.warn(`Translation for "${id}" not found in "${currentLanguage}"`);
    translation = realDefaultMessage || id;
  }
  if (realParams) {
    Object.keys(realParams).forEach((key) => {
      translation = translation.replace(
        new RegExp(`{{\\s*${key}\\s*}}`, "g"),
        realParams[key],
      );
    });
  }
  return translation;
}
