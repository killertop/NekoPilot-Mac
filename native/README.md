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

`scripts/build-sing-box-macos-arm64.sh` downloads the archive for the pinned upstream commit, verifies the archive SHA-256, requires the exact Go and macOS SDK versions, and builds the unmodified upstream `cmd/sing-box` target. Swift communicates directly with sing-box 1.14's official `StartedService` gRPC API through a per-process `127.0.0.1` port and a 256-bit in-memory session secret. It does not start a Dashboard, remote API, HTTP controller, Unix-socket bridge, or Clash service.

CI builds the core twice from the same inputs and requires identical hashes. No forked Go proxy implementation or prebuilt sidecar is accepted as a Release input.

```bash
native/scripts/build-sing-box-macos-arm64.sh
```

Set `NEKOPILOT_VERIFY_REPRODUCIBLE=1` to run the same double-build check locally.

## China rule sets

`Resources/rules/geoip-cn.srs` and `Resources/rules/geosite-cn.srs` are standard local sing-box binary rule sets. They are bundled for offline startup, loaded directly by the runtime configuration, and refreshed every seven days only after the downloaded candidate passes native sing-box validation. Updates are atomically promoted, so a failed refresh leaves the active assets unchanged.

## Apple Silicon package

```bash
native/scripts/package-macos.sh
```

The script creates and verifies an ad-hoc-signed `.app`, `.dmg`, `.app.tar.gz`, and `SHA256SUMS` under `native/dist`. Both executable files must be arm64-only and compatible with macOS 13. The packaged DMG and archive are mounted/extracted and checked independently.

The repository contains one production architecture only: a SwiftUI/AppKit shell plus the pinned upstream Go sing-box executable. Rust, WebView, Windows, Linux, and Intel application targets are rejected by the repository policy check.
