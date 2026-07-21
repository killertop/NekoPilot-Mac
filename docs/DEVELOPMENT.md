# Development Guide

## 1. Supported environment

NekoPilot production development and acceptance run on an Apple Silicon Mac with macOS 13 or newer.

Required tools:

- Xcode 26.2 and Swift 6.
- Go 1.26.5 exactly.
- GitHub CLI (`gh`) for downloading the pinned upstream sing-box archive.
- Standard macOS packaging tools: `codesign`, `hdiutil`, `lipo`, and `vtool`.

SwiftUI + AppKit are the application shell. Original Go sing-box is a separate executable and the sole implementation of protocols, routing, DNS, and URL Test.

## 2. Build the proxy core

From the repository root:

```bash
native/scripts/build-sing-box-macos-arm64.sh
```

The script verifies the pinned upstream commit archive before compiling it. It sets `MACOSX_DEPLOYMENT_TARGET=13.0`, produces arm64 only, and rejects a Mach-O minimum version newer than macOS 13.

For a release-equivalent reproducibility check:

```bash
NEKOPILOT_VERIFY_REPRODUCIBLE=1 \
  native/scripts/build-sing-box-macos-arm64.sh
```

## 3. Run the native app

```bash
NEKOPILOT_SING_BOX="$PWD/native/.build/sidecar/sing-box" \
  swift run --package-path native NekoPilot
```

The SwiftPM executable is useful for iteration, but it is not package acceptance. `Info.plist`, app resources, agent activation behavior, signatures, the DMG, and the menu-bar template exist only in the real bundle.

## 4. Checks and package build

```bash
git diff --check
native/scripts/check-release-policy.sh
swift build --package-path native
swift test --package-path native
swift run --package-path native NekoPilotCoreChecks
native/scripts/package-macos.sh
```

The package script performs these hard checks:

- application and sing-box are arm64-only;
- both Mach-O files require macOS 13.0 or older;
- bundle identifier and version match `native/VERSION`;
- `LSUIElement` is absent so SwiftUI can create the first window before AppDelegate switches the process to accessory mode;
- menu-bar artwork and offline rule resources are present;
- sing-box reports the pinned version, Go version, release tags, and CGO state;
- the app has a valid strict ad-hoc signature;
- both the mounted DMG and extracted app archive pass the same bundle checks;
- `SHA256SUMS` contains exactly the DMG and archive.
- the real packaged executable creates exactly one visible initial window, rejects a second instance, and completes a normal quit handshake.

Passing these checks still does not prove real proxy egress.

## 5. Manual QA boundary

Run the packaged `.app`, not just `swift run`, and confirm:

- the first window appears and only one menu-bar item exists;
- closing, reopening from the menu bar, and quitting release all owned resources;
- a second launch activates the existing instance instead of creating another;
- subscription and standalone-node import persist across restart;
- URL Test works while disconnected and connected, retains old results until the next test, and sorts nodes by delay;
- selected-node connection, stop, reconnect, and node switch use the displayed node;
- system proxy is applied only after sing-box is ready and is restored after stop, failure, sleep, and quit;
- custom rules and bundled LAN/China direct rules are compiled into the active sing-box configuration;
- wake/network-change recovery uses bounded retry and cannot leave an orphan sing-box process.

Record the app version, package path, macOS version, node protocol, test URL, real egress result, and relevant log excerpt.

## 6. Legacy boundary

The repository intentionally contains no legacy application implementation. Use Git history when an old behavior needs investigation; do not restore Rust, Tauri, React/WebView, Windows, Linux, or Intel application targets to the active tree.
