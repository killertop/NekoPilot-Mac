# NekoPilot for Mac

<p align="center">
  <img src="./src/assets/nekopilot-logo.png" alt="NekoPilot" width="128">
</p>

NekoPilot for Mac is a macOS-first desktop proxy client built with Tauri, React, TypeScript, Rust, and sing-box. It focuses on a clear everyday workflow: import a subscription or a standalone node link, select a node, connect to that node, and inspect the connection result.

> This repository is under active development. The local Release build is suitable for development and QA; the distributable package must be produced by the signed release workflow described in [docs/RELEASE.md](docs/RELEASE.md).

## Current scope

- Subscription import, update, deletion, and metadata display.
- Standalone `vless://`, `trojan://`, `vmess://`, `ss://`, and `anytls://` node links.
- Explicit group and node selection. NekoPilot does not automatically switch nodes for the user.
- System Proxy mode backed by a bundled sing-box process.
- Rule and Global routing modes.
- Persistent connection feedback such as connecting, connected, testing, and failed with a reason.
- macOS deep-link scheme: `nekopilot://`.

The current product target is macOS. Windows and Linux configuration files remain in the codebase as part of the Tauri baseline, but they are not the primary acceptance target for this repository.

## Technology

- Tauri 2
- React 19 and TypeScript
- Rust 2021
- Deno 2 task runner
- Vite and Vitest
- sing-box

## Prerequisites

- macOS 10.15 or later for the macOS target.
- Deno 2.x.
- Rust stable toolchain and Cargo.
- Xcode Command Line Tools.

Install frontend dependencies and prepare the local hooks:

```bash
deno install
deno task prepare
```

## Development

Start the Tauri development application:

```bash
deno task tauri dev
```

The development command runs the Vite frontend and the Rust backend with development diagnostics enabled. It is intended for implementation work, not for validating the final distributable package.

## Verification

Run the frontend unit tests:

```bash
deno task test
```

Run the Rust library tests:

```bash
cargo test --manifest-path src-tauri/Cargo.toml --lib
```

Run the production frontend build:

```bash
deno task build
```

Build a local Release application and macOS bundle:

```bash
deno task tauri build
```

The local bundle is written below `src-tauri/target/release/bundle/`. A local build may be ad-hoc signed; see [docs/RELEASE.md](docs/RELEASE.md) for the signed and notarized release path.

## Project layout

```text
src/                 React UI, state, configuration, and frontend tests
src-tauri/src/       Rust commands, database, engine, and lifecycle code
src-tauri/            Tauri configuration, icons, resources, and Cargo workspace
scripts/              Build, binary download, and template synchronization tools
docs/                 Development, release, audit, and implementation notes
```

## Documentation

- [中文说明](README_CN.md)
- [Development Guide](docs/DEVELOPMENT.md)
- [Release Guide](docs/RELEASE.md)
- [Security Policy](SECURITY.md)
- [Contributing Guide](CONTRIBUTING.md)

## License and source notices

This repository is maintained at [killertop/NekoPilot-Mac](https://github.com/killertop/NekoPilot-Mac). It retains the Apache-2.0 `LICENSE` and `NOTICE` files required for source attribution. NekoPilot for Mac uses its own product name, iconography, bundle identifier, and user-facing branding. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for the applicable notices.
