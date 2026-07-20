import { describe, expect, it, vi } from "vitest";
import { runConfigSync } from "../utils/config-sync";

describe("runConfigSync", () => {
  it("reports success only after compilation and continuation finish", async () => {
    const events: string[] = [];
    await expect(runConfigSync(
      async () => {
        events.push("compile");
      },
      {
        onSuccess: async () => {
          events.push("start");
        },
      },
    )).resolves.toBe(true);
    expect(events).toEqual(["compile", "start"]);
  });

  it("reports compilation failure and never runs the continuation", async () => {
    const error = new Error("invalid config");
    const onSuccess = vi.fn();
    const onError = vi.fn();
    await expect(runConfigSync(
      async () => {
        throw error;
      },
      { onSuccess, onError },
    )).resolves.toBe(false);
    expect(onSuccess).not.toHaveBeenCalled();
    expect(onError).toHaveBeenCalledOnce();
    expect(onError).toHaveBeenCalledWith(error);
  });

  it("treats a failed continuation as a failed pipeline", async () => {
    const onError = vi.fn();
    await expect(runConfigSync(
      async () => undefined,
      {
        onSuccess: async () => {
          throw new Error("start failed");
        },
        onError,
      },
    )).resolves.toBe(false);
    expect(onError).toHaveBeenCalledOnce();
  });
});
