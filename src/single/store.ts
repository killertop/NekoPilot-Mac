import { invoke } from "@tauri-apps/api/core";
import { locale } from "@tauri-apps/plugin-os";
import {
  emptyRuleSet,
  normalizeRuleSet,
  type RuleAction,
  type RuleSet,
} from "../config/merger/custom-rules";
import {
  ALLOWLAN_STORE_KEY,
  AUTO_SELECT_FASTEST_NODE_STORE_KEY,
  DEFAULT_AUTO_SELECT_FASTEST_NODE,
  DEFAULT_PROXY_PORT,
  PROXY_PORT_STORE_KEY,
  SHOW_NODE_PROTOCOL_STORE_KEY,
  SKIP_SYSTEM_PROXY_STORE_KEY,
  USER_AGENT_STORE_KEY,
} from "../types/definition";

const REMOVED_PREFERENCE_KEYS = [
  "developer_toggle_key",
  "stage_version_key",
  "support_local_file_key",
  "theme_pref_key",
  "custom_ruleset_reject",
  "rule_mode_key",
  "use_dhcp_key",
] as const;

/** Delete obsolete preferences left by earlier builds. */
export async function cleanupRemovedDeveloperSettings(): Promise<void> {
  await Promise.all(
    REMOVED_PREFERENCE_KEYS.map((key) =>
      invoke("delete_setting", { key }).catch((error) => {
        console.warn(`Failed to remove obsolete setting "${key}"`, error);
      }),
    ),
  );
}

/**
 * Resolve the interface language from the operating system on every launch
 * (and focus refresh).  The previous per-app setting is deliberately ignored
 * so an old saved preference cannot override the macOS language.
 */
export const getLanguage = async (): Promise<"zh" | "en"> => {
  const osLocale = await locale();
  return osLocale?.toLowerCase().startsWith("zh") ? "zh" : "en";
};

export async function getStoreValue<T = unknown>(
  key: string,
  defaultValue?: T,
): Promise<T> {
  const value = await invoke<T | null>("get_setting", { key });

  // zh: 如果 defaultValue 存在且 value 为 undefined、null 或空字符串，则返回 val
  // en: If defaultValue exists and value is undefined, null, or an empty string, return val
  if (
    defaultValue !== undefined &&
    (value === undefined || value === null || value === "")
  ) {
    console.debug(`Store key "${key}" is empty, returning default value.`);
    return defaultValue;
  }
  console.debug(`Store key "${key}" found, returning stored value.`);
  return value as T;
}
export async function setStoreValue(key: string, value: unknown): Promise<void> {
  await invoke("set_setting", { key, value });
}

export async function getAllowLan(): Promise<boolean> {
  const b = await getStoreValue(ALLOWLAN_STORE_KEY);
  return Boolean(b);
}

export async function setAllowLan(value: boolean) {
  await setStoreValue(ALLOWLAN_STORE_KEY, value);
}

export async function getAutoSelectFastestNode(): Promise<boolean> {
  const value = await getStoreValue(AUTO_SELECT_FASTEST_NODE_STORE_KEY);
  return value === undefined || value === null
    ? DEFAULT_AUTO_SELECT_FASTEST_NODE
    : Boolean(value);
}

export async function setAutoSelectFastestNode(value: boolean): Promise<void> {
  await setStoreValue(AUTO_SELECT_FASTEST_NODE_STORE_KEY, value);
}

/**
 * Retrieves or generates a Clash API secret from the store.
 *
 * @returns A Promise that resolves to the Clash API secret string.
 * If a secret exists in the store, returns that secret.
 * If no secret exists, generates a new random secret, saves it to the store, and returns it.
 */
export async function getClashApiSecret(): Promise<string> {
  return await invoke<string>("get_or_create_clash_api_secret");
}

export async function getShowNodeProtocol(): Promise<boolean> {
  const b = await getStoreValue(SHOW_NODE_PROTOCOL_STORE_KEY);
  if (b === undefined) {
    return false;
  }
  return Boolean(b);
}

export async function setShowNodeProtocol(value: boolean) {
  await setStoreValue(SHOW_NODE_PROTOCOL_STORE_KEY, value);
}

export async function getSkipSystemProxy(): Promise<boolean> {
  const b = await getStoreValue(SKIP_SYSTEM_PROXY_STORE_KEY);
  return Boolean(b);
}

export async function setSkipSystemProxy(value: boolean) {
  await setStoreValue(SKIP_SYSTEM_PROXY_STORE_KEY, value);
}

export async function setCustomRuleSet(key: RuleAction, config: RuleSet) {
  await setStoreValue(`custom_ruleset_${key}`, JSON.stringify(config));
}

// Missing rule sets from prior builds are read as empty sets.
export async function getCustomRuleSet(key: RuleAction): Promise<RuleSet> {
  const s = await getStoreValue<string | undefined>(`custom_ruleset_${key}`);
  if (s) {
    try {
      const parsed: unknown = JSON.parse(s);
      const config = normalizeRuleSet(parsed);
      if (JSON.stringify(parsed) !== JSON.stringify(config)) {
        await setCustomRuleSet(key, config);
      }
      return config;
    } catch (e) {
      console.error("解析自定义规则集失败:", e);
      const config = emptyRuleSet();
      try {
        await setCustomRuleSet(key, config);
      } catch (repairError) {
        console.warn("Failed to repair invalid custom rule data:", repairError);
      }
      return config;
    }
  }
  return emptyRuleSet();
}

// set dns for direct connection
export async function setDirectDNS(dnsServers: string) {
  await setStoreValue("direct_dns", dnsServers);
}

export async function getDirectDNS(): Promise<string> {
  const s = await getStoreValue<string | undefined>("direct_dns");
  if (s) {
    return s;
  }
  const defaultValue = await invoke<string>("get_optimal_local_dns_server");
  console.debug("最佳DNS服务器为:", defaultValue);
  return defaultValue || "223.5.5.5";
}

// 获取用户设置的 User Agent
export async function getUserAgent(): Promise<string> {
  const ua = await getStoreValue<string | undefined>(USER_AGENT_STORE_KEY);
  if (ua) {
    return ua;
  }
  return "default";
}

// 设置 User Agent
export async function setUserAgent(ua: string) {
  await setStoreValue(USER_AGENT_STORE_KEY, ua);
}

export async function getProxyPort(): Promise<number> {
  const raw = await getStoreValue(PROXY_PORT_STORE_KEY);
  const port = typeof raw === "number" ? raw : Number(raw);
  if (Number.isInteger(port) && port > 0 && port <= 65535) {
    return port;
  }
  return DEFAULT_PROXY_PORT;
}

export async function setProxyPort(port: number): Promise<void> {
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error("invalid_proxy_port");
  }
  await setStoreValue(PROXY_PORT_STORE_KEY, port);
}
