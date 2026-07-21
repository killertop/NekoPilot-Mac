#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
RELEASE="$ROOT/.github/workflows/release.yml"
TEST="$ROOT/.github/workflows/test.yml"
GUIDE="$ROOT/docs/RELEASE.md"
CORE_BUILD="$ROOT/native/scripts/build-sing-box-macos-arm64.sh"
PACKAGE="$ROOT/native/scripts/package-macos.sh"

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

require_text "$CORE_BUILD" 'SING_BOX_COMMIT="25a600db24f7680ad9806ce5427bd0ab8afe1114"'
require_text "$CORE_BUILD" 'GO_VERSION="1.26.5"'
require_text "$CORE_BUILD" 'MACOS_DEPLOYMENT_TARGET="13.0"'
require_text "$CORE_BUILD" 'MACOS_SDK_VERSION="26.2"'
require_text "$CORE_BUILD" 'SING_BOX_ARCHIVE_SHA256='
require_text "$CORE_BUILD" 'vtool -show-build'
require_text "$CORE_BUILD" './cmd/sing-box'
reject_pattern "$CORE_BUILD" 'src-tauri/binaries'

require_text "$PACKAGE" 'menu-bar-template.png'
require_text "$PACKAGE" 'LSMultipleInstancesProhibited'
require_text "$PACKAGE" 'swift test --package-path'
require_text "$PACKAGE" 'verify-macos-artifacts.sh'
require_text "$PACKAGE" 'smoke-test-macos-app.sh'

require_text "$GUIDE" "Only Apple Silicon macOS assets are built or published"
require_text "$GUIDE" "Windows, Linux, Intel macOS, and Tauri packages are never Release assets"
require_text "$GUIDE" 'native/VERSION'

echo "[release-policy] Native Apple Silicon publication policy passed"
