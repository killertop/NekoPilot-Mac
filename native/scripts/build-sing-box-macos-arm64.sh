#!/bin/bash
set -euo pipefail

# Reproducible, source-pinned sing-box build for the only supported release
# target: Apple Silicon on macOS 13 or newer.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NATIVE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

SING_BOX_VERSION="1.14.0-alpha.48"
SING_BOX_COMMIT="fa36eb769a200e9558c414a36eb16da9a2446ea9"
SING_BOX_ARCHIVE_SHA256="f823c45154065b8707c85a02213dd1df9daee5ccb1c5f625de4cae67974d1d1e"
GO_VERSION="1.26.5"
MACOS_DEPLOYMENT_TARGET="13.0"
MACOS_SDK_VERSION="26.2"
SOURCE_DATE_EPOCH="1779788717"
# Clash is deliberately absent: NekoPilot uses only the native sing-box 1.14
# API service, bound to loopback with an ephemeral secret by Swift.
BUILD_TAGS="with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_tailscale,with_ccm,with_ocm,with_cloudflared,with_naive_outbound,badlinkname,tfogo_checklinkname0"
# `-buildid=` clears Go's identifier. `-B none` also suppresses the Mach-O
# LC_UUID that Go's Darwin linker otherwise generates differently on each
# link, so the CI double-build check compares meaningful identical outputs.
LDFLAGS="-X github.com/sagernet/sing-box/constant.Version=${SING_BOX_VERSION} -X internal/godebug.defaultGODEBUG=multipathtcp=0 -checklinkname=0 -buildid= -B none"

OUTPUT=${NEKOPILOT_SING_BOX_OUTPUT:-"$NATIVE_DIR/.build/sidecar/sing-box"}
VERIFY_REPRODUCIBLE=${NEKOPILOT_VERIFY_REPRODUCIBLE:-0}

fail() {
  echo "[sing-box-build] $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

assert_macos_13_or_older() {
  local binary=$1
  local minos
  minos=$(vtool -show-build "$binary" | awk '$1 == "minos" { print $2; exit }')
  [[ -n "$minos" ]] || fail "vtool did not report LC_BUILD_VERSION minos for $binary"
  awk -v version="$minos" 'BEGIN {
    split(version, parts, ".")
    major = parts[1] + 0
    minor = parts[2] + 0
    exit !((major < 13) || (major == 13 && minor <= 0))
  }' || fail "$binary requires macOS $minos; release binaries must require macOS 13.0 or older"
}

validate_binary() {
  local binary=$1
  [[ -x "$binary" ]] || fail "Build did not create an executable: $binary"
  [[ "$(lipo -archs "$binary")" == "arm64" ]] || \
    fail "Expected an arm64-only binary, got: $(lipo -archs "$binary")"
  assert_macos_13_or_older "$binary"

  local version_output
  version_output=$("$binary" version)
  grep -Fq "sing-box version $SING_BOX_VERSION" <<<"$version_output" || \
    fail "Unexpected sing-box version output"
  grep -Fq "Environment: go${GO_VERSION} darwin/arm64" <<<"$version_output" || \
    fail "Unexpected Go toolchain or target in sing-box version output"
  grep -Fq "Tags: $BUILD_TAGS" <<<"$version_output" || \
    fail "sing-box was not built with the pinned upstream release tags"
  grep -Fq "CGO: enabled" <<<"$version_output" || fail "sing-box must be built with CGO enabled"
}

[[ "$(uname -s)" == "Darwin" ]] || fail "This release build only runs on macOS"
[[ "$(uname -m)" == "arm64" ]] || fail "This release build only runs on Apple Silicon"

for command_name in gh go shasum tar lipo vtool install xcrun; do
  require_command "$command_name"
done

ACTUAL_GO_VERSION=$(go env GOVERSION)
[[ "$ACTUAL_GO_VERSION" == "go${GO_VERSION}" ]] || \
  fail "Go go${GO_VERSION} is required exactly; found $ACTUAL_GO_VERSION"
ACTUAL_SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
[[ "$ACTUAL_SDK_VERSION" == "$MACOS_SDK_VERSION" ]] || \
  fail "macOS SDK $MACOS_SDK_VERSION is required exactly; found $ACTUAL_SDK_VERSION"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nekopilot-sing-box.XXXXXX")
STAGED_OUTPUT=""
cleanup() {
  # The Go module cache is intentionally read-only. Make the task-owned temp
  # tree writable before removal so interrupted builds do not leak gigabytes.
  chmod -R u+w "$WORK_DIR" >/dev/null 2>&1 || true
  rm -rf -- "$WORK_DIR"
  if [[ -n "$STAGED_OUTPUT" ]]; then
    rm -f -- "$STAGED_OUTPUT"
  fi
}
trap cleanup EXIT

ARCHIVE="$WORK_DIR/sing-box.tar.gz"
SOURCE_PARENT="$WORK_DIR/source"
# Module archives are verified against the upstream go.sum on every build.
# Keep that verified cache outside the disposable source tree so a local
# rebuild after changing only NekoPilot's wrapper does not redownload the
# entire sing-box dependency graph.
GO_MODULE_CACHE=${NEKOPILOT_GO_MODULE_CACHE:-"$(go env GOMODCACHE)"}
mkdir -p "$SOURCE_PARENT"

echo "[sing-box-build] Downloading SagerNet/sing-box $SING_BOX_COMMIT"
gh api "repos/SagerNet/sing-box/tarball/$SING_BOX_COMMIT" > "$ARCHIVE"

ACTUAL_ARCHIVE_SHA256=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
[[ "$ACTUAL_ARCHIVE_SHA256" == "$SING_BOX_ARCHIVE_SHA256" ]] || \
  fail "Source archive SHA-256 mismatch: expected $SING_BOX_ARCHIVE_SHA256, got $ACTUAL_ARCHIVE_SHA256"

if tar -tzf "$ARCHIVE" | awk -F/ '($1 == "" || $1 == "." || $1 == "..") { exit 1 } { for (i = 1; i <= NF; i++) if ($i == "..") exit 1 }'; then
  :
else
  fail "Source archive contains an unsafe path"
fi

tar -xzf "$ARCHIVE" -C "$SOURCE_PARENT"
SOURCE_ROOT=$(find "$SOURCE_PARENT" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n "$SOURCE_ROOT" && -f "$SOURCE_ROOT/go.mod" ]] || fail "Downloaded archive has no sing-box source root"
grep -Fxq "module github.com/sagernet/sing-box" "$SOURCE_ROOT/go.mod" || fail "Unexpected Go module in source archive"
build_once() {
  local destination=$1
  local build_cache=$2
  (
    cd "$SOURCE_ROOT"
    export CGO_ENABLED=1
    export CC
    CC=$(xcrun --sdk macosx --find clang)
    export GOARCH=arm64
    export GOENV=off
    export GOFLAGS=""
    export GOOS=darwin
    export GOTOOLCHAIN=local
    export GOWORK=off
    export GOCACHE="$build_cache"
    export GOMODCACHE="$GO_MODULE_CACHE"
    # proxy.golang.org is not reachable on a number of Chinese networks.
    # Use a module mirror for transport only; the pinned upstream source's
    # go.sum still verifies every downloaded archive before it is compiled.
    export GOPROXY="https://goproxy.cn,direct"
    export GONOPROXY=""
    export GONOSUMDB="*"
    export GOPRIVATE=""
    export GOSUMDB=off
    export LC_ALL=C
    export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"
    export SDKROOT
    SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
    export SOURCE_DATE_EPOCH
    export TZ=UTC
    go build \
      -mod=readonly \
      -buildvcs=false \
      -trimpath \
      -tags "$BUILD_TAGS" \
      -ldflags "$LDFLAGS" \
      -o "$destination" \
      ./cmd/sing-box
  )
  chmod 0755 "$destination"
  validate_binary "$destination"
}

FIRST_BUILD="$WORK_DIR/sing-box-first"
build_once "$FIRST_BUILD" "$WORK_DIR/go-build-cache-first"

if [[ "$VERIFY_REPRODUCIBLE" == "1" ]]; then
  SECOND_BUILD="$WORK_DIR/sing-box-second"
  build_once "$SECOND_BUILD" "$WORK_DIR/go-build-cache-second"
  FIRST_SHA256=$(shasum -a 256 "$FIRST_BUILD" | awk '{print $1}')
  SECOND_SHA256=$(shasum -a 256 "$SECOND_BUILD" | awk '{print $1}')
  [[ "$FIRST_SHA256" == "$SECOND_SHA256" ]] || \
    fail "Two builds from the same pinned inputs differ: $FIRST_SHA256 != $SECOND_SHA256"
  echo "[sing-box-build] Reproducibility check passed: $FIRST_SHA256"
fi

mkdir -p "$(dirname "$OUTPUT")"
STAGED_OUTPUT="${OUTPUT}.new.$$"
install -m 0755 "$FIRST_BUILD" "$STAGED_OUTPUT"
mv -f -- "$STAGED_OUTPUT" "$OUTPUT"
STAGED_OUTPUT=""

validate_binary "$OUTPUT"
echo "[sing-box-build] Built $OUTPUT"
shasum -a 256 "$OUTPUT"
