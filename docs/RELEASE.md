# Release Guide

## Release types

There are three useful package levels:

1. Development run — deno task tauri dev; debug app, not a distributable package.
2. Local Release bundle — deno task tauri build; optimized local package, normally ad-hoc signed.
3. Official release package — GitHub Actions output signed with an Apple Developer ID certificate and notarized by Apple.

Only the third type should be described as the final formal release package.

## Local preflight

Before starting a release, run:

```bash
git diff --check
deno task test
cargo test --manifest-path src-tauri/Cargo.toml --lib
deno task build
deno task tauri build
```

Then manually test the local Release bundle on macOS. Confirm import, selection, connection, stop, reconnect, routing mode, and system proxy restoration.

## GitHub Actions release

The release workflow is .github/workflows/release.yml. It builds macOS arm64 and x86_64 packages and publishes the resulting assets to a GitHub Release.

## GitHub synchronization through the VPS

Source publication uses a VPS bare repository as the network boundary:

~~~text
local origin → us:/opt/git/NekoPilot-Mac.git → GitHub killertop/NekoPilot-Mac
~~~

The VPS bare repository has a post-receive hook at /opt/git/NekoPilot-Mac.git/hooks/post-receive. It forwards branch and tag updates to the GitHub remote, configured as https://github.com/killertop/NekoPilot-Mac.git.

One-time local setup:

~~~bash
git remote set-url origin us:/opt/git/NekoPilot-Mac.git
git remote set-url --push origin us:/opt/git/NekoPilot-Mac.git
~~~

After the one-time VPS setup, publish normally from the repository root:

~~~bash
git push origin main
~~~

The local origin intentionally points to us:/opt/git/NekoPilot-Mac.git; the Mac does not push directly to GitHub. The VPS uses its own gh/Git HTTPS credential setup for killertop, so no GitHub token is stored in this repository.

The hook is versioned at scripts/post-receive-github-sync.sh. If the VPS hook changes, keep the repository copy and the installed VPS copy identical, then verify both the VPS bare ref and the GitHub ref.

The intended stable flow is:

1. Finish and review the code and documentation.
2. Increment the version in src-tauri/tauri.conf.json.
3. Update the relevant CHANGELOG.MD entry.
4. Run the local preflight checks.
5. Push the version change to the stable branch through the VPS route above.
6. Wait for the release workflow to finish.
7. Download the DMG and app.tar.gz assets from the resulting GitHub Release.

The repository convention is to use make bump for a version bump. It commits all current changes after confirmation, so inspect git status first and only run it when every listed change belongs in the release.

The workflow also supports dev, beta, stable, and manual channels through GitHub Actions manual dispatch. Stable and beta may reuse an upstream artifact when the version matches; use a new version when the current source must be rebuilt.

## Required GitHub secrets

The macOS jobs reference these secrets:

- APPLE_CERTIFICATE — base64-encoded Apple signing certificate in .p12 format.
- APPLE_CERTIFICATE_PASSWORD — password for that certificate.
- APPLE_AUTH_KEY — App Store Connect API key file content in .p8 format.
- APPLE_API_KEY — App Store Connect API key ID.
- APPLE_API_ISSUER — App Store Connect issuer ID.
- TAURI_PRIVATE_KEY — Tauri updater signing private key.
- KEYCHAIN_PASSWORD — temporary keychain password used by the macOS job.

The certificate must be suitable for Developer ID distribution, and the App Store Connect key must be authorized for notarization. Never put any of these values in the repository or in an Issue, PR, log, or screenshot.

## Package verification

After downloading the macOS package, verify the application bundle:

```bash
codesign -dv --verbose=4 NekoPilot.app
codesign --verify --deep --strict --verbose=2 NekoPilot.app
spctl -a -vv NekoPilot.app
xcrun stapler validate NekoPilot.app
```

Expected results:

- codesign shows a Developer ID Application authority and a non-empty team identifier.
- The signature is not adhoc.
- spctl reports the app as accepted.
- stapler validate succeeds for the notarization ticket.

If the bundle still reports Signature=adhoc, it is a local-style package and must not be distributed as the final official build.

## Release artifacts

The macOS release is expected to contain:

- Apple Silicon DMG and app.tar.gz packages.
- Intel DMG and app.tar.gz packages.
- Matching updater signature files.
- latest.json when the updater metadata is generated.

Record the Git commit, version, workflow run URL, artifact checksums, and manual QA result alongside each production release.
