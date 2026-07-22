# NekoPilot Native for macOS

This directory is the production implementation.

- SwiftUI renders Home, Nodes, Rules, and Settings.
- AppKit owns the single menu-bar item, window lifecycle, deep links, sleep/wake, and termination handshake.
- Swift actors own SQLite persistence, process supervision, system-proxy ownership, and native gRPC control.
- The unmodified Go sing-box executable is the only protocol, routing, DNS, and URL-test engine.

The bundle identifier remains `dev.nekopilot.desktop`; existing data is read from:

```text
~/Library/Application Support/dev.nekopilot.desktop/
```

## Local checks

```bash
swift build --package-path native
swift test --package-path native
swift run --package-path native NekoPilotCoreChecks
```

## Pinned sing-box core

`scripts/build-sing-box-macos-arm64.sh` downloads the archive for the pinned upstream commit, verifies the archive SHA-256, requires the exact Go and macOS SDK versions, and builds the unmodified upstream `cmd/sing-box` target. Swift communicates directly with sing-box 1.14's official `StartedService` gRPC API through a per-process `127.0.0.1` port and a fresh 256-bit session secret. The secret is present only in the owner-only (`0600`) runtime configuration for that session. It does not start a Dashboard, remote API, HTTP controller, Unix-socket bridge, or Clash service.

CI builds the core twice from the same inputs and compares canonical Mach-O
hashes. The canonical form retains the delivered binary but excludes the
runtime `LC_UUID`, its matching ad-hoc signature, and linker-generated
dynamic/Objective-C call trampolines that the CGO linker can lay out
differently. No forked Go proxy implementation or prebuilt sidecar is accepted
as a Release input.

```bash
native/scripts/build-sing-box-macos-arm64.sh
```

Set `NEKOPILOT_VERIFY_REPRODUCIBLE=1` to run the same double-build check locally.

## China rule sets

`Resources/rules/geoip-cn.srs` and `Resources/rules/geosite-cn.srs` are standard local sing-box binary rule sets. They are bundled for offline startup, loaded directly by the runtime configuration, and refreshed every seven days only after the downloaded candidate passes native sing-box validation. Each refresh resolves an immutable upstream Git commit, checks the downloaded Git blob SHA-1, then installs both files as one generation and atomically switches the active generation. A failed refresh retries in one hour and leaves the active assets unchanged.

## Apple Silicon package

```bash
native/scripts/package-macos.sh
```

The script creates and verifies an ad-hoc-signed `.app`, `.dmg`, `.app.tar.gz`, and `SHA256SUMS` under `native/dist`. Both executable files must be arm64-only, compatible with macOS 13, and stripped for release. The zlib-level-9 DMG and archive are mounted/extracted and checked independently. Visual acceptance is performed manually.

The repository contains one production architecture only: a SwiftUI/AppKit shell plus the pinned upstream Go sing-box executable. Rust, WebView, Windows, Linux, and Intel application targets are rejected by the repository policy check.
