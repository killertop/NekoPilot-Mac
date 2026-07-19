import { describe, expect, it } from "vitest";
import { consumeJsonFrames } from "../utils/clash-api";

describe("consumeJsonFrames", () => {
  it("preserves a JSON line split across transport chunks", () => {
    const first = consumeJsonFrames<{ payload: string }>('{"payload":"hel');
    expect(first.values).toEqual([]);
    expect(first.remainder).toBe('{"payload":"hel');

    const second = consumeJsonFrames<{ payload: string }>(
      `${first.remainder}lo"}\n`,
    );
    expect(second.values).toEqual([{ payload: "hello" }]);
    expect(second.remainder).toBe("");
  });

  it("accepts multiple newline-delimited frames and SSE data prefixes", () => {
    const result = consumeJsonFrames<{ value: number }>(
      'data: {"value":1}\n{"value":2}\n',
    );

    expect(result.values).toEqual([{ value: 1 }, { value: 2 }]);
    expect(result.remainder).toBe("");
  });

  it("accepts a complete frame without a trailing newline", () => {
    const result = consumeJsonFrames<{ up: number; down: number }>(
      '{"up":12,"down":34}',
    );

    expect(result.values).toEqual([{ up: 12, down: 34 }]);
    expect(result.remainder).toBe("");
  });
});
