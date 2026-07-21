# NekoPilot Native for macOS

This directory is the production implementation.

- SwiftUI renders Home, Nodes, Rules, and Settings.
- AppKit owns the single menu-bar item, window lifecycle, deep links, sleep/wake, and termination handshake.
- Swift actors own SQLite persistence, process supervision, system-proxy ownership, and the Clash control API.
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

`scripts/build-sing-box-macos-arm64.sh` downloads the archive for the pinned upstream commit, verifies the archive SHA-256, requires the exact Go and macOS SDK versions, builds upstream `./cmd/sing-box` with the upstream release tags in isolated Go caches, and rejects any binary whose `LC_BUILD_VERSION` requires newer than macOS 13.0.

CI builds the core twice from the same inputs and requires identical hashes. No forked Go proxy implementation or prebuilt sidecar is accepted as a Release input.

```bash
native/scripts/build-sing-box-macos-arm64.sh
```

Set `NEKOPILOT_VERIFY_REPRODUCIBLE=1` to run the same double-build check locally.

## Apple Silicon package

```bash
native/scripts/package-macos.sh
```

The script creates and verifies an ad-hoc-signed `.app`, `.dmg`, `.app.tar.gz`, and `SHA256SUMS` under `native/dist`. Both executable files must be arm64-only and compatible with macOS 13. The packaged DMG and archive are mounted/extracted and checked independently.

The repository contains one production architecture only: a SwiftUI/AppKit shell plus the pinned upstream Go sing-box executable. Rust, WebView, Windows, Linux, and Intel application targets are rejected by the repository policy check.
