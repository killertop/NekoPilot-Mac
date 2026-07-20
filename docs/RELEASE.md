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
deno install --frozen
deno audit --lock=deno.lock
deno task check:versions
deno task test
cargo test --manifest-path src-tauri/Cargo.toml --lib
deno task build
deno task tauri build
```

Then manually test the local Release bundle on macOS. Confirm import, selection, connection, stop, reconnect, routing mode, and system proxy restoration.

## GitHub Actions release

The release workflow is `.github/workflows/release.yml`. It builds and publishes macOS arm64 and x86_64 packages. Linux packages remain secondary, best-effort artifacts. Windows packages are deliberately not built, copied between release channels, or published; macOS remains the required acceptance platform for this repository.

The normal automation is version-based: a push that changes `src-tauri/tauri.conf.json` on `feature/dev`, `feature/beta`, or `main` starts the corresponding channel. A `main` build is the stable release and is tagged `v<version>`. This prevents ordinary source commits from repeatedly overwriting the same formal release version.

To rerun the current committed stable version, manually dispatch the same workflow from `main`:

~~~bash
gh workflow run release.yml --repo killertop/NekoPilot-Mac --ref main -f channel=stable
~~~

The selected channel is restricted to its canonical branch (`dev` to `feature/dev`, `beta` to `feature/beta`, and `stable` to `main`). The `manual` rolling channel may run from another selected ref. A stable `v<version>` tag is immutable: rerunning the same commit is allowed, but publishing a different commit under an existing version is rejected.

Before any rolling tag is deleted or package is published, the workflow repeats the release-critical preflight: synchronized versions, locked frontend install and audit, production frontend build and tests, sidecar checksum verification, Rust formatting, Clippy, and Rust tests. This is intentional because the independent Test workflow starts in parallel and cannot gate a direct version push by itself.

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
2. Run `make bump` to increment the synchronized version in `package.json`, `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml`, and the NekoPilot entry in `src-tauri/Cargo.lock`.
3. Update the relevant CHANGELOG.MD entry.
4. Run the local preflight checks.
5. Push the version change to the stable branch through the VPS route above.
6. Wait for the release workflow to finish.
7. Download the DMG and app.tar.gz assets from the resulting GitHub Release.

`make bump` only updates those four version files. It never stages or commits files. Update `CHANGELOG.MD`, inspect the complete diff, run the preflight, and create the release commit explicitly.

The workflow also supports dev, beta, stable, and manual channels through GitHub Actions manual dispatch. Stable and beta reuse upstream artifacts only when both the application version and the Git object fingerprint of every build input match. Any source, configuration, lockfile, resource, changelog, or build-script difference forces a fresh build.

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

- Apple Silicon DMG and `.app.tar.gz` archive.
- Intel DMG and `.app.tar.gz` archive.
- No updater signatures or `latest.json`: the Tauri updater is not enabled in this project.

The workflow may additionally produce Linux DEB, RPM, or AppImage packages. It must never publish Windows EXE, MSI, or NSIS installers. These secondary Linux artifacts passing CI is not a substitute for platform-specific runtime acceptance.

Record the Git commit, version, workflow run URL, artifact checksums, and manual QA result alongside each production release.
