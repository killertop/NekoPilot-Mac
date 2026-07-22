#!/bin/bash
set -euo pipefail

APP_BUNDLE=${1:-}
EXPECTED_VERSION=${2:-}
EXPECTED_SING_BOX_VERSION="1.14.0-alpha.48"
EXPECTED_GO_VERSION="1.26.5"
EXPECTED_TAGS="with_quic,with_dhcp,with_utls,with_naive_outbound,badlinkname,tfogo_checklinkname0"
EXPECTED_MENU_ICON_SHA256="4c632710a7644b1704fc7995fae95e1dee53c854984eb74e52c43c9ec7718213"

fail() {
  echo "[bundle-verify] $*" >&2
  exit 1
}

[[ -n "$APP_BUNDLE" && -d "$APP_BUNDLE" ]] || fail "usage: $0 /path/to/NekoPilot.app VERSION"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid expected version: $EXPECTED_VERSION"

PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/NekoPilot"
SING_BOX="$APP_BUNDLE/Contents/MacOS/sing-box"
MENU_ICON="$APP_BUNDLE/Contents/Resources/menu-bar-template.png"

for required_path in \
  "$PLIST" \
  "$APP_EXECUTABLE" \
  "$SING_BOX" \
  "$APP_BUNDLE/Contents/Resources/AppIcon.icns" \
  "$MENU_ICON" \
  "$APP_BUNDLE/Contents/Resources/base-config.json" \
  "$APP_BUNDLE/Contents/Resources/rules/geoip-cn.srs" \
  "$APP_BUNDLE/Contents/Resources/rules/geosite-cn.srs"; do
  [[ -e "$required_path" ]] || fail "Missing bundle resource: $required_path"
done

assert_arm64_only() {
  local binary=$1
  local architectures
  architectures=$(lipo -archs "$binary")
  [[ "$architectures" == "arm64" ]] || fail "$binary is not arm64-only: $architectures"
}

assert_macos_13_or_older() {
  local binary=$1
  local minos
  minos=$(vtool -show-build "$binary" | awk '$1 == "minos" { print $2; exit }')
  [[ -n "$minos" ]] || fail "vtool did not report minos for $binary"
  awk -v version="$minos" 'BEGIN {
    split(version, parts, ".")
    major = parts[1] + 0
    minor = parts[2] + 0
    exit !((major < 13) || (major == 13 && minor <= 0))
  }' || fail "$binary requires macOS $minos; expected macOS 13.0 or older"
}

assert_arm64_only "$APP_EXECUTABLE"
assert_arm64_only "$SING_BOX"
assert_macos_13_or_older "$APP_EXECUTABLE"
assert_macos_13_or_older "$SING_BOX"
if nm -m "$APP_EXECUTABLE" 2>/dev/null | awk 'index($0, "non-external") { found = 1 } END { exit !found }'; then
  fail "Packaged Swift executable still contains local symbols"
fi
if go tool nm "$SING_BOX" 2>/dev/null | awk '/ runtime\.main$| github\.com\/sagernet\/sing-box\// { found = 1 } END { exit !found }'; then
  fail "Packaged sing-box still contains Go symbol/debug tables"
fi

[[ "$(plutil -extract CFBundleIdentifier raw "$PLIST")" == "dev.nekopilot.desktop" ]] || fail "Unexpected bundle identifier"
[[ "$(plutil -extract CFBundleShortVersionString raw "$PLIST")" == "$EXPECTED_VERSION" ]] || fail "Unexpected short version"
[[ "$(plutil -extract CFBundleVersion raw "$PLIST")" == "$EXPECTED_VERSION" ]] || fail "Unexpected bundle version"
[[ "$(plutil -extract LSMinimumSystemVersion raw "$PLIST")" == "13.0" ]] || fail "Unexpected minimum macOS version"
[[ "$(plutil -extract LSMultipleInstancesProhibited raw "$PLIST")" == "true" ]] || fail "Multiple app instances must be prohibited"
if plutil -extract LSUIElement raw "$PLIST" >/dev/null 2>&1; then
  fail "LSUIElement must stay absent so SwiftUI can create the initial WindowGroup before AppDelegate switches to accessory mode"
fi

file "$MENU_ICON" | grep -Fq "PNG image data" || fail "Menu-bar template is not a PNG"
[[ "$(shasum -a 256 "$MENU_ICON" | awk '{print $1}')" == "$EXPECTED_MENU_ICON_SHA256" ]] || fail "Unexpected menu-bar template artwork"

VERSION_OUTPUT=$("$SING_BOX" version)
grep -Fq "sing-box version $EXPECTED_SING_BOX_VERSION" <<<"$VERSION_OUTPUT" || fail "Unexpected sing-box version"
grep -Fq "Environment: go${EXPECTED_GO_VERSION} darwin/arm64" <<<"$VERSION_OUTPUT" || fail "Unexpected sing-box Go toolchain or target"
grep -Fq "Tags: $EXPECTED_TAGS" <<<"$VERSION_OUTPUT" || fail "Unexpected sing-box build tags"
grep -Fq "CGO: enabled" <<<"$VERSION_OUTPUT" || fail "sing-box CGO must be enabled"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
echo "[bundle-verify] OK: $APP_BUNDLE ($EXPECTED_VERSION, Apple Silicon, macOS 13+)"
