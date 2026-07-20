import { describe, expect, it } from "vitest";
import {
  AUTO_SELECT_INTERVAL_MS,
  connectionAgeMs,
  hasLongLivedConnection,
  pickFastestNode,
} from "../hooks/useAutoNodeSelection";

describe("automatic node selection", () => {
  it("runs on the fixed ten-minute schedule", () => {
    expect(AUTO_SELECT_INTERVAL_MS).toBe(600_000);
  });

  it("picks the lowest successful delay and ignores timeouts", () => {
    expect(pickFastestNode({ slow: 220, timeout: "-", fast: 48 })).toEqual({
      node: "fast",
      delay: 48,
    });
    expect(pickFastestNode({ timeout: "-" })).toBeUndefined();
  });

  it("recognizes ISO, second and millisecond connection start times", () => {
    const now = Date.parse("2026-07-20T08:10:00.000Z");
    expect(connectionAgeMs("2026-07-20T08:08:00.000Z", now)).toBe(120_000);
    expect(connectionAgeMs((now - 90_000) / 1_000, now)).toBe(90_000);
    expect(connectionAgeMs(now - 30_000, now)).toBe(30_000);
  });

  it("waits only when an active connection exceeds the long-lived threshold", () => {
    const now = Date.parse("2026-07-20T08:10:00.000Z");
    expect(hasLongLivedConnection({
      connections: [
        { start: "2026-07-20T08:09:45.000Z" },
        { start: "2026-07-20T08:08:00.000Z" },
      ],
    }, now)).toBe(true);
    expect(hasLongLivedConnection({
      connections: [{ start: "2026-07-20T08:09:45.000Z" }],
    }, now)).toBe(false);
  });
});
