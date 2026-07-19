/** True when a pasted URI is a locally-imported proxy node, not a subscription. */
const LOCAL_PROXY_LINK_SCHEMES = new Set(["vless", "trojan", "vmess", "ss", "anytls"]);

export function isLocalProxyLink(value: string): boolean {
  const scheme = value.trim().match(/^([a-z][a-z0-9+.-]*):\/\//i)?.[1]
    ?.toLowerCase();
  return Boolean(scheme && LOCAL_PROXY_LINK_SCHEMES.has(scheme));
}
