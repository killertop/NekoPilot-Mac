#!/bin/zsh
set -euo pipefail

# Non-invasive runtime sampler for an already-running NekoPilot installation.
# It never starts, stops, restarts, signals, or reconfigures NekoPilot,
# sing-box, or the macOS system proxy. Raw command output is retained next to
# the JSONL metrics so later reports can re-parse the exact observations.

script_dir="$(cd "$(dirname "$0")" && pwd)"
native_dir="$(cd "$script_dir/.." && pwd)"
duration_seconds=600
interval_seconds=60
output=""
requested_app_pid=""
requested_core_pid=""

usage() {
    print "usage: measure-live-runtime.sh [--duration-seconds 600] [--interval-seconds 60] [--app-pid PID] [--core-pid PID] [--output results.jsonl]"
}

while (( $# > 0 )); do
    case "$1" in
        --duration-seconds)
            (( $# >= 2 )) || { usage >&2; exit 64; }
            duration_seconds="$2"
            shift 2
            ;;
        --interval-seconds)
            (( $# >= 2 )) || { usage >&2; exit 64; }
            interval_seconds="$2"
            shift 2
            ;;
        --output)
            (( $# >= 2 )) || { usage >&2; exit 64; }
            output="$2"
            shift 2
            ;;
        --app-pid)
            (( $# >= 2 )) || { usage >&2; exit 64; }
            requested_app_pid="$2"
            shift 2
            ;;
        --core-pid)
            (( $# >= 2 )) || { usage >&2; exit 64; }
            requested_core_pid="$2"
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

[[ "$duration_seconds" == <-> && "$duration_seconds" -ge 0 ]] || {
    print -u2 "--duration-seconds must be a non-negative integer"
    exit 64
}
[[ "$interval_seconds" == <-> && "$interval_seconds" -gt 0 ]] || {
    print -u2 "--interval-seconds must be a positive integer"
    exit 64
}
[[ -z "$requested_app_pid" || "$requested_app_pid" == <-> ]] || {
    print -u2 "--app-pid must be a positive integer"
    exit 64
}
[[ -z "$requested_core_pid" || "$requested_core_pid" == <-> ]] || {
    print -u2 "--core-pid must be a positive integer"
    exit 64
}

if [[ -z "$output" ]]; then
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    output="$native_dir/.build/performance/live-runtime-$stamp.jsonl"
fi

raw_directory="${output%.jsonl}.raw"
[[ ! -e "$output" && ! -e "$raw_directory" ]] || {
    print -u2 "refusing to overwrite existing measurement output: $output"
    exit 73
}

app_bundle="/Applications/NekoPilot.app"
app_executable="$app_bundle/Contents/MacOS/NekoPilot"
core_executable="$app_bundle/Contents/MacOS/sing-box"
[[ -x "$app_executable" && -x "$core_executable" ]] || {
    print -u2 "expected NekoPilot executable or sidecar is missing from $app_bundle"
    exit 66
}

matching_apps=()
for candidate in ${(f)"$(pgrep -x NekoPilot || true)"}; do
    command_line="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
    [[ "$command_line" == "$app_executable"* ]] && matching_apps+=("$candidate")
done
if [[ -n "$requested_app_pid" ]]; then
    command_line="$(ps -p "$requested_app_pid" -o command= 2>/dev/null || true)"
    [[ "$command_line" == "$app_executable"* ]] || {
        print -u2 "--app-pid is not the expected $app_executable process"
        exit 69
    }
    app_pid="$requested_app_pid"
elif (( ${#matching_apps[@]} == 1 )); then
    app_pid="$matching_apps[1]"
else
    print -u2 "could not identify exactly one NekoPilot process for $app_bundle; use --app-pid after validating it"
    exit 69
fi

matching_cores=()
for candidate in ${(f)"$(pgrep -P "$app_pid" -x sing-box || true)"}; do
    command_line="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
    [[ "$command_line" == "$core_executable"* ]] && matching_cores+=("$candidate")
done
if [[ -n "$requested_core_pid" ]]; then
    core_parent="$(ps -p "$requested_core_pid" -o ppid= 2>/dev/null | tr -d '[:space:]')"
    command_line="$(ps -p "$requested_core_pid" -o command= 2>/dev/null || true)"
    [[ "$core_parent" == "$app_pid" && "$command_line" == "$core_executable"* ]] || {
        print -u2 "--core-pid is not the expected sing-box child of NekoPilot PID $app_pid"
        exit 69
    }
    core_pid="$requested_core_pid"
elif (( ${#matching_cores[@]} == 1 )); then
    core_pid="$matching_cores[1]"
else
    print -u2 "could not identify exactly one sing-box child of NekoPilot PID $app_pid; use --core-pid after validating it"
    exit 69
fi

mkdir -p "$(dirname "$output")" "$raw_directory"
: > "$output"

log_path="${NEKOPILOT_LOG_PATH:-$HOME/Library/Logs/dev.nekopilot.desktop/NekoPilot.log}"

json_string() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '"%s"' "$value"
}

top_metrics() {
    local pid="$1"
    local file="$2"
    /usr/bin/awk -v target="$pid" '
        $1 == target {
            cpu = $3
            time = $4
            memory = $5
            threads = $6
            ports = $7
            csw = $8
        }
        END {
            if (cpu == "") {
                print "null"
                exit
            }
            gsub(/[+-]/, "", memory)
            sub(/\/.*/, "", threads)
            gsub(/[+-]/, "", threads)
            sub(/\/.*/, "", ports)
            gsub(/[+-]/, "", ports)
            gsub(/[+-]/, "", csw)
            if (threads !~ /^[0-9]+$/) threads = "null"
            if (ports !~ /^[0-9]+$/) ports = "null"
            if (csw !~ /^[0-9]+$/) csw = "null"
            printf "{\"pid\":%d,\"cpuPercent\":%s,\"cpuTime\":\"%s\",\"memory\":\"%s\",\"threads\":%s,\"ports\":%s,\"contextSwitches\":%s}", target, cpu, time, memory, threads, ports, csw
        }
    ' "$file"
}

ps_metrics() {
    local pid="$1"
    local file="$2"
    /usr/bin/awk -v target="$pid" '
        $1 == target && NF >= 5 {
            gsub(/^ +| +$/, "", $0)
            split($0, values, / +/)
            printf "{\"pid\":%s,\"rssKiB\":%s,\"virtualKiB\":%s,\"cpuPercentLifetime\":%s,\"cpuTime\":\"%s\"}", values[1], values[2], values[3], values[4], values[5]
            found = 1
            exit
        }
        END { if (!found) print "null" }
    ' "$file"
}

tool_status() {
    command -v "$1" >/dev/null 2>&1 && print available || print unavailable
}

metadata_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"kind":"metadata","timestamp":"%s","durationSeconds":%s,"intervalSeconds":%s,"appBundle":%s,"appPid":%s,"corePid":%s,"logPath":%s,"tools":{"top":%s,"ps":%s,"nettop":%s,"sample":%s,"vmmap":%s,"powermetrics":%s,"fs_usage":%s,"xctrace":%s}}\n' \
    "$metadata_timestamp" "$duration_seconds" "$interval_seconds" "$(json_string "$app_bundle")" "$app_pid" "$core_pid" \
    "$(json_string "$log_path")" "$(json_string "$(tool_status top)")" "$(json_string "$(tool_status ps)")" \
    "$(json_string "$(tool_status nettop)")" "$(json_string "$(tool_status sample)")" \
    "$(json_string "$(tool_status vmmap)")" "$(json_string "$(tool_status powermetrics)")" \
    "$(json_string "$(tool_status fs_usage)")" "$(json_string "$(tool_status xctrace)")" >> "$output"

sample_index=0
started_at="$(date +%s)"
while true; do
    sample_directory="$raw_directory/$(printf '%04d' "$sample_index")"
    mkdir -p "$sample_directory"
    sample_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    top -l 2 -s 1 -n 20 -pid "$app_pid" -pid "$core_pid" \
        -stats pid,command,cpu,time,mem,threads,ports,csw > "$sample_directory/top.txt" 2>&1 || true
    ps -p "$app_pid","$core_pid" -o pid=,rss=,vsz=,pcpu=,time=,command= > "$sample_directory/ps.txt" 2>&1 || true
    log_bytes=null
    log_stat_status=missing
    if [[ -e "$log_path" ]]; then
        if stat -f '%z' "$log_path" > "$sample_directory/log-bytes.txt" 2> "$sample_directory/log-stat-error.txt"; then
            candidate_log_bytes="$(tr -d '[:space:]' < "$sample_directory/log-bytes.txt")"
            if [[ "$candidate_log_bytes" == <-> ]]; then
                log_bytes="$candidate_log_bytes"
                log_stat_status=ok
            else
                log_stat_status=invalid-output
            fi
        else
            log_stat_status=error
        fi
    fi
    nettop -n -d -m tcp -p "$app_pid" -p "$core_pid" -L 2 -s 1 -P > "$sample_directory/nettop.txt" 2>&1 || true

    app_top="$(top_metrics "$app_pid" "$sample_directory/top.txt")"
    core_top="$(top_metrics "$core_pid" "$sample_directory/top.txt")"
    app_ps="$(ps_metrics "$app_pid" "$sample_directory/ps.txt")"
    core_ps="$(ps_metrics "$core_pid" "$sample_directory/ps.txt")"
    completed_at="$(date +%s)"
    elapsed=$(( completed_at - started_at ))
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    printf '{"kind":"sample","sampleStartedAt":"%s","timestamp":"%s","index":%s,"elapsedSeconds":%s,"appTop":%s,"coreTop":%s,"appPS":%s,"corePS":%s,"logBytes":%s,"logStatStatus":%s,"rawDirectory":%s}\n' \
        "$sample_started_at" "$timestamp" "$sample_index" "$elapsed" "$app_top" "$core_top" "$app_ps" "$core_ps" "$log_bytes" "$(json_string "$log_stat_status")" \
        "$(json_string "$sample_directory")" >> "$output"

    (( sample_index += 1 ))
    (( elapsed >= duration_seconds )) && break
    next_sample_at=$(( started_at + sample_index * interval_seconds ))
    sleep_seconds=$(( next_sample_at - completed_at ))
    (( sleep_seconds > 0 )) && sleep "$sleep_seconds"
done

print "[performance] Raw JSONL: $output"
print "[performance] Raw command output: $raw_directory"
