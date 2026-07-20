import { describe, expect, it } from "vitest";
import { mapSettledWithConcurrency } from "../utils/async-pool";

describe("mapSettledWithConcurrency", () => {
  it("caps active work and preserves result order", async () => {
    let active = 0;
    let peak = 0;
    const results = await mapSettledWithConcurrency([1, 2, 3, 4, 5], 2, async (value) => {
      active += 1;
      peak = Math.max(peak, active);
      await Promise.resolve();
      active -= 1;
      return value * 2;
    });
    expect(peak).toBe(2);
    expect(results).toEqual([2, 4, 6, 8, 10].map((value) => ({
      status: "fulfilled",
      value,
    })));
  });

  it("keeps processing after one task rejects", async () => {
    const results = await mapSettledWithConcurrency([1, 2, 3], 2, async (value) => {
      if (value === 2) throw new Error("expected");
      return value;
    });
    expect(results.map((result) => result.status)).toEqual([
      "fulfilled",
      "rejected",
      "fulfilled",
    ]);
  });
});
