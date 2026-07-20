import { clashApiFetch } from "./clash-api";

export const RUNTIME_NODE_TAG_PREFIX = "@np:";
const lastSelectedNodeBySubscription = new Map<string, string>();

export type ExitGatewaySelector = {
  all: string[];
  now: string;
};

export function subscriptionNodePrefix(identifier: string): string {
  return `${RUNTIME_NODE_TAG_PREFIX}${identifier}:`;
}

export function subscriptionIdentifierForNode(nodeTag: string): string | undefined {
  if (!nodeTag.startsWith(RUNTIME_NODE_TAG_PREFIX)) return undefined;
  const separator = nodeTag.indexOf(":", RUNTIME_NODE_TAG_PREFIX.length);
  if (separator < 0) return undefined;
  return nodeTag.slice(RUNTIME_NODE_TAG_PREFIX.length, separator) || undefined;
}

export function displayNodeTag(nodeTag: string): string {
  const identifier = subscriptionIdentifierForNode(nodeTag);
  if (!identifier) return nodeTag;
  return nodeTag.slice(subscriptionNodePrefix(identifier).length) || nodeTag;
}

export async function getExitGatewaySelector(): Promise<ExitGatewaySelector> {
  const response = await clashApiFetch("/proxies/ExitGateway");
  if (!response.ok) throw new Error(`selector_http_${response.status}`);
  const payload = await response.json() as { all?: unknown; now?: unknown };
  return {
    all: Array.isArray(payload.all)
      ? payload.all.filter((value): value is string => typeof value === "string")
      : [],
    now: typeof payload.now === "string" ? payload.now : "",
  };
}

export async function selectExitGatewayNode(nodeTag: string): Promise<void> {
  const response = await clashApiFetch("/proxies/ExitGateway", {
    method: "PUT",
    body: JSON.stringify({ name: nodeTag }),
  });
  if (!response.ok) throw new Error(`selector_switch_http_${response.status}`);
  const identifier = subscriptionIdentifierForNode(nodeTag);
  if (identifier) lastSelectedNodeBySubscription.set(identifier, nodeTag);
}

/** Selects the first node belonging to a configuration without reloading sing-box. */
export async function switchToSubscriptionNode(identifier: string): Promise<boolean> {
  const selector = await getExitGatewaySelector();
  const prefix = subscriptionNodePrefix(identifier);
  const currentIdentifier = subscriptionIdentifierForNode(selector.now);
  if (currentIdentifier) {
    lastSelectedNodeBySubscription.set(currentIdentifier, selector.now);
  }
  const remembered = lastSelectedNodeBySubscription.get(identifier);
  const target = remembered && selector.all.includes(remembered)
    ? remembered
    : selector.all.find((node) => node.startsWith(prefix));
  if (!target) return false;
  if (selector.now !== target) await selectExitGatewayNode(target);
  return true;
}
