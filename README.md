# NekoPilot for Mac

<p align="center">
  <img src="./native/Resources/NekoPilotLogo.png" alt="NekoPilot" width="128">
</p>

NekoPilot is a native Apple Silicon proxy client for macOS. Its application shell is SwiftUI + AppKit; the unmodified upstream Go sing-box executable is the only proxy engine.

Swift owns the menu bar, window lifecycle, sleep/wake handling, system proxy, persistence, and native interaction. Go sing-box owns protocols, routing, DNS, and URL Test. NekoPilot does not reimplement proxy protocols in Swift.

## Supported release target

- Apple Silicon (`arm64`) only.
- macOS 13 or newer.
- GitHub Releases with an ad-hoc signature; Apple Developer ID and notarization are not required by this distribution path.
- No Windows, Linux, or Intel macOS packages.

The repository no longer contains a Rust, Tauri, React, or cross-platform application implementation. Git history remains available for old-version archaeology.

## Product scope

- Import and update subscriptions.
- Import standalone `vless://`, `trojan://`, `vmess://`, `ss://`, and `anytls://` links.
- Present all imported nodes in one delay-sorted list.
- Manual URL Test while disconnected or connected, with persisted historical delay results.
- Connect to the selected node through System Proxy mode.
- Custom direct/proxy routing rules and bundled China/LAN direct rules.
- A single native menu-bar item with running and stopped states.

## Technology

- Swift 6, SwiftUI, and AppKit for the native application.
- Original Go sing-box for protocols, routing, DNS, and URL Test; Swift communicates directly with its official 1.14 gRPC API.
- SQLite for local data.
- Shell and GitHub Actions for reproducible Apple Silicon packaging.

## Development

Requirements: Apple Silicon Mac, macOS 13+, Xcode 26.2, Go 1.26.5, and GitHub CLI.

```bash
native/scripts/build-sing-box-macos-arm64.sh
NEKOPILOT_SING_BOX="$PWD/native/.build/sidecar/sing-box" \
  swift run --package-path native NekoPilot
```

Run native checks:

```bash
native/scripts/check-release-policy.sh
swift build --package-path native
swift test --package-path native
swift run --package-path native NekoPilotCoreChecks
```

Build and verify the actual application, DMG, archive, signature, architecture, resources, and minimum macOS version:

```bash
native/scripts/package-macos.sh
```

Artifacts are written to `native/dist/`. The package script copies the pinned menu-bar template, offline rule baseline, and source-built sing-box into the app before ad-hoc signing it.

## Project layout

```text
native/Sources/NekoPilot/       SwiftUI/AppKit application shell
native/Sources/NekoPilotCore/   native lifecycle, persistence, compiler, and engine supervision
native/Resources/               source artwork for the macOS app and menu bar
native/scripts/                 pinned sing-box build and macOS package verification
.github/workflows/              native Apple Silicon tests and release
docs/                           development and release guides
```

See [Architecture](docs/ARCHITECTURE.md), [中文说明](README_CN.md), [Development Guide](docs/DEVELOPMENT.md), and [Release Guide](docs/RELEASE.md).

Source publication is routed through the VPS bare repository described in the release guide. The maintained repository is [killertop/NekoPilot-Mac](https://github.com/killertop/NekoPilot-Mac). See [LICENSE](LICENSE) and [NOTICE](NOTICE).
