import { describe, expect, it } from "vitest";

import { RULE_ACTIONS } from "../config/merger/custom-rules";
import { getBuiltInTemplate } from "../config/templates";

describe("built-in template branding", () => {
  it("does not send rule-set traffic to OneBox infrastructure", () => {
    for (const mode of ["mixed", "mixed-global"] as const) {
      expect(getBuiltInTemplate(mode)).not.toMatch(/oneoh\.cloud|OneOhCloud\/one-geosite/i);
    }
  });

  it("exposes direct and proxy custom rules only", () => {
    expect(RULE_ACTIONS).toEqual(["direct", "proxy"]);
  });

  it("does not ship an automatic urltest outbound", () => {
    for (const mode of ["mixed", "mixed-global"] as const) {
      const template = JSON.parse(getBuiltInTemplate(mode));
      const gateway = template.outbounds.find((item: any) => item.tag === "ExitGateway");
      expect(gateway.outbounds).toEqual([]);
      expect(template.outbounds.some((item: any) => item.type === "urltest")).toBe(false);
    }
  });

  it("keeps the selected node as the route fallback", () => {
    for (const mode of ["mixed", "mixed-global"] as const) {
      const template = JSON.parse(getBuiltInTemplate(mode));
      expect(template.route.final).toBe("ExitGateway");

      const hasUnconditionalDirectRule = template.route.rules.some((rule: Record<string, unknown>) =>
        rule.outbound === "direct" && Object.keys(rule).every((key) => key === "outbound"),
      );
      expect(hasUnconditionalDirectRule).toBe(false);
    }
  });

  it("does not download unused remote rule sets", () => {
    const unusedTags = [
      "geosite-geolocation-cn",
      "geosite-geolocation-!cn",
      "geosite-telegram",
    ];
    for (const mode of ["mixed", "mixed-global"] as const) {
      const template = JSON.parse(getBuiltInTemplate(mode));
      const tags = template.route.rule_set.map((item: { tag: string }) => item.tag);
      for (const unusedTag of unusedTags) expect(tags).not.toContain(unusedTag);
    }
  });
});
