import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../utils/clash-api", () => ({ clashApiFetch: vi.fn() }));
import { clashApiFetch } from "../utils/clash-api";
import { measureNodeDelays } from "../utils/node-delay";

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
});
