#!/bin/bash
set -euo pipefail

CONFIG_FILE="${FILE_MONITOR_CONFIG:-/etc/file-monitor/monitor.conf}"
LOG_FILE="${FILE_MONITOR_LOG:-/var/log/file-monitor.log}"
PID_FILE="/var/run/file-monitor.pid"

touch $LOG_FILE

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

if ! command -v inotifywait &> /dev/null; then
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

declare -A WATCH_PATHS
declare -A WATCH_EVENTS
declare -A WATCH_ACTIONS

parse_config() {
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [[ "$line" =~ ^([^|]+)\|([^|]+)\|(.+)$ ]]; then
            local path="${BASH_REMATCH[1]}"
            local events="${BASH_REMATCH[2]}"
            local action="${BASH_REMATCH[3]}"
            
            if [[ ! -e "$path" ]]; then
                log "WARNING: Path does not exist (line $line_num): $path"
                continue
            fi
            
            WATCH_PATHS["$path"]="$path"
            WATCH_EVENTS["$path"]="$events"
            WATCH_ACTIONS["$path"]="$action"
            log "Configured: $path -> Events: $events -> Action: $action"
        else
            log "WARNING: Invalid configuration line $line_num: $line"
        fi
    done < "$CONFIG_FILE"
}

build_monitor_list() {
    local paths=()
    for key in "${!WATCH_PATHS[@]}"; do
        paths+=("${WATCH_PATHS[$key]}")
    done
    
    if [[ ${#paths[@]} -eq 0 ]]; then
        log "ERROR: No valid paths to monitor"
        exit 1
    fi
    echo "${paths[@]}"
}

execute_action() {
    local path="$1"
    local event="$2"
    local file="$3"
    
    for key in "${!WATCH_PATHS[@]}"; do
        if [[ "$path" == "${WATCH_PATHS[$key]}" ]]; then
            local configured_events="${WATCH_EVENTS[$key]}"
            local action="${WATCH_ACTIONS[$key]}"
            
            if [[ ",$configured_events," == *",$event,"* ]] || \
               [[ " $configured_events " == *" $event "* ]] || \
               [[ "$configured_events" == "all" ]]; then
                
                log "Event '$event' on '$path/$file' - Executing: $action"
                
                export MONITOR_PATH="$path"
                export MONITOR_EVENT="$event"
                export MONITOR_FILE="$file"
                export MONITOR_FULLPATH="$path/$file"
                
                if eval "$action" >> "$LOG_FILE" 2>&1; then
                    log "Action completed successfully"
                else
                    log "ERROR: Action failed with exit code $?"
                fi
            fi
            break
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
    local monitor_paths
    monitor_paths=$(build_monitor_list)
    log "Monitoring ${#WATCH_PATHS[@]} path(s)"
    
    while true; do
        inotifywait -m -r -e modify,create,delete,move,attrib \
            --format '%w|%e|%f' \
            $monitor_paths 2>> "$LOG_FILE" | \
        while IFS='|' read -r path event file; do
            execute_action "$path" "$event" "$file"
        done
        
        log "WARNING: inotifywait exited, restarting in 5 seconds..."
        sleep 5
    done
}

main
