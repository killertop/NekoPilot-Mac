#!/bin/zsh
set -euo pipefail

# Deliberately guarded lifecycle measurement for a packaged NekoPilot app.
# This script can quit and relaunch the app, so it must be run from an
# independent shell after explicit authorization. It never writes macOS proxy
# settings itself; all proxy ownership remains with NekoPilot.
#
# Safe default: without both --execute and NEKOPILOT_LIFECYCLE_ALLOW_STOP=YES,
# it only prints this safety notice and exits without touching any process.

script_dir="$(cd "$(dirname "$0")" && pwd)"
native_dir="$(cd "$script_dir/.." && pwd)"
app_path="/Applications/NekoPilot.app"
cycles=6
execute=false
output=""

usage() {
    print "usage: NEKOPILOT_LIFECYCLE_ALLOW_STOP=YES NEKOPILOT_LIFECYCLE_EXTERNAL_SESSION=YES measure-app-lifecycle.sh --execute [--app-path /path/NekoPilot.app] [--cycles 6] [--output results.jsonl]"
}

while (( $# > 0 )); do
    case "$1" in
        --execute)
            execute=true
            shift
            ;;
        --app-path)
            (( $# >= 2 )) || { usage >&2; exit 64; }
            app_path="$2"
            shift 2
            ;;
        --cycles)
            (( $# >= 2 )) || { usage >&2; exit 64; }
            cycles="$2"
            shift 2
            ;;
        --output)
            (( $# >= 2 )) || { usage >&2; exit 64; }
            output="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            print -u2 "unknown argument: $1"
            usage >&2
            exit 64
            ;;
    esac
done

if [[ "$execute" != true || "${NEKOPILOT_LIFECYCLE_ALLOW_STOP:-}" != YES || "${NEKOPILOT_LIFECYCLE_EXTERNAL_SESSION:-}" != YES ]]; then
    print -u2 "refusing to run lifecycle measurements: this operation can quit NekoPilot."
    print -u2 "Run only from a session that does not depend on NekoPilot networking, after explicit authorization."
    usage >&2
    exit 77
fi

[[ -d "$app_path" ]] || {
    print -u2 "app bundle not found: $app_path"
    exit 66
}
[[ "$cycles" == <-> && "$cycles" -ge 6 ]] || {
    print -u2 "--cycles must be an integer of at least 6 (one warmup plus five retained samples)"
    exit 64
}

info_plist="$app_path/Contents/Info.plist"
app_executable="$app_path/Contents/MacOS/NekoPilot"
sidecar_executable="$app_path/Contents/MacOS/sing-box"
bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$info_plist" 2>/dev/null || true)"
bundle_executable="$(plutil -extract CFBundleExecutable raw "$info_plist" 2>/dev/null || true)"
[[ "$bundle_identifier" == "dev.nekopilot.desktop" && "$bundle_executable" == "NekoPilot" && -x "$app_executable" && -x "$sidecar_executable" ]] || {
    print -u2 "refusing unverified app bundle; expected dev.nekopilot.desktop with NekoPilot and sing-box executables"
    exit 66
}
zmodload zsh/datetime || {
    print -u2 "could not load zsh/datetime for monotonic lifecycle timing"
    exit 69
}

if [[ -z "$output" ]]; then
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    output="$native_dir/.build/performance/lifecycle-$stamp.jsonl"
fi
[[ ! -e "$output" ]] || {
    print -u2 "refusing to overwrite existing measurement output: $output"
    exit 73
}
mkdir -p "$(dirname "$output")"
: > "$output"

milliseconds() {
    printf '%.0f' "$(( EPOCHREALTIME * 1000 ))"
}

json_string() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    printf '"%s"' "$value"
}

find_target_pids() {
    local candidate command_line
    for candidate in ${(f)"$(pgrep -x NekoPilot || true)"}; do
        command_line="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
        [[ "$command_line" == "$app_executable"* ]] && print "$candidate"
    done
}

find_target_sidecar_pids() {
    local app_pid="$1"
    local candidate command_line
    for candidate in ${(f)"$(pgrep -P "$app_pid" -x sing-box || true)"}; do
        command_line="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
        [[ "$command_line" == "$sidecar_executable"* ]] && print "$candidate"
    done
}

target_pids=("${(@f)$(find_target_pids)}")
(( ${#target_pids[@]} <= 1 )) || {
    print -u2 "refusing lifecycle measurement: more than one matching NekoPilot process exists"
    exit 69
}
was_running=false
original_pid=""
if (( ${#target_pids[@]} == 1 )); then
    was_running=true
    original_pid="$target_pids[1]"
fi
launched_by_script=false
launched_pid=""
last_quit_process_finished=""
last_quit_sidecar_finished=""

wait_for_target_state() {
    local expected="$1"
    local timeout_seconds="$2"
    local started="$EPOCHREALTIME"
    while true; do
        local -a observed
        observed=("${(@f)$(find_target_pids)}")
        (( ${#observed[@]} <= 1 )) || return 2
        if [[ "$expected" == true && ${#observed[@]} == 1 ]]; then
            observed_target_pid="$observed[1]"
            return 0
        fi
        if [[ "$expected" == false && ${#observed[@]} == 0 ]]; then
            observed_target_pid=""
            return 0
        fi
        (( EPOCHREALTIME - started < timeout_seconds )) || return 1
        sleep 0.05
    done
}

wait_for_pids_to_exit() {
    local timeout_seconds="$1"
    shift
    local -a pids=("$@")
    local started="$EPOCHREALTIME"
    while true; do
        local any_running=false
        local pid
        for pid in "${pids[@]}"; do
            ps -p "$pid" >/dev/null 2>&1 && any_running=true
        done
        [[ "$any_running" == false ]] && return 0
        (( EPOCHREALTIME - started < timeout_seconds )) || return 1
        sleep 0.05
    done
}

quit_app() {
    local -a observed sidecars
    observed=("${(@f)$(find_target_pids)}")
    (( ${#observed[@]} <= 1 )) || return 2
    if (( ${#observed[@]} == 0 )); then
        last_quit_process_finished="$(milliseconds)"
        last_quit_sidecar_finished="$last_quit_process_finished"
        return 0
    fi
    local target_pid="$observed[1]"
    [[ "$target_pid" == "$original_pid" || ( "$launched_by_script" == true && "$target_pid" == "$launched_pid" ) ]] || {
        print -u2 "refusing to quit a NekoPilot process not owned by this lifecycle run"
        return 2
    }
    sidecars=("${(@f)$(find_target_sidecar_pids "$target_pid")}")
    osascript -e 'tell application id "dev.nekopilot.desktop" to quit' >/dev/null
    wait_for_target_state false 30
    last_quit_process_finished="$(milliseconds)"
    wait_for_pids_to_exit 30 "${sidecars[@]}"
    last_quit_sidecar_finished="$(milliseconds)"
}

launch_app() {
    wait_for_target_state false 1 || return
    open "$app_path" >/dev/null
    wait_for_target_state true 30
    launched_pid="$observed_target_pid"
    launched_by_script=true
}

restore_original_state() {
    local status="$1"
    trap - EXIT HUP INT TERM
    local restore_status=not-needed
    local -a observed
    observed=("${(@f)$(find_target_pids)}")
    if [[ "$was_running" == true ]]; then
        if (( ${#observed[@]} == 0 )); then
            open "$app_path" >/dev/null 2>&1 && wait_for_target_state true 30 && restore_status=relaunched || restore_status=failed
        elif (( ${#observed[@]} == 1 )); then
            restore_status=already-running
        else
            restore_status=ambiguous
        fi
    elif [[ "$launched_by_script" == true && ${#observed[@]} == 1 && "$observed[1]" == "$launched_pid" ]]; then
        osascript -e 'tell application id "dev.nekopilot.desktop" to quit' >/dev/null 2>&1 && wait_for_target_state false 30 && restore_status=stopped-script-instance || restore_status=failed
    fi
    printf '{"kind":"restore","status":%s}\n' "$(json_string "$restore_status")" >> "$output"
    exit "$status"
}
trap 'restore_original_state $?' EXIT HUP INT TERM

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"kind":"metadata","timestamp":"%s","appPath":%s,"cycles":%s,"warmupRuns":1,"retainedSamples":%s,"originallyRunning":%s,"uiFirstFrame":"unavailable-without-an-explicit-accessibility-probe","connectionRecovery":"unavailable","systemProxyRestoration":"unavailable","note":"Measures process appearance, open command return, and observed sidecar exit only. Visual acceptance and transport recovery require separate authorization."}\n' \
    "$timestamp" "$(json_string "$app_path")" "$cycles" "$(( cycles - 1 ))" "$was_running" >> "$output"

for (( cycle = 1; cycle <= cycles; cycle += 1 )); do
    quit_started="$(milliseconds)"
    quit_app
    quit_finished="$(milliseconds)"

    cold_started="$(milliseconds)"
    launch_app
    cold_finished="$(milliseconds)"

    hot_started="$(milliseconds)"
    open "$app_path" >/dev/null
    hot_finished="$(milliseconds)"

    warmup=false
    (( cycle == 1 )) && warmup=true
    printf '{"kind":"sample","cycle":%s,"warmup":%s,"processDisappearanceMilliseconds":%s,"sidecarCleanupMilliseconds":%s,"coldProcessAppearanceMilliseconds":%s,"hotOpenCommandMilliseconds":%s}\n' \
        "$cycle" "$warmup" "$(( last_quit_process_finished - quit_started ))" "$(( last_quit_sidecar_finished - quit_started ))" "$(( cold_finished - cold_started ))" "$(( hot_finished - hot_started ))" >> "$output"
done

if [[ "$was_running" != true ]]; then
    quit_app || true
fi

print "[performance] Raw JSONL: $output"
