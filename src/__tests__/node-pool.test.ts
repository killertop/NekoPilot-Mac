import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("../utils/clash-api", () => ({ clashApiFetch: vi.fn() }));
import { clashApiFetch } from "../utils/clash-api";
import {
  displayNodeTag,
  nodesForSubscription,
  preferredNodeForSubscription,
  scopedNodeSelection,
  subscriptionIdentifierForNode,
  subscriptionNodePrefix,
  switchToSubscriptionNode,
} from "../utils/node-pool";

const mockFetch = vi.mocked(clashApiFetch);

describe("runtime node pool tags", () => {
  beforeEach(() => mockFetch.mockReset());

  it("keeps subscription identity internal while preserving the node label", () => {
    const tag = "@np:airport-123:VLESS · Tokyo";
    expect(subscriptionIdentifierForNode(tag)).toBe("airport-123");
    expect(subscriptionNodePrefix("airport-123")).toBe("@np:airport-123:");
    expect(displayNodeTag(tag)).toBe("VLESS · Tokyo");
  });

  it("leaves legacy node tags unchanged", () => {
    expect(displayNodeTag("VLESS · Tokyo")).toBe("VLESS · Tokyo");
    expect(subscriptionIdentifierForNode("VLESS · Tokyo")).toBeUndefined();
  });

  it("resolves a configuration node synchronously from the cached pool", () => {
    const nodes = ["@np:airport-a:Tokyo", "@np:airport-b:Osaka"];
    expect(preferredNodeForSubscription("airport-b", nodes)).toBe(
      "@np:airport-b:Osaka",
    );
  });

  it("shows only nodes belonging to the configuration displayed on Home", () => {
    const nodes = [
      "@np:airport-a:Tokyo",
      "@np:airport-b:Osaka",
      "@np:airport-a:Singapore",
    ];
    expect(nodesForSubscription("airport-a", nodes)).toEqual([
      "@np:airport-a:Tokyo",
      "@np:airport-a:Singapore",
    ]);
    expect(
      scopedNodeSelection("airport-a", nodes, "@np:airport-b:Osaka"),
    ).toEqual({
      all: ["@np:airport-a:Tokyo", "@np:airport-a:Singapore"],
      now: "@np:airport-a:Tokyo",
    });
  });

  it("keeps legacy single-configuration node pools visible during upgrade", () => {
    expect(
      scopedNodeSelection("airport-a", ["Tokyo", "Singapore"], "Singapore"),
    ).toEqual({ all: ["Tokyo", "Singapore"], now: "Singapore" });
  });

  it("switches configuration through the local selector without a config reload", async () => {
    mockFetch
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({
          all: ["@np:airport-a:Tokyo", "@np:airport-b:Osaka"],
          now: "@np:airport-a:Tokyo",
        }),
      } as Response)
      .mockResolvedValueOnce({ ok: true, status: 204 } as Response);

    await expect(switchToSubscriptionNode("airport-b")).resolves.toBe(true);
    expect(mockFetch).toHaveBeenNthCalledWith(2, "/proxies/ExitGateway", {
      method: "PUT",
      body: JSON.stringify({ name: "@np:airport-b:Osaka" }),
    });
  });
});
