# NekoPilot macOS Architecture

## Product boundary

NekoPilot is an Apple Silicon-only macOS application. The minimum supported system is macOS 13 and every application binary published by the project is `arm64`.

The application is split into a native control plane and an upstream proxy data plane:

```text
SwiftUI views
    ↓ user intent and observable state
AppKit + Swift control plane
    ↓ generated configuration, process lifecycle, SIGHUP, Clash API
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
- Clash API control, node selection, traffic state, and delay-history persistence.

Swift does not implement a proxy transport, packet tunnel, routing engine, DNS engine, or URL Test algorithm.

## Go sing-box responsibilities

The only proxy engine is the original upstream `SagerNet/sing-box` executable. The build script pins and verifies its upstream commit, source archive, Go toolchain, build tags, macOS SDK, deployment target, and output architecture before packaging it beside the Swift executable.

sing-box exclusively owns:

- VLESS, Trojan, VMess, Shadowsocks, AnyTLS, Hysteria2, TUIC, and other supported transports;
- outbound routing and route-rule execution;
- DNS resolution and DNS routing;
- URL Test execution and Clash-compatible runtime control.

NekoPilot communicates with sing-box through generated JSON configuration, process signals, and its authenticated local Clash API. No forked proxy engine or downloaded prebuilt executable is accepted as a Release input.

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
