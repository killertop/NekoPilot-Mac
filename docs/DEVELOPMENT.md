# Development Guide

## 1. Environment

NekoPilot for Mac is developed and manually accepted on macOS 10.15 or later.

Required tools:

- Deno 2.x
- Rust stable and Cargo
- Xcode Command Line Tools

Install dependencies from the repository root:

```bash
deno install
deno task prepare
```

## 2. Run the app

```bash
deno task tauri dev
```

The development app uses the Vite dev server and a debug Rust process. Use it for UI iteration, command wiring, and fast feedback. It is not the same artifact as the Release bundle used for package-level QA.

For a local Release build:

```bash
deno task tauri build
```

The output is under:

```text
src-tauri/target/release/bundle/
```

The local macOS bundle may be ad-hoc signed because the repository deliberately does not require a signing identity for local development.

## 3. Tests and checks

Frontend tests:

```bash
deno task test
```

Rust library tests:

```bash
cargo test --manifest-path src-tauri/Cargo.toml --lib
```

Formatting and production build checks:

```bash
git diff --check
deno task build
```

The Rust test command and frontend test command are independent. Passing them does not prove that a signed macOS application can start, control the system proxy, launch sing-box, or pass notarization.

## 4. Manual QA boundary

Manual QA is required for behavior that depends on macOS or a real network:

- Launching and closing the packaged app.
- Importing a subscription and a standalone node link.
- Selecting a group and a node.
- Connecting, stopping, reconnecting, and switching nodes.
- System Proxy mode and restoration after exit.
- Rule and Global routing behavior.
- Delay testing and failure messages.
- Upgrade behavior and local data preservation.

When reporting a failure, record the app version, package path, macOS version, node protocol, routing mode, and the relevant application log excerpt.

## 5. Configuration and generated files

The file src/config/templates/generated.ts is a versioned offline build input. Refresh it explicitly with:

```bash
deno task sync-templates
```

The release workflow refreshes the template snapshot for its selected channel. Do not commit personal subscription data or generated local databases.

## 6. Product behavior principles

- The user selects a node and connects to that node.
- A local node link is standalone configuration, not an updateable subscription.
- Connection state should represent the real execution lifecycle.
- System-level changes must be restored when the app stops or loses the relevant network state.
