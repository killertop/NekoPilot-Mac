import { describe, expect, it } from "vitest";
import { createLifecycleQueue } from "../utils/lifecycle-queue";

describe("createLifecycleQueue", () => {
  it("runs lifecycle jobs one at a time in request order", async () => {
    const queue = createLifecycleQueue();
    const events: string[] = [];
    let releaseFirst!: () => void;
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });

    const first = queue.run(async () => {
      events.push("first:start");
      await firstGate;
      events.push("first:end");
    });
    const second = queue.run(async () => {
      events.push("second:start");
      events.push("second:end");
    });

    await Promise.resolve();
    expect(events).toEqual(["first:start"]);
    releaseFirst();
    await Promise.all([first, second]);
    expect(events).toEqual([
      "first:start",
      "first:end",
      "second:start",
      "second:end",
    ]);
  });

  it("continues with the next job after a failed operation", async () => {
    const queue = createLifecycleQueue();
    const failed = queue.run(async () => {
      throw new Error("expected failure");
    });
    const next = queue.run(async () => "recovered");

    await expect(failed).rejects.toThrow("expected failure");
    await expect(next).resolves.toBe("recovered");
  });
});
