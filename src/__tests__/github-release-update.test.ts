import { describe, expect, it } from "vitest";
import { isVersionNewer } from "../utils/github-release-update";

describe("isVersionNewer", () => {
  it("accepts v-prefixed GitHub release tags", () => {
    expect(isVersionNewer("v1.0.2", "1.0.1")).toBe(true);
  });

  it("does not prompt for the same or an older release", () => {
    expect(isVersionNewer("v1.0.1", "1.0.1")).toBe(false);
    expect(isVersionNewer("v1.0.0", "1.0.1")).toBe(false);
  });

  it("compares each semantic-version segment numerically", () => {
    expect(isVersionNewer("1.10.0", "1.9.9")).toBe(true);
    expect(isVersionNewer("1.0.1", "1.0.10")).toBe(false);
  });

  it("fails closed for malformed version strings", () => {
    expect(isVersionNewer("nightly", "1.0.1")).toBe(false);
  });
});
