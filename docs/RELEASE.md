# Native macOS Release Guide

## Distribution boundary

NekoPilot is distributed through GitHub Releases only. Packages use an ad-hoc signature and are not Apple-notarized, so no Apple Developer certificate is required. Users may need to right-click **Open** once or approve the app in **System Settings → Privacy & Security**.

Only Apple Silicon macOS assets are built or published. Windows, Linux, Intel macOS, Rust/Tauri, and WebView packages are never Release assets or active source targets.

The minimum supported system is macOS 13. The workflow rejects both the Swift executable and sing-box sidecar if `vtool` reports a newer minimum version.

## Version source

`native/VERSION` is the sole Release version source. A strict `x.y.z` change on these branches starts the corresponding channel:

- `feature/dev` → rolling `dev` prerelease;
- `feature/beta` → rolling `beta` prerelease;
- `main` → immutable `v<version>` stable release.

Manual dispatch also supports a rolling `manual` channel. A stable tag can never be replaced; bump `native/VERSION` for another stable package. `native/VERSION` is the only application-version source read by the Release workflow.

## Reproducible core inputs

`native/scripts/build-sing-box-macos-arm64.sh` pins all release-critical core inputs:

- upstream SagerNet/sing-box version and commit;
- GitHub source-archive SHA-256;
- exact Go toolchain;
- exact macOS SDK selected through the pinned Xcode installation;
- upstream release build tags;
- `CGO_ENABLED=1`, `GOOS=darwin`, `GOARCH=arm64`;
- `MACOSX_DEPLOYMENT_TARGET=13.0`;
- trimmed source paths and an empty Go build ID.

The GitHub build runs this compile twice and requires identical output hashes. This proves repeatability on the pinned runner/toolchain; package hashes themselves can still differ because DMG filesystem metadata is created at packaging time.

## Local preflight

Run on Apple Silicon before changing a Release version:

```bash
git diff --check
native/scripts/check-release-policy.sh
swift build --package-path native
swift test --package-path native
swift run --package-path native NekoPilotCoreChecks
NEKOPILOT_VERIFY_REPRODUCIBLE=1 \
  native/scripts/build-sing-box-macos-arm64.sh
native/scripts/package-macos.sh
```

Then launch `native/dist/NekoPilot.app` and complete the manual acceptance list in [DEVELOPMENT.md](DEVELOPMENT.md). A successful compile or signature check is not evidence of real node connectivity or system-proxy restoration.

## GitHub Actions

`.github/workflows/test.yml` is the non-publishing hard gate. On an Apple Silicon `macos-26` runner with Xcode 26.2 and Go 1.26.5 it builds the pinned sing-box source twice, runs native tests, packages the actual bundle, mounts/extracts the artifacts, and validates architecture, `minos`, resources, version, signature, real initial-window creation, single-instance behavior, and normal quit. A separate policy check prevents publication scope from drifting.

`.github/workflows/release.yml` repeats the complete native build rather than trusting an artifact from another run. GitHub content write permission exists only in the final publish job, after all package checks pass. Rolling releases are deleted only after a replacement has been built and verified.

The exact Release asset allow-list is:

```text
NekoPilot_<version>_aarch64.dmg
NekoPilot_<version>_aarch64.app.tar.gz
SHA256SUMS
```

No updater metadata, prebuilt sidecar, universal binary, Intel archive, or secondary-platform package is uploaded.

To dispatch a stable release from `main`:

```bash
gh workflow run release.yml \
  --repo killertop/NekoPilot-Mac \
  --ref main \
  -f channel=stable
```

## VPS synchronization

Source publication continues through the VPS bare repository:

```text
local origin → us:/opt/git/NekoPilot-Mac.git → GitHub killertop/NekoPilot-Mac
```

The post-receive hook is versioned at `scripts/post-receive-github-sync.sh`. Keep it identical to `/opt/git/NekoPilot-Mac.git/hooks/post-receive`, then verify the local, VPS, and public GitHub refs after a push. No GitHub token belongs in this repository.

## Download verification

Verify the checksum first:

```bash
shasum -a 256 -c SHA256SUMS
```

After extracting the archive, verify the bundle:

```bash
codesign --verify --deep --strict --verbose=2 NekoPilot.app
lipo -archs NekoPilot.app/Contents/MacOS/NekoPilot
lipo -archs NekoPilot.app/Contents/MacOS/sing-box
vtool -show-build NekoPilot.app/Contents/MacOS/NekoPilot
vtool -show-build NekoPilot.app/Contents/MacOS/sing-box
```

Expected: both architectures are exactly `arm64`, both minimum versions are no newer than 13.0, and strict code-sign verification succeeds. `spctl` may reject the app because ad-hoc signing does not include a notarization ticket; that is expected for this GitHub-only path.

Record the Git commit, version, workflow URL, downloaded checksums, packaged-app launch result, real egress test, and system-proxy cleanup result for every production release.
