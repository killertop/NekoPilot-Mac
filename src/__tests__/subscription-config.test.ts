import { describe, expect, it } from "vitest";

import { isUsableSubscriptionConfig } from "../action/subscription-config";
import { isLocalProxyLink } from "../action/proxy-link";

describe("subscription config validation", () => {
  it("accepts a sing-box config with a usable outbound", () => {
    expect(isUsableSubscriptionConfig({
      outbounds: [{ type: "vless", tag: "node-1" }],
    })).toBe(true);
  });

  it("rejects non-config responses before they can replace a saved subscription", () => {
    expect(isUsableSubscriptionConfig(null)).toBe(false);
    expect(isUsableSubscriptionConfig({})).toBe(false);
    expect(isUsableSubscriptionConfig({ outbounds: [] })).toBe(false);
    expect(isUsableSubscriptionConfig({ outbounds: [{ type: "direct", tag: "direct" }] })).toBe(false);
    expect(isUsableSubscriptionConfig({ outbounds: "not-an-array" })).toBe(false);
  });
});

describe("local proxy links", () => {
  it("routes VLESS, Trojan, VMess, Shadowsocks and AnyTLS links to the local importer", () => {
    expect(isLocalProxyLink("vless://uuid@example.com:443#Tokyo")).toBe(true);
    expect(isLocalProxyLink("trojan://password@example.com:443#Tokyo")).toBe(true);
    expect(isLocalProxyLink("vmess://base64-payload")).toBe(true);
    expect(isLocalProxyLink("ss://base64-payload@example.com:443#Tokyo")).toBe(true);
    expect(isLocalProxyLink("anytls://password@example.com:443#Tokyo")).toBe(true);
    expect(isLocalProxyLink("https://example.com/sub")).toBe(false);
  });
});
