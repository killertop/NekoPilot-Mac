#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NATIVE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
VERSION=$(tr -d '[:space:]' < "$NATIVE_DIR/VERSION")
OUTPUT_DIR=${1:-"$NATIVE_DIR/dist"}
APP_NAME="NekoPilot.app"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME"
SING_BOX_SOURCE=${NEKOPILOT_SING_BOX_SOURCE:-"$NATIVE_DIR/.build/sidecar/sing-box"}
ICON_SOURCE="$NATIVE_DIR/Resources/AppIcon.icns"
MENU_ICON_SOURCE="$NATIVE_DIR/Resources/menu-bar-template.png"

fail() {
  echo "[native-package] $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Native release packages can only be built on macOS"
[[ "$(uname -m)" == "arm64" ]] || fail "Only Apple Silicon release packages are supported"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid native/VERSION: $VERSION"

if [[ ! -x "$SING_BOX_SOURCE" ]]; then
  echo "[native-package] No validated sidecar found; building it from pinned upstream source"
  NEKOPILOT_SING_BOX_OUTPUT="$SING_BOX_SOURCE" "$SCRIPT_DIR/build-sing-box-macos-arm64.sh"
fi

for resource in "$ICON_SOURCE" "$MENU_ICON_SOURCE"; do
  [[ -f "$resource" ]] || fail "Missing package resource: $resource"
done

mkdir -p "$OUTPUT_DIR"

NEKOPILOT_SING_BOX="$SING_BOX_SOURCE" \
NEKOPILOT_VALIDATE_SINGBOX_IMPORT=1 \
  swift test --package-path "$NATIVE_DIR"
swift build --package-path "$NATIVE_DIR" -c release --arch arm64 --product NekoPilot
swift run --package-path "$NATIVE_DIR" -c release NekoPilotCoreChecks
BUILD_ROOT=$(swift build --package-path "$NATIVE_DIR" -c release --arch arm64 --show-bin-path)
[[ -x "$BUILD_ROOT/NekoPilot" ]] || fail "Swift release executable was not produced"

if [[ -e "$APP_BUNDLE" ]]; then
  rm -rf -- "$APP_BUNDLE"
fi
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/rules"

install -m 0755 "$BUILD_ROOT/NekoPilot" "$APP_BUNDLE/Contents/MacOS/NekoPilot"
install -m 0755 "$SING_BOX_SOURCE" "$APP_BUNDLE/Contents/MacOS/sing-box"
install -m 0644 "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
install -m 0644 "$MENU_ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/menu-bar-template.png"
install -m 0644 "$NATIVE_DIR/Sources/NekoPilotCore/Resources/base-config.json" "$APP_BUNDLE/Contents/Resources/base-config.json"
install -m 0644 "$NATIVE_DIR/Sources/NekoPilotCore/Resources/rules/geoip-cn.srs" "$APP_BUNDLE/Contents/Resources/rules/geoip-cn.srs"
install -m 0644 "$NATIVE_DIR/Sources/NekoPilotCore/Resources/rules/geosite-cn.srs" "$APP_BUNDLE/Contents/Resources/rules/geosite-cn.srs"

PLIST="$APP_BUNDLE/Contents/Info.plist"
plutil -create xml1 "$PLIST"
plutil -insert CFBundleDisplayName -string NekoPilot "$PLIST"
plutil -insert CFBundleName -string NekoPilot "$PLIST"
plutil -insert CFBundleExecutable -string NekoPilot "$PLIST"
plutil -insert CFBundleIdentifier -string dev.nekopilot.desktop "$PLIST"
plutil -insert CFBundlePackageType -string APPL "$PLIST"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -insert CFBundleVersion -string "$VERSION" "$PLIST"
plutil -insert CFBundleIconFile -string AppIcon "$PLIST"
plutil -insert LSMinimumSystemVersion -string 13.0 "$PLIST"
plutil -insert LSMultipleInstancesProhibited -bool YES "$PLIST"
plutil -insert NSHighResolutionCapable -bool YES "$PLIST"
plutil -insert CFBundleURLTypes -json '[{"CFBundleURLName":"dev.nekopilot.desktop.config","CFBundleURLSchemes":["nekopilot"]}]' "$PLIST"

# Strip machine-local extended attributes before sealing the resource envelope.
xattr -cr "$APP_BUNDLE"
codesign --force --sign - --timestamp=none "$APP_BUNDLE/Contents/MacOS/sing-box"
codesign --force --sign - --timestamp=none "$APP_BUNDLE"
"$SCRIPT_DIR/verify-macos-bundle.sh" "$APP_BUNDLE" "$VERSION"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nekopilot-package.XXXXXX")
trap 'rm -rf -- "$WORK_DIR"' EXIT
DMG_SOURCE="$WORK_DIR/dmg"
mkdir -p "$DMG_SOURCE"
cp -R "$APP_BUNDLE" "$DMG_SOURCE/NekoPilot.app"
ln -s /Applications "$DMG_SOURCE/Applications"

DMG_PATH="$OUTPUT_DIR/NekoPilot_${VERSION}_aarch64.dmg"
ARCHIVE_PATH="$OUTPUT_DIR/NekoPilot_${VERSION}_aarch64.app.tar.gz"
CHECKSUM_PATH="$OUTPUT_DIR/SHA256SUMS"
rm -f -- "$DMG_PATH" "$ARCHIVE_PATH" "$CHECKSUM_PATH"
hdiutil create -quiet -fs HFS+ -volname NekoPilot -srcfolder "$DMG_SOURCE" -format UDZO "$DMG_PATH"
COPYFILE_DISABLE=1 tar -C "$OUTPUT_DIR" -czf "$ARCHIVE_PATH" "$APP_NAME"
(
  cd "$OUTPUT_DIR"
  LC_ALL=C shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$ARCHIVE_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

"$SCRIPT_DIR/verify-macos-artifacts.sh" "$OUTPUT_DIR" "$VERSION"
"$SCRIPT_DIR/smoke-test-macos-app.sh" "$APP_BUNDLE"

echo "[native-package] Built and verified native macOS artifacts:"
echo "  $APP_BUNDLE"
echo "  $DMG_PATH"
echo "  $ARCHIVE_PATH"
echo "  $CHECKSUM_PATH"
