# NekoPilot for Mac engineering boundary

NekoPilot has one supported product architecture:

- SwiftUI renders the application.
- AppKit owns macOS lifecycle, menu bar, windows, sleep/wake, deep links, and native interaction.
- Swift owns local persistence, configuration generation, system-proxy ownership, and supervision of the external core process.
- The pinned, unmodified upstream Go sing-box executable owns proxy protocols, routing, DNS, and URL Test.

Only Apple Silicon macOS is supported. Do not add Rust/Cargo, Tauri, React/WebView, Windows, Linux, Intel, or a Swift proxy-protocol implementation. Use Git history when old behavior must be inspected.

Before committing, run:

```bash
native/scripts/check-release-policy.sh
swift build --package-path native
swift test --package-path native
swift run --package-path native NekoPilotCoreChecks
```

For release-affecting changes, also run `native/scripts/package-macos.sh` and verify the real packaged app lifecycle. Do not treat compilation or signing alone as proof of proxy behavior.
