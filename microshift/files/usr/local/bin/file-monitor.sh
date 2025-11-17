#!/bin/bash
set -euo pipefail

CONFIG_FILE="${FILE_MONITOR_CONFIG:-/etc/file-monitor/monitor.conf}"
LOG_FILE="${FILE_MONITOR_LOG:-/var/log/file-monitor.log}"
PID_FILE="/var/run/file-monitor.pid"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

if ! command -v inotifywait &>/dev/null; then
    log "ERROR: inotifywait not found. Install: yum install inotify-tools"
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

echo $$ > "$PID_FILE"
log "Starting file monitor service"
log "Using configuration: $CONFIG_FILE"

declare -A WATCH_DIRS       # real directories
declare -A WATCH_EVENTS     # event lists
declare -A WATCH_ACTIONS    # commands
declare -A WATCH_PATTERNS   # original glob patterns

parse_config() {
    local line_num=0
    log "DEBUG: Starting config parse"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))

        # Skip empty or comment lines
        if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        # Trim whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [[ "$line" =~ ^([^|]+)\|([^|]+)\|(.+)$ ]]; then
            local pattern="${BASH_REMATCH[1]}"
            local events="${BASH_REMATCH[2]}"
            local action="${BASH_REMATCH[3]}"

            # Get directory from the pattern
            local dir
            dir=$(dirname "$pattern")

            if [[ ! -d "$dir" ]]; then
                log "WARNING: Directory does not exist (line $line_num): $dir"
                continue
            fi

            log "DEBUG: Configured: dir='$dir' pattern='$pattern'"

            WATCH_DIRS["$dir"]="$dir"
            WATCH_EVENTS["$dir"]="$events"
            WATCH_ACTIONS["$dir"]="$action"
            WATCH_PATTERNS["$dir"]="$pattern"

        else
            log "WARNING: Invalid configuration line $line_num: $line"
        fi
    done < "$CONFIG_FILE"

    log "DEBUG: Config parse complete. Found ${#WATCH_DIRS[@]} directories"
}

build_monitor_list() {
    local dirs=()
    for d in "${!WATCH_DIRS[@]}"; do
        dirs+=("$d")
    done

    if [[ ${#dirs[@]} -eq 0 ]]; then
        log "ERROR: No valid directories to monitor"
        exit 1
    fi

    echo "${dirs[@]}"
}

event_matches_pattern() {
    local fullpath="$1"
    local pattern="$2"

    [[ "$fullpath" == $pattern ]]
}

execute_action() {
    local path="$1"
    local event="$2"
    local file="$3"

    local fullpath="${path}${file}"

    for key in "${!WATCH_DIRS[@]}"; do
        local dir="${WATCH_DIRS[$key]}"

        # Only process files within this directory
        [[ "$path" == "$dir/" ]] || continue

        local pattern="${WATCH_PATTERNS[$key]}"
        local events="${WATCH_EVENTS[$key]}"
        local action="${WATCH_ACTIONS[$key]}"

        # Check pattern match
        if ! event_matches_pattern "$fullpath" "$pattern"; then
            continue
        fi

        # Check event match
        if [[ "$events" != "all" ]]; then
            if [[ ",$events," != *",$event,"* ]]; then
                continue
            fi
        fi

        log "Event '$event' on '$fullpath' matches pattern '$pattern' → Executing: $action"

        # Export variables for the user's action script
        export MONITOR_PATH="$dir"
        export MONITOR_EVENT="$event"
        export MONITOR_FILE="$file"
        export MONITOR_FULLPATH="$fullpath"

        if eval "$action" >>"$LOG_FILE" 2>&1; then
            log "Action completed successfully"
        else
            log "ERROR: Action failed"
        fi
    done
}

cleanup() {
    log "Shutting down file monitor service"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT

main() {
    parse_config

    log "Parsed ${#WATCH_DIRS[@]} directories"
    for key in "${!WATCH_DIRS[@]}"; do
        log "  - ${WATCH_DIRS[$key]} (pattern: ${WATCH_PATTERNS[$key]})"
    done

    local monitor_dirs
    monitor_dirs=$(build_monitor_list)
    log "Monitoring ${#WATCH_DIRS[@]} directory(ies)"

    while true; do
        inotifywait -m -r -e modify,create,delete,move,attrib \
            --format '%w|%e|%f' \
            $monitor_dirs 2>>"$LOG_FILE" | \
        while IFS='|' read -r path event file; do
            execute_action "$path" "$event" "$file"
        done

        log "WARNING: inotifywait exited, restarting in 5 seconds..."
        sleep 5
    done
}

main
