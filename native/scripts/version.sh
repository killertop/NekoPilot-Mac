#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
VERSION_FILE="$SCRIPT_DIR/../VERSION"
MODE=${1:---check}

VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "[version] invalid semantic version: $VERSION" >&2
  exit 1
fi

case "$MODE" in
  --check)
    echo "[version] OK: $VERSION"
    ;;
  --bump-patch)
    IFS=. read -r major minor patch <<<"$VERSION"
    next="$major.$minor.$((patch + 1))"
    printf '%s\n' "$next" > "$VERSION_FILE"
    echo "[version] $VERSION -> $next"
    ;;
  *)
    echo "usage: $0 [--check|--bump-patch]" >&2
    exit 1
    ;;
esac
