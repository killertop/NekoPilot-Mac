# Release Guide

## Release types

There are three useful package levels:

1. Development run — deno task tauri dev; debug app, not a distributable package.
2. Local Release bundle — deno task tauri build; optimized local package, normally ad-hoc signed.
3. GitHub Release package — GitHub Actions output ad-hoc signed macOS packages and uploads them to GitHub Releases.

NekoPilot is distributed from GitHub only. Apple Developer ID signing and notarization are deliberately not part of this release path. An ad-hoc signature lets Apple Silicon run a downloaded bundle, but users may still need to approve the app once in macOS Privacy & Security.

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

The normal automation is version-based: a push that changes `src-tauri/tauri.conf.json` on `feature/dev`, `feature/beta`, or `main` starts the corresponding channel. A `main` build is the stable release and is tagged `v<version>`. This prevents ordinary source commits from repeatedly overwriting the same formal release version.

To package the current committed version without changing the version file, manually dispatch the same workflow:

~~~bash
gh workflow run release.yml --repo killertop/NekoPilot-Mac --ref main -f channel=stable
~~~

The workflow must finish successfully before the GitHub Release is considered complete. macOS jobs use the Tauri ad-hoc signing identity (`-`), so they do not require Apple certificates, notarization credentials, or GitHub Actions secrets beyond the built-in `GITHUB_TOKEN`.

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

## Package verification

After downloading the macOS package, verify the application bundle:

```bash
codesign -dv --verbose=4 NekoPilot.app
codesign --verify --deep --strict --verbose=2 NekoPilot.app
spctl -a -vv NekoPilot.app || true
```

Expected results:

- `codesign --verify` succeeds and the signature is ad-hoc.
- `spctl` may reject the bundle because it has no Apple notarization ticket; this is expected for this GitHub-only release path.
- On first launch after downloading, users may need to right-click the app and choose **Open**, or approve it in **System Settings → Privacy & Security**.

## Release artifacts

The macOS release is expected to contain:

- Apple Silicon DMG package.
- Intel DMG package.
- No updater signatures or `latest.json`: the Tauri updater is not enabled in this project.

Record the Git commit, version, workflow run URL, artifact checksums, and manual QA result alongside each production release.
