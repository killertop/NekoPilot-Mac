#!/bin/bash
set -euo pipefail

APP_BUNDLE=${1:-}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

fail() {
  echo "[app-smoke] $*" >&2
  if [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]]; then
    tail -100 "$LOG_FILE" >&2 || true
  fi
  exit 1
}

[[ -n "$APP_BUNDLE" && -d "$APP_BUNDLE" ]] || fail "usage: $0 /path/to/NekoPilot.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/NekoPilot"
[[ -x "$APP_EXECUTABLE" ]] || fail "Missing packaged executable: $APP_EXECUTABLE"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nekopilot-app-smoke.XXXXXX")
SMOKE_HOME="$WORK_DIR/home"
LOG_FILE="$WORK_DIR/NekoPilot.log"
mkdir -p "$SMOKE_HOME/Library/Application Support"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    osascript -e 'tell application id "dev.nekopilot.desktop" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
      kill -0 "$APP_PID" >/dev/null 2>&1 || break
      sleep 1
    done
    if kill -0 "$APP_PID" >/dev/null 2>&1; then
      kill -TERM "$APP_PID" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

CFFIXED_USER_HOME="$SMOKE_HOME" "$APP_EXECUTABLE" >"$LOG_FILE" 2>&1 &
APP_PID=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$APP_PID" >/dev/null 2>&1 || fail "Packaged application terminated during startup"
  WINDOW_COUNT=$(swift "$SCRIPT_DIR/window-count.swift" "$APP_PID")
  if [[ "$WINDOW_COUNT" == "1" ]]; then
    break
  fi
  sleep 1
done
[[ "${WINDOW_COUNT:-0}" == "1" ]] || fail "Expected one visible packaged-app window, found ${WINDOW_COUNT:-0}"

# A background executable launch can leave an accessory app on another Space.
# Reopening the bundle activates the existing locked instance and moves its
# main window onto the runner's active Space before accessibility navigation.
open "$APP_BUNDLE"
sleep 1

set +e
swift "$SCRIPT_DIR/ui-smoke.swift" "$APP_PID"
UI_SMOKE_STATUS=$?
set -e
case "$UI_SMOKE_STATUS" in
  0) ;;
  77) echo "[app-smoke] Accessibility navigation skipped: test runner permission is unavailable" ;;
  *) fail "Native UI navigation smoke test failed" ;;
esac

CFFIXED_USER_HOME="$SMOKE_HOME" "$APP_EXECUTABLE" >>"$LOG_FILE" 2>&1 &
SECOND_PID=$!
for _ in 1 2 3 4 5; do
  if ! kill -0 "$SECOND_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if kill -0 "$SECOND_PID" >/dev/null 2>&1; then
  kill -TERM "$SECOND_PID" >/dev/null 2>&1 || true
  fail "A second packaged-app process remained alive"
fi
kill -0 "$APP_PID" >/dev/null 2>&1 || fail "Second launch terminated the original application"

osascript -e 'tell application id "dev.nekopilot.desktop" to quit'
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
kill -0 "$APP_PID" >/dev/null 2>&1 && fail "Packaged application did not complete its normal quit handshake"
APP_PID=""

echo "[app-smoke] OK: initial window, single instance, and normal quit"
