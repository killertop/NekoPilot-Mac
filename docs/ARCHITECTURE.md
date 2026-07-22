# NekoPilot macOS Architecture

## Product boundary

NekoPilot is an Apple Silicon-only macOS application. The minimum supported system is macOS 13 and every application binary published by the project is `arm64`.

The application is split into a native control plane and an upstream proxy data plane:

```text
SwiftUI views
    ↓ user intent and observable state
AppKit + Swift control plane
    ↓ generated configuration, process lifecycle, official local gRPC
unmodified upstream Go sing-box
    ↓
network protocols, routing, DNS, URL Test
```

## SwiftUI and AppKit responsibilities

SwiftUI renders Home, Nodes, Rules, and Settings. AppKit integrates with macOS and owns:

- the menu-bar item and window activation;
- application launch, single-instance behavior, deep links, and termination;
- sleep and wake notifications;
- launch-at-login and native system interaction.

Swift actors form the application control plane and own:

- SQLite persistence and settings;
- subscription and standalone-node parsing at the import boundary;
- sing-box configuration generation and validation;
- system-proxy ownership, safe restore, and crash markers;
- sing-box process supervision and bounded network-readiness retry;
- native gRPC control, node selection, traffic state, and delay-history persistence.

Swift does not implement a proxy transport, packet tunnel, routing engine, DNS engine, or URL Test algorithm.

## Go sing-box responsibilities

The only proxy engine is the original upstream `SagerNet/sing-box` executable. The build script pins and verifies its upstream commit, source archive, Go toolchain, build tags, macOS SDK, deployment target, and output architecture before packaging it beside the Swift executable.

sing-box exclusively owns:

- VLESS, Trojan, VMess, Shadowsocks, AnyTLS, Hysteria2, TUIC, and other supported transports;
- outbound routing and route-rule execution;
- DNS resolution and DNS routing;
- URL Test execution and runtime state.

NekoPilot communicates with sing-box through generated JSON configuration and the official 1.14 `StartedService` gRPC interface. Each sing-box process listens only on `127.0.0.1` at a newly allocated ephemeral port; Swift supplies a fresh 256-bit authorization secret in the owner-only (`0600`) runtime configuration for that process. There is no Dashboard, remote API setting, HTTP controller, Unix-socket bridge, custom Go source, or Clash service. Swift owns process lifecycle; sing-box handles native selection and URL Test APIs, while its standard executable handles configuration reload on `SIGHUP`.

China routing uses only standard local binary `rule_set` assets: bundled `geoip-cn.srs` and `geosite-cn.srs` provide an offline baseline. A seven-day updater resolves immutable upstream Git commits, verifies each downloaded Git blob SHA-1, validates the candidates with the embedded sing-box checker, and installs both assets as one generation before atomically switching the active generation. Failed downloads retry in one hour. The runtime configuration always loads those local files and never needs to fetch route sets at startup.

## Explicitly unsupported architecture

The active repository must not contain or publish:

- Rust or Cargo source;
- Tauri, React, WebView, or a second application shell;
- Windows, Linux, Intel macOS, universal, mobile, or App Store targets;
- proxy-protocol implementations written in Swift.

`native/scripts/check-release-policy.sh` enforces these boundaries in local checks and CI. Old implementations remain recoverable from Git history rather than from duplicate active source trees.

## Acceptance evidence

Architecture completion requires all of the following, not only a successful compile:

1. Repository policy finds no tracked Rust/Cargo or legacy application tree.
2. Swift build and unit tests pass.
3. The pinned upstream sing-box source builds as arm64 with the declared Go toolchain.
4. Existing local data compiles into a valid sing-box configuration.
5. URL Test and sing-box start, live reload, and stop integration checks pass.
6. The DMG and app archive pass architecture, minimum-system, resource, signature, single-instance, initial-window, and normal-quit checks.
