import { describe, expect, it } from "vitest";
import {
  isUpdateCheckDue,
  isVersionNewer,
  safeGitHubReleaseUrl,
} from "../utils/github-release-update";

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

describe("isUpdateCheckDue", () => {
  it("recovers from a persisted timestamp that is in the future", () => {
    expect(isUpdateCheckDue(2_000, 1_000)).toBe(true);
  });

  it("does not repeat a recent successful attempt", () => {
    expect(isUpdateCheckDue(999, 1_000)).toBe(false);
  });
});

describe("safeGitHubReleaseUrl", () => {
  it("accepts canonical NekoPilot Mac release pages", () => {
    expect(
      safeGitHubReleaseUrl(
        "https://github.com/killertop/NekoPilot-Mac/releases/tag/v1.0.8",
      ),
    ).toBe(
      "https://github.com/killertop/NekoPilot-Mac/releases/tag/v1.0.8",
    );
  });

  it("rejects unsafe schemes, hosts, credentials, and unrelated pages", () => {
    expect(safeGitHubReleaseUrl("javascript:alert(1)")).toBeUndefined();
    expect(
      safeGitHubReleaseUrl(
        "https://github.example.com/killertop/NekoPilot-Mac/releases/tag/v2",
      ),
    ).toBeUndefined();
    expect(
      safeGitHubReleaseUrl(
        "https://evil.example@github.com/killertop/NekoPilot-Mac/releases/tag/v2",
      ),
    ).toBeUndefined();
    expect(
      safeGitHubReleaseUrl("https://github.com/killertop/NekoPilot-Mac/issues"),
    ).toBeUndefined();
  });
});
