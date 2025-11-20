#!/bin/bash
set -euo pipefail

CONFIG_PATH="${FILE_MONITOR_CONFIG:-/usr/lib/flightctl/hooks.d/afterupdating/}"
LOG_FILE="${FILE_MONITOR_LOG:-/var/log/file-monitor.log}"
PID_FILE="/var/run/file-monitor.pid"
MAX_PARALLEL="${FILE_MONITOR_MAX_PARALLEL:-5}"
DEBOUNCE_TIME="${FILE_MONITOR_DEBOUNCE:-2}"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Job control
declare -A JOB_PIDS=()
declare -A PENDING_EVENTS=()
LOCK_DIR="/var/run/file-monitor-locks"
mkdir -p "$LOCK_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PID:$$] $*" | tee -a "$LOG_FILE"
}

# Check for required tools
if ! command -v inotifywait &>/dev/null; then
    log "ERROR: inotifywait not found. Install: yum install inotify-tools"
    exit 1
fi

if ! command -v yq &>/dev/null; then
    log "ERROR: yq not found. Install: wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && chmod +x /usr/bin/yq"
    exit 1
fi

# Determine if CONFIG_PATH is a directory or a file
if [[ -d "$CONFIG_PATH" ]]; then
    CONFIG_DIR="$CONFIG_PATH"
    log "Using configuration directory: $CONFIG_DIR"
    
    # Check if directory has any .yaml or .yml files
    shopt -s nullglob
    yaml_files=("$CONFIG_DIR"/*.yaml "$CONFIG_DIR"/*.yml)
    shopt -u nullglob

    if [[ ${#yaml_files[@]} -eq 0 ]]; then
        log "ERROR: No YAML configuration files found in $CONFIG_DIR"
        exit 1
    fi
elif [[ -f "$CONFIG_PATH" ]]; then
    CONFIG_FILE="$CONFIG_PATH"
    log "Using configuration file: $CONFIG_FILE"
else
    log "ERROR: Configuration path not found: $CONFIG_PATH"
    exit 1
fi

echo $$ > "$PID_FILE"
log "Starting file monitor service (max $MAX_PARALLEL parallel jobs, ${DEBOUNCE_TIME}s debounce)"

declare -a RULES=()

parse_yaml_config() {
    log "DEBUG: Starting YAML config parse"
    
    local config_files=()
    
    # Collect configuration files
    if [[ -n "${CONFIG_DIR:-}" ]]; then
        # Load all .yaml and .yml files from directory, sorted
        while IFS= read -r file; do
            config_files+=("$file")
        done < <(find "$CONFIG_DIR" -maxdepth 1 -type f \( -name "*.yaml" -o -name "*.yml" \) | sort)
        
        log "DEBUG: Found ${#config_files[@]} configuration files in $CONFIG_DIR"
    else
        # Single configuration file
        config_files=("$CONFIG_FILE")
        log "DEBUG: Using single configuration file: $CONFIG_FILE"
    fi
    
    # Parse each configuration file
    for config_file in "${config_files[@]}"; do
        log "DEBUG: Parsing $config_file"
        
        local rule_count
        rule_count=$(yq eval '. | length' "$config_file")
        
        if [[ "$rule_count" -eq 0 ]] || [[ "$rule_count" == "null" ]]; then
            log "WARNING: No rules found in $config_file"
            continue
        fi
        
        for ((i=0; i<rule_count; i++)); do
            local rule_json
            rule_json=$(yq eval ".[$i] | @json" "$config_file")
            RULES+=("$rule_json")
            
            local path
            path=$(echo "$rule_json" | yq eval '.if[0].path' -)
            local run
            run=$(echo "$rule_json" | yq eval '.run' -)
            
            log "DEBUG: Rule ${#RULES[@]}: path='$path' run='$run' (from $(basename "$config_file"))"
        done
    done
    
    if [[ ${#RULES[@]} -eq 0 ]]; then
        log "ERROR: No rules found in any configuration files"
        exit 1
    fi
    
    log "DEBUG: Config parse complete. Found ${#RULES[@]} rules total"
}

build_monitor_list() {
    local -A unique_dirs
    
    for rule in "${RULES[@]}"; do
        local if_count
        if_count=$(echo "$rule" | yq eval '.if | length' -)
        
        for ((j=0; j<if_count; j++)); do
            local path
            path=$(echo "$rule" | yq eval ".if[$j].path" -)
            
            if [[ ! -e "$path" ]]; then
                log "WARNING: Path does not exist: $path"
                continue
            fi
            
            # If path is a file, monitor its directory
            if [[ -f "$path" ]]; then
                path=$(dirname "$path")
            fi
            
            # Remove trailing slash if present
            path="${path%/}"
            unique_dirs["$path"]=1
        done
    done
    
    if [[ ${#unique_dirs[@]} -eq 0 ]]; then
        log "ERROR: No valid paths to monitor"
        exit 1
    fi
    
    echo "${!unique_dirs[@]}"
}

match_path_condition() {
    local fullpath="$1"
    local condition_path="$2"
    local event="$3"
    local ops="$4"
    
    # Check if the changed file matches the condition path
    local matches=0
    
    if [[ -d "$condition_path" ]]; then
        # Directory: check if file is within it
        local dir_path="${condition_path%/}/"
        if [[ "$fullpath" == "$dir_path"* ]]; then
            matches=1
        fi
    else
        # File: exact match
        if [[ "$fullpath" == "$condition_path" ]]; then
            matches=1
        fi
    fi
    
    if [[ $matches -eq 0 ]]; then
        return 1
    fi
    
    # Check if event operation matches
    if [[ "$ops" != "null" ]] && [[ -n "$ops" ]]; then
        local normalized_event
        case "$event" in
            CREATE|MOVED_TO) normalized_event="created" ;;
            MODIFY|ATTRIB) normalized_event="updated" ;;
            DELETE|MOVED_FROM) normalized_event="removed" ;;
            *) normalized_event="updated" ;;
        esac
        
        if [[ ",$ops," != *",$normalized_event,"* ]]; then
            return 1
        fi
    fi
    
    return 0
}

# Acquire lock with timeout
acquire_lock() {
    local lock_name="$1"
    local timeout="${2:-30}"
    local lock_file="$LOCK_DIR/$lock_name.lock"
    local waited=0
    
    while [[ $waited -lt $timeout ]]; do
        if mkdir "$lock_file" 2>/dev/null; then
            echo $$ > "$lock_file/pid"
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    
    return 1
}

release_lock() {
    local lock_name="$1"
    local lock_file="$LOCK_DIR/$lock_name.lock"
    rm -rf "$lock_file" 2>/dev/null || true
}

# Wait for job slots to be available
wait_for_slot() {
    while true; do
        # Clean up finished jobs
        for pid in "${!JOB_PIDS[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                unset JOB_PIDS["$pid"]
            fi
        done
        
        if [[ ${#JOB_PIDS[@]} -lt $MAX_PARALLEL ]]; then
            return 0
        fi
        
        sleep 0.2
    done
}

execute_action() {
    local path="$1"
    local event="$2"
    local file="$3"
    
    local fullpath="${path}${file}"
    
    # Create a unique lock name for this file
    local lock_name
    lock_name=$(echo "$fullpath" | md5sum | cut -d' ' -f1)
    
    # Debouncing: Check if there's already a pending event for this file
    local event_key="${fullpath}:${event}"
    local now
    now=$(date +%s)
    
    if [[ -n "${PENDING_EVENTS[$event_key]:-}" ]]; then
        local last_time="${PENDING_EVENTS[$event_key]}"
        local elapsed=$((now - last_time))
        
        if [[ $elapsed -lt $DEBOUNCE_TIME ]]; then
            log "DEBUG: Debouncing event '$event' on '$fullpath' (${elapsed}s since last)"
            PENDING_EVENTS[$event_key]=$now
            return 0
        fi
    fi
    
    PENDING_EVENTS[$event_key]=$now
    
    # Track matched files for each condition path
    declare -A created_files
    declare -A updated_files
    declare -A removed_files
    declare -A all_files
    
    # Normalize event for file categorization
    local normalized_event
    case "$event" in
        CREATE|MOVED_TO) 
            normalized_event="created"
            ;;
        MODIFY|ATTRIB) 
            normalized_event="updated"
            ;;
        DELETE|MOVED_FROM) 
            normalized_event="removed"
            ;;
        *) 
            normalized_event="updated"
            ;;
    esac
    
    # Process each rule
    for rule_idx in "${!RULES[@]}"; do
        local rule="${RULES[$rule_idx]}"
        
        local if_count
        if_count=$(echo "$rule" | yq eval '.if | length' -)
        
        # Check all conditions
        local all_conditions_met=1
        local condition_paths=()
        
        for ((j=0; j<if_count; j++)); do
            local condition_path
            condition_path=$(echo "$rule" | yq eval ".if[$j].path" -)
            
            local ops
            ops=$(echo "$rule" | yq eval ".if[$j].op | join(\",\")" -)
            
            condition_paths+=("$condition_path")
            
            if ! match_path_condition "$fullpath" "$condition_path" "$event" "$ops"; then
                all_conditions_met=0
                break
            fi
            
            # Track files for this condition path
            all_files["$condition_path"]+="$fullpath "
            case "$normalized_event" in
                created) created_files["$condition_path"]+="$fullpath " ;;
                updated) updated_files["$condition_path"]+="$fullpath " ;;
                removed) removed_files["$condition_path"]+="$fullpath " ;;
            esac
        done
        
        if [[ $all_conditions_met -eq 0 ]]; then
            continue
        fi
        
        # Execute the run command in background with locking
        local run_cmd
        run_cmd=$(echo "$rule" | yq eval '.run' -)
        
        local timeout
        timeout=$(echo "$rule" | yq eval '.timeout // "300s"' -)
        
        local workdir
        workdir=$(echo "$rule" | yq eval '.workDir // "/"' -)
        
        log "Event '$event' on '$fullpath' matches rule $rule_idx → Queuing: $run_cmd"
        
        # Wait for available slot
        wait_for_slot
        
        # Execute in background subshell
        (
            # Try to acquire lock
            if ! acquire_lock "$lock_name" 10; then
                log "WARNING: Could not acquire lock for '$fullpath', skipping duplicate execution"
                exit 0
            fi
            
            trap "release_lock '$lock_name'" EXIT
            
            log "DEBUG: [Worker $$] Executing action for '$fullpath'"
            
            # Prepare environment variables
            export MONITOR_EVENT="$normalized_event"
            export MONITOR_FILE="$file"
            export MONITOR_FULLPATH="$fullpath"
            
            # Set Flight Control-style variables for the first condition path
            if [[ ${#condition_paths[@]} -gt 0 ]]; then
                local first_path="${condition_paths[0]}"
                export Path="$first_path"
                export Files="${all_files[$first_path]:-}"
                export CreatedFiles="${created_files[$first_path]:-}"
                export UpdatedFiles="${updated_files[$first_path]:-}"
                export RemovedFiles="${removed_files[$first_path]:-}"
            fi
            
            # Parse environment variables from config
            local env_count
            env_count=$(echo "$rule" | yq eval '.envVars | length' - 2>/dev/null || echo 0)
            
            if [[ "$env_count" != "0" ]] && [[ "$env_count" != "null" ]]; then
                local env_vars
                env_vars=$(echo "$rule" | yq eval '.envVars | to_entries | .[] | .key + "=" + .value' -)
                while IFS= read -r env_var; do
                    export "$env_var"
                done <<< "$env_vars"
            fi
            
            # Execute with timeout
            cd "$workdir" || cd /
            
            if timeout "$timeout" bash -c "$run_cmd" >>"$LOG_FILE" 2>&1; then
                log "DEBUG: [Worker $$] Action completed successfully for '$fullpath'"
            else
                local exit_code=$?
                if [[ $exit_code -eq 124 ]]; then
                    log "ERROR: [Worker $$] Action timed out after $timeout for '$fullpath'"
                else
                    log "ERROR: [Worker $$] Action failed with exit code $exit_code for '$fullpath'"
                fi
            fi
        ) &
        
        local worker_pid=$!
        JOB_PIDS[$worker_pid]=1
        log "DEBUG: Started worker $worker_pid for rule $rule_idx"
    done
}

cleanup() {
    log "Shutting down file monitor service"
    
    # Wait for all background jobs to complete
    log "Waiting for ${#JOB_PIDS[@]} background jobs to complete..."
    for pid in "${!JOB_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
        fi
    done
    
    # Clean up locks
    rm -rf "$LOCK_DIR"
    rm -f "$PID_FILE"
    
    log "File monitor service stopped"
    exit 0
}

trap cleanup SIGTERM SIGINT

main() {
    parse_yaml_config
    
    log "Parsed ${#RULES[@]} rules"
    
    local monitor_dirs
    monitor_dirs=$(build_monitor_list)
    log "Monitoring directories: $monitor_dirs"
    
    while true; do
        inotifywait -m -r -e modify,create,delete,move,attrib \
            --format '%w|%e|%f' \
            $monitor_dirs 2>>"$LOG_FILE" | \
        while IFS='|' read -r path event file; do
            # Process events immediately without blocking
            execute_action "$path" "$event" "$file"
        done
        
        log "WARNING: inotifywait exited, restarting in 5 seconds..."
        sleep 5
    done
}

main