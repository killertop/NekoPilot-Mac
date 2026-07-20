import { describe, expect, it } from "vitest";
import { compareNodesByDelay } from "../utils/node-order";

describe("unified Home node ordering", () => {
  it("sorts successful measurements from fastest to slowest", () => {
    const nodes = ["slow", "timeout", "fast"];
    const delays = { slow: 210, timeout: "-" as const, fast: 42 };
    expect(
      [...nodes].sort((left, right) =>
        compareNodesByDelay(left, right, delays, new Set())
      ),
    ).toEqual(["fast", "slow", "timeout"]);
  });

  it("keeps pending measurements above completed timeouts", () => {
    const nodes = ["timeout", "pending", "measured"];
    const delays = { timeout: "-" as const, measured: 88 };
    expect(
      [...nodes].sort((left, right) =>
        compareNodesByDelay(left, right, delays, new Set(["pending"]))
      ),
    ).toEqual(["measured", "pending", "timeout"]);
  });
});
