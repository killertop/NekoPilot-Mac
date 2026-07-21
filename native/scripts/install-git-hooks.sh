#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

git config --local core.hooksPath .githooks
actual=$(git config --local --get core.hooksPath)
[[ "$actual" == ".githooks" ]] || {
  echo "[git-hooks] failed to activate repository hooks" >&2
  exit 1
}

echo "[git-hooks] active: $actual"
