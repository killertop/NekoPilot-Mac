import { describe, expect, it } from "vitest";
import {
  delaysFromHistory,
  parseNodeDelayHistory,
  retainNodeDelayHistory,
  updateNodeDelayHistory,
} from "../utils/node-delay-history";

describe("node URL Test history", () => {
  it("restores valid persisted delay and timeout results", () => {
    const history = parseNodeDelayHistory({
      fast: { delay: 48, measuredAt: 100 },
      timeout: { delay: "-", measuredAt: 101 },
      invalid: { delay: -2, measuredAt: 102 },
    });
    expect(delaysFromHistory(history, ["fast", "timeout", "missing"]))
      .toEqual({ fast: 48, timeout: "-" });
  });

  it("updates only the manually tested node and prunes removed nodes", () => {
    const previous = {
      keep: { delay: 120 as const, measuredAt: 1 },
      removed: { delay: 240 as const, measuredAt: 1 },
    };
    const updated = updateNodeDelayHistory(previous, "keep", 75, 2);
    expect(retainNodeDelayHistory(updated, ["keep"]))
      .toEqual({ keep: { delay: 75, measuredAt: 2 } });
  });
});
