import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

function read(relativePath: string): string {
  return readFileSync(new URL(relativePath, import.meta.url), "utf8");
}

const releaseWorkflow = read("../../.github/workflows/release.yml");
const testWorkflow = read("../../.github/workflows/test.yml");
const releaseGuide = read("../../docs/RELEASE.md");
const sidecarBuild = read("../../native/scripts/build-sing-box-macos-arm64.sh");
const packageScript = read("../../native/scripts/package-macos.sh");
const shellPolicy = read("../../native/scripts/check-release-policy.sh");

describe("native macOS release policy", () => {
  it("publishes only native Apple Silicon macOS packages", () => {
    expect(releaseWorkflow).toContain("runs-on: macos-26");
    expect(releaseWorkflow).toContain("native/scripts/package-macos.sh");
    expect(releaseWorkflow).toContain("NekoPilot_${VERSION}_aarch64.dmg");
    expect(releaseWorkflow).toContain(
      "NekoPilot_${VERSION}_aarch64.app.tar.gz",
    );
    expect(releaseWorkflow).toContain("SHA256SUMS");

    expect(releaseWorkflow).not.toMatch(/runs-on:\s*windows-/i);
    expect(releaseWorkflow).not.toMatch(/build-(?:windows|linux|macos-x86)/i);
    expect(releaseWorkflow).not.toMatch(/\.(?:msi|exe|deb|rpm|AppImage)\b/i);
    expect(releaseWorkflow).not.toMatch(/(?:x86_64|amd64|intel)/i);
    expect(releaseWorkflow).not.toContain("tauri-action");
    expect(releaseWorkflow).not.toContain("deno task tauri");
    expect(releaseWorkflow).not.toContain("cargo ");
  });

  it("takes the release version only from native/VERSION", () => {
    expect(releaseWorkflow).toContain('paths:\n      - "native/VERSION"');
    expect(releaseWorkflow).toContain("< native/VERSION");
    expect(releaseWorkflow).not.toContain("src-tauri/tauri.conf.json");
    expect(releaseWorkflow).not.toContain("package.json");
  });

  it("builds the original Go core from pinned inputs and rejects a newer minos", () => {
    expect(sidecarBuild).toContain('SING_BOX_VERSION="1.13.14"');
    expect(sidecarBuild).toContain(
      'SING_BOX_COMMIT="25a600db24f7680ad9806ce5427bd0ab8afe1114"',
    );
    expect(sidecarBuild).toContain('GO_VERSION="1.26.5"');
    expect(sidecarBuild).toContain('MACOS_DEPLOYMENT_TARGET="13.0"');
    expect(sidecarBuild).toContain('MACOS_SDK_VERSION="26.2"');
    expect(sidecarBuild).toContain("SING_BOX_ARCHIVE_SHA256=");
    expect(sidecarBuild).toContain("NEKOPILOT_VERIFY_REPRODUCIBLE");
    expect(sidecarBuild).toContain("vtool -show-build");
    expect(sidecarBuild).toContain("./cmd/sing-box");
    expect(sidecarBuild).not.toContain("src-tauri/binaries");
  });

  it("packages native resources and ad-hoc signs the complete bundle", () => {
    expect(packageScript).toContain("menu-bar-template.png");
    expect(packageScript).toContain("base-config.json");
    expect(packageScript).toContain("geoip-cn.srs");
    expect(packageScript).toContain("geosite-cn.srs");
    expect(packageScript).toContain("codesign --force --sign -");
    expect(packageScript).toContain("swift test --package-path");
    expect(packageScript).toContain("verify-macos-artifacts.sh");
    expect(packageScript).toContain("smoke-test-macos-app.sh");
  });

  it("keeps the Test workflow a native hard gate with no publication", () => {
    expect(testWorkflow).toContain("Native Apple Silicon hard gate");
    expect(testWorkflow).toContain("runs-on: macos-26");
    expect(testWorkflow).toContain("native/scripts/package-macos.sh");
    expect(testWorkflow).not.toContain("contents: write");
    expect(testWorkflow).not.toContain("gh release");
    expect(testWorkflow).not.toContain("actions/upload-artifact");
    expect(testWorkflow).not.toContain("denoland/setup-deno");
    expect(testWorkflow).toContain("native/scripts/check-release-policy.sh");
    expect(shellPolicy).toContain("Native Apple Silicon publication policy passed");
  });

  it("documents the permanent native-only publication boundary", () => {
    expect(releaseGuide).toContain(
      "Only Apple Silicon macOS assets are built or published",
    );
    expect(releaseGuide).toContain(
      "Windows, Linux, Intel macOS, and Tauri packages are never Release assets",
    );
    expect(releaseGuide).toContain("native/VERSION");
  });
});
