# Security Policy

## Scope

This project handles proxy subscriptions, node configurations, local application state, and network-related settings. Security reports are welcome for issues that could expose credentials, bypass user-selected routing behavior, execute unintended commands, or corrupt protected local state.

## Reporting a vulnerability

Please do not publish credentials, subscription URLs, private keys, or a full exploit in a public Issue. Contact the repository owner privately through the GitHub account that owns this repository, including:

- A short description of the issue.
- Affected version or commit.
- Reproduction steps or a minimal proof of concept.
- Potential impact.
- Any suggested mitigation.

If the issue involves a real subscription or node, remove the URL and replace secrets with a local test fixture before sharing.

## Development safety

- Never commit subscription URLs, API keys, private keys, certificates, or personal databases.
- Treat imported configuration content as untrusted input.
- Keep local logs and exported configurations out of Issues and Pull Requests unless they have been sanitized.
- Verify the ad-hoc signature of macOS release packages and clearly disclose the required first-launch Gatekeeper approval before distributing them.
- Keep the upstream commit, source-archive SHA-256, exact Go version, release tags, and macOS deployment target in `native/scripts/build-sing-box-macos-arm64.sh` synchronized with the reviewed sing-box version. Native Releases must build from that verified source; never substitute a downloaded executable.
