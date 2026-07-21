#!/bin/bash
set -euo pipefail

ARTIFACT_DIR=${1:-}
EXPECTED_VERSION=${2:-}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

fail() {
  echo "[artifact-verify] $*" >&2
  exit 1
}

[[ -n "$ARTIFACT_DIR" && -d "$ARTIFACT_DIR" ]] || fail "usage: $0 /path/to/artifacts VERSION"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid expected version: $EXPECTED_VERSION"

DMG="$ARTIFACT_DIR/NekoPilot_${EXPECTED_VERSION}_aarch64.dmg"
ARCHIVE="$ARTIFACT_DIR/NekoPilot_${EXPECTED_VERSION}_aarch64.app.tar.gz"
CHECKSUMS="$ARTIFACT_DIR/SHA256SUMS"

for artifact in "$DMG" "$ARCHIVE" "$CHECKSUMS"; do
  [[ -f "$artifact" ]] || fail "Missing release artifact: $artifact"
done

EXPECTED_CHECKSUM_LINES=$(wc -l < "$CHECKSUMS" | tr -d '[:space:]')
[[ "$EXPECTED_CHECKSUM_LINES" == "2" ]] || fail "SHA256SUMS must contain exactly the DMG and app archive"
(
  cd "$ARTIFACT_DIR"
  grep -Fxq "$(shasum -a 256 "$(basename "$DMG")")" SHA256SUMS || fail "DMG checksum is missing or incorrect"
  grep -Fxq "$(shasum -a 256 "$(basename "$ARCHIVE")")" SHA256SUMS || fail "Archive checksum is missing or incorrect"
)

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nekopilot-artifacts.XXXXXX")
MOUNT_DIR="$WORK_DIR/dmg"
ARCHIVE_DIR="$WORK_DIR/archive"
mkdir -p "$MOUNT_DIR" "$ARCHIVE_DIR"
DMG_ATTACHED=0
DMG_DEVICE=""
detach_dmg() {
  [[ "$DMG_ATTACHED" == "1" ]] || return 0
  sync
  for attempt in 1 2 3; do
    if hdiutil detach -quiet "$DMG_DEVICE" >/dev/null 2>&1; then
      DMG_ATTACHED=0
      return 0
    fi
    sleep "$attempt"
  done
  if hdiutil detach -quiet -force "$DMG_DEVICE" >/dev/null 2>&1; then
    DMG_ATTACHED=0
    return 0
  fi
  return 1
}
cleanup() {
  if [[ "$DMG_ATTACHED" == "1" ]]; then
    detach_dmg || true
  fi
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG"
DMG_ATTACHED=1
DMG_DEVICE=$(df "$MOUNT_DIR" | awk 'NR == 2 { print $1 }')
[[ "$DMG_DEVICE" == /dev/disk* ]] || fail "Could not determine the attached DMG device"
"$SCRIPT_DIR/verify-macos-bundle.sh" "$MOUNT_DIR/NekoPilot.app" "$EXPECTED_VERSION"
detach_dmg || fail "Could not detach verified DMG: $DMG_DEVICE"

COPYFILE_DISABLE=1 tar -xzf "$ARCHIVE" -C "$ARCHIVE_DIR"
"$SCRIPT_DIR/verify-macos-bundle.sh" "$ARCHIVE_DIR/NekoPilot.app" "$EXPECTED_VERSION"

echo "[artifact-verify] OK: $DMG"
echo "[artifact-verify] OK: $ARCHIVE"
