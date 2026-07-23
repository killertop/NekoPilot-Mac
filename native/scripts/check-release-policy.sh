#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
RELEASE="$ROOT/.github/workflows/release.yml"
TEST="$ROOT/.github/workflows/test.yml"
GUIDE="$ROOT/docs/RELEASE.md"
CORE_BUILD="$ROOT/native/scripts/build-sing-box-macos-arm64.sh"
PACKAGE="$ROOT/native/scripts/package-macos.sh"
APP_ICON="$ROOT/native/Resources/AppIcon.icns"
MENU_ICON="$ROOT/native/Resources/menu-bar-template.png"
LOGO="$ROOT/native/Resources/NekoPilotLogo.png"

fail() {
  echo "[release-policy] $*" >&2
  exit 1
}

require_text() {
  local file=$1
  local value=$2
  grep -Fq -- "$value" "$file" || fail "$file is missing required policy text: $value"
}

reject_pattern() {
  local file=$1
  local pattern=$2
  if grep -Eiq -- "$pattern" "$file"; then
    fail "$file contains forbidden release pattern: $pattern"
  fi
}

require_text "$RELEASE" "runs-on: macos-26"
require_text "$RELEASE" 'native/VERSION'
require_text "$RELEASE" 'native/scripts/package-macos.sh'
require_text "$RELEASE" 'NekoPilot_${VERSION}_aarch64.dmg'
require_text "$RELEASE" 'NekoPilot_${VERSION}_aarch64.app.tar.gz'
require_text "$RELEASE" 'SHA256SUMS'

for forbidden in \
  'runs-on:[[:space:]]*windows-' \
  'build-(windows|linux|macos-x86)' \
  '\.(msi|exe|deb|rpm|AppImage)([^A-Za-z]|$)' \
  '(x86_64|amd64|intel)' \
  'tauri-action' \
  'deno task tauri' \
  'src-tauri/tauri\.conf\.json'; do
  reject_pattern "$RELEASE" "$forbidden"
done

require_text "$TEST" "Native Apple Silicon hard gate"
require_text "$TEST" "runs-on: macos-26"
require_text "$TEST" "native/scripts/package-macos.sh"
reject_pattern "$TEST" 'contents:[[:space:]]*write'
reject_pattern "$TEST" 'gh release'
reject_pattern "$TEST" 'actions/upload-artifact'

require_text "$CORE_BUILD" 'SING_BOX_VERSION="1.14.0-beta.1"'
require_text "$CORE_BUILD" 'SING_BOX_COMMIT="8bc6787c7ff785e5f6343241affdadd5ca239bd7"'
require_text "$CORE_BUILD" 'SING_BOX_ARCHIVE_SHA256="90394c042267558802b88329e85b3669e9e229eccea1387bfd79805bfb710ebf"'
require_text "$CORE_BUILD" 'GO_VERSION="1.26.5"'
require_text "$CORE_BUILD" 'MACOS_DEPLOYMENT_TARGET="13.0"'
require_text "$CORE_BUILD" 'MACOS_SDK_VERSION="26.2"'
require_text "$CORE_BUILD" 'SOURCE_DATE_EPOCH="1784812860"'
require_text "$CORE_BUILD" 'EXPECTED_UPSTREAM_LDFLAGS="-X runtime.godebugDefault=multipathtcp=0,tlssha1=1,tlsunsafeekm=1 -checklinkname=0"'
require_text "$CORE_BUILD" 'release/LDFLAGS'
require_text "$CORE_BUILD" 'vtool -show-build'
require_text "$CORE_BUILD" './cmd/sing-box'
require_text "$CORE_BUILD" '-B gobuildid'
require_text "$CORE_BUILD" 'BUILD_TAGS="with_quic,with_dhcp,with_utls,with_naive_outbound,badlinkname,tfogo_checklinkname0"'
require_text "$CORE_BUILD" 'LDFLAGS="-s -w '
require_text "$CORE_BUILD" 'canonical_macho_sha256'
reject_pattern "$CORE_BUILD" 'src-tauri/binaries'

require_text "$PACKAGE" 'menu-bar-template.png'
require_text "$PACKAGE" '$NATIVE_DIR/Resources/AppIcon.icns'
require_text "$PACKAGE" '$NATIVE_DIR/Resources/menu-bar-template.png'
require_text "$PACKAGE" 'LSMultipleInstancesProhibited'
require_text "$PACKAGE" 'swift test --package-path'
require_text "$PACKAGE" 'strip -S -x "$APP_BUNDLE/Contents/MacOS/NekoPilot"'
require_text "$PACKAGE" '-format UDZO -imagekey zlib-level=9'
require_text "$PACKAGE" 'verify-macos-artifacts.sh'

require_text "$GUIDE" "Only Apple Silicon macOS assets are built or published"
require_text "$GUIDE" "Windows, Linux, Intel macOS, Rust/Tauri, and WebView packages are never Release assets or active source targets"
require_text "$GUIDE" 'native/VERSION'

for resource in "$APP_ICON" "$MENU_ICON" "$LOGO"; do
  [[ -f "$resource" ]] || fail "Missing native source resource: $resource"
done

TRACKED=$(git -C "$ROOT" ls-files)
if grep -Eq '(^|/)(Cargo\.toml|Cargo\.lock|[^/]+\.rs)$' <<<"$TRACKED"; then
  fail "Tracked Rust or Cargo source is forbidden"
fi
if grep -Eq '(^|/)(go\.mod|go\.sum|[^/]+\.go)$' <<<"$TRACKED"; then
  fail "NekoPilot must not ship custom Go source; the upstream sing-box binary is built from its pinned source archive"
fi
if grep -Eq '^(src-tauri|src|public)/|^(package\.json|deno\.json|deno\.lock|index\.html|vite\.config\.ts|vitest\.config\.ts|tsconfig[^/]*\.json)$' <<<"$TRACKED"; then
  fail "Tracked legacy Tauri/React application source is forbidden"
fi

for forbidden_source in \
  'src-tauri/' \
  '@tauri-apps/' \
  'cargo tauri' \
  'deno task tauri'; do
  if git -C "$ROOT" grep -Fq -- "$forbidden_source" -- \
    ':!CHANGELOG.MD' \
    ':!docs/design-reference/**' \
    ':!native/scripts/check-release-policy.sh'; then
    fail "Active source still references retired runtime: $forbidden_source"
  fi
done

echo "[release-policy] Native Apple Silicon publication policy passed"
