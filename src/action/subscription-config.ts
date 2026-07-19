const NON_NODE_OUTBOUND_TYPES = new Set([
  "selector",
  "urltest",
  "direct",
  "block",
  "dns",
]);

/** True only for a subscription that can contribute at least one node. */
export function isUsableSubscriptionConfig(
  value: unknown,
): value is { outbounds: unknown[] } {
  if (!value || typeof value !== "object") return false;
  const outbounds = (value as { outbounds?: unknown }).outbounds;
  if (!Array.isArray(outbounds)) return false;
  return outbounds.some((outbound) => {
    if (!outbound || typeof outbound !== "object") return false;
    const item = outbound as { type?: unknown; tag?: unknown };
    return typeof item.type === "string" &&
      !NON_NODE_OUTBOUND_TYPES.has(item.type) &&
      typeof item.tag === "string" && item.tag.trim().length > 0;
  });
}
