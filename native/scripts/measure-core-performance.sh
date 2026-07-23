#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NATIVE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
ROOT=$(cd "$NATIVE_DIR/.." && pwd)
OUTPUT_ROOT=${NEKOPILOT_PERFORMANCE_OUTPUT_ROOT:-"$NATIVE_DIR/.build/performance"}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUTPUT="$OUTPUT_ROOT/NekoPilotBench-$STAMP.jsonl"
BENCH_ARGS=()
OUTPUT_WAS_SET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { echo "usage: $0 [--output results.jsonl] [NekoPilotBench options]" >&2; exit 2; }
      [[ "$OUTPUT_WAS_SET" == false ]] || { echo "[performance] --output may be supplied only once" >&2; exit 2; }
      OUTPUT=$2
      OUTPUT_WAS_SET=true
      shift 2
      ;;
    *)
      BENCH_ARGS+=("$1")
      shift
      ;;
  esac
done

mkdir -p "$(dirname "$OUTPUT")"

NEKOPILOT_BENCH_COMMIT=$(git -C "$ROOT" rev-parse HEAD) \
NEKOPILOT_BENCH_VERSION=$(tr -d '[:space:]' < "$NATIVE_DIR/VERSION") \
  swift run --package-path "$NATIVE_DIR" -c release NekoPilotBench --output "$OUTPUT" "${BENCH_ARGS[@]}"

echo "[performance] Raw JSONL: $OUTPUT"
