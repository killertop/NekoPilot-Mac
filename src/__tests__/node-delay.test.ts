import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../utils/clash-api", () => ({ clashApiFetch: vi.fn() }));
import { clashApiFetch } from "../utils/clash-api";
import { measureNodeDelay, measureNodeDelays } from "../utils/node-delay";

const mockFetch = vi.mocked(clashApiFetch);

describe("bounded node delay measurement", () => {
  beforeEach(() => mockFetch.mockReset());

  it("never exceeds the configured request concurrency", async () => {
    let active = 0;
    let maximumActive = 0;
    mockFetch.mockImplementation(async () => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      await new Promise((resolve) => setTimeout(resolve, 5));
      active -= 1;
      return {
        ok: true,
        status: 200,
        json: async () => ({ delay: 50 }),
      } as Response;
    });

    const results = await measureNodeDelays(
      ["perf-a", "perf-b", "perf-c", "perf-d", "perf-e", "perf-f"],
      { force: true, concurrency: 3 },
    );

    expect(Object.keys(results)).toHaveLength(6);
    expect(maximumActive).toBe(3);
  });

  it("forces a fresh URL Test instead of reusing the recent delay cache", async () => {
    mockFetch.mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({ delay: 42 }),
    } as Response);

    await measureNodeDelay("manual-url-test-node", { force: true });
    await measureNodeDelay("manual-url-test-node");
    expect(mockFetch).toHaveBeenCalledTimes(1);

    await measureNodeDelay("manual-url-test-node", { force: true });
    expect(mockFetch).toHaveBeenCalledTimes(2);
  });

  it("can use a disconnected one-shot measurement backend", async () => {
    const measure = vi.fn(async (node: string) => node === "offline-a" ? 81 : "-" as const);
    const results = await measureNodeDelays(["offline-a", "offline-b"], {
      concurrency: 2,
      measure,
    });

    expect(results).toEqual({ "offline-a": 81, "offline-b": "-" });
    expect(measure).toHaveBeenCalledTimes(2);
    expect(mockFetch).not.toHaveBeenCalled();
  });
});
