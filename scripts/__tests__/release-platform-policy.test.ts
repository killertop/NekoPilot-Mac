import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const releaseWorkflow = readFileSync(
  new URL("../../.github/workflows/release.yml", import.meta.url),
  "utf8",
);
const releaseGuide = readFileSync(
  new URL("../../docs/RELEASE.md", import.meta.url),
  "utf8",
);

describe("release platform policy", () => {
  it("never builds or publishes a Windows installer", () => {
    expect(releaseWorkflow).not.toMatch(/^\s*build-windows:\s*$/m);
    expect(releaseWorkflow).not.toMatch(/^\s*runs-on:\s*windows-/m);
    expect(releaseWorkflow).not.toContain("build-windows");
    expect(releaseWorkflow).not.toMatch(/\.(?:msi|exe)['\"\s]/i);
  });

  it("allow-lists reusable macOS and Linux package types", () => {
    expect(releaseWorkflow).not.toContain("--pattern '*'");
    for (const pattern of [
      "--pattern '*.dmg'",
      "--pattern '*.app.tar.gz'",
      "--pattern '*.deb'",
      "--pattern '*.rpm'",
      "--pattern '*.AppImage'",
    ]) {
      expect(releaseWorkflow).toContain(pattern);
    }
  });

  it("documents the permanent Windows publication boundary", () => {
    expect(releaseGuide).toContain(
      "Windows packages are deliberately not built, copied between release channels, or published",
    );
    expect(releaseGuide).toContain(
      "It must never publish Windows EXE, MSI, or NSIS installers",
    );
  });
});
