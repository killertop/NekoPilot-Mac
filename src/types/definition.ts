import { Arch, OsType } from "@tauri-apps/plugin-os";
export const SING_BOX_MAJOR_VERSION = "1.13";
export const SING_BOX_MINOR_VERSION = "14";
export const SING_BOX_VERSION =
  `v${SING_BOX_MAJOR_VERSION}.${SING_BOX_MINOR_VERSION}`;

export const SSI_STORE_KEY = "selected_subscription_identifier";
// 是否在节点列表中显示协议类型标签
export const SHOW_NODE_PROTOCOL_STORE_KEY = "show_node_protocol_key";
export const AUTO_SELECT_FASTEST_NODE_STORE_KEY = "auto_select_fastest_node_key";
export const AUTO_SELECT_FASTEST_NODE_CHANGED_EVENT =
  "nekopilot-auto-select-fastest-node-changed";
export const DEFAULT_AUTO_SELECT_FASTEST_NODE = true;
export const SKIP_SYSTEM_PROXY_STORE_KEY = "skip_system_proxy_key";
// User Agent 配置键
export const USER_AGENT_STORE_KEY = "user_agent_key";
// A high, non-standard port avoids clashes with common proxy (7890/1080) and
// development-service ports while remaining easy to recognize in support docs.
export const DEFAULT_PROXY_PORT = 16789;
export const PROXY_PORT_STORE_KEY = "proxy_port_key";
export const PROXY_PORT_CHANGED_EVENT = "onebox-proxy-port-changed";

// Theme preference: 'light' | 'dark' | 'system' (default when unset).
// 'system' follows prefers-color-scheme; explicit values override it.
// 允许局域网连接
export const ALLOWLAN_STORE_KEY = "allow_lan_key";
export type OsInfo = {
  appVersion: string;
  osArch: Arch;
  osType: OsType;
  osVersion: string;
  osLocale: string | null;
};

export type Subscription = {
  id: number;
  identifier: string;
  name: string;
  used_traffic: number;
  total_traffic: number;
  subscription_url: string;
  official_website: string;
  expire_time: number;
  last_update_time: number;
  source_type: "subscription" | "local_link";
};

export type SubscriptionConfig = {
  id: number;
  identifier: string;
  config_content: string;
};

// 获取订阅列表的 SWR 键
export const GET_SUBSCRIPTIONS_LIST_SWR_KEY = "get-subscriptions-list";

export interface TerminatedPayload {
  code: number | null;
  signal: number | null;
}

export type StatusChangedPayload = void | TerminatedPayload;
