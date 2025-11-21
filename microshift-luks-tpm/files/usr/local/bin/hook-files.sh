#!/bin/bash
set -euo pipefail

# Configurable enrollment check interval (in seconds)
ENROLLMENT_CHECK_INTERVAL="${ENROLLMENT_CHECK_INTERVAL:-300}"  # Default: 5 minutes

# Extension filtering configuration
# Blacklist: comma-separated list of extensions to ignore (without the dot)
# Default includes temporary and backup files
FILE_MONITOR_BLACKLIST="${FILE_MONITOR_BLACKLIST:-swp,swpx,swx,swo,bak,tmp,temp,~,orig,rej,dpkg-old,dpkg-new,dpkg-dist,rpmsave,rpmnew,new,tmp-*}"

# Whitelist: comma-separated list of extensions to allow (without the dot)
# Use "*" (default) to allow all extensions (subject to blacklist)
# If set to specific extensions, only those will be processed
FILE_MONITOR_WHITELIST="${FILE_MONITOR_WHITELIST:-*}"

## Initial enrollment check
check_enrollment() {
    set +e
    /usr/local/bin/check-enrollment.sh
    local status=$?
    set -e
    return $status
}

# Check enrollment initially
if check_enrollment; then
    echo "Device is already enrolled, stopping."
    exit 0
else
    echo "Device is not enrolled or pending, continuing..."
fi

#####

# Start periodic enrollment checker in background
start_enrollment_monitor() {
    (
        while true; do
            sleep "$ENROLLMENT_CHECK_INTERVAL"
            
            if check_enrollment; then
                log "Device has been enrolled. Stopping file monitor service."
                # Send SIGTERM to main process
                kill -TERM "$$" 2>/dev/null || true
                exit 0
            fi
        done
    ) &
    
    ENROLLMENT_MONITOR_PID=$!
    echo "$ENROLLMENT_MONITOR_PID" > "/var/run/file-monitor-enrollment.pid"
    log "Started enrollment monitor (PID: $ENROLLMENT_MONITOR_PID, checking every ${ENROLLMENT_CHECK_INTERVAL}s)"
}

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

# Parse blacklist and whitelist into arrays
IFS=',' read -ra BLACKLIST_ARRAY <<< "$FILE_MONITOR_BLACKLIST"
IFS=',' read -ra WHITELIST_ARRAY <<< "$FILE_MONITOR_WHITELIST"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PID:$$] $*" | tee -a "$LOG_FILE"
}

# Check if a file extension should be processed
should_process_extension() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    
    # Skip hidden files and common temporary patterns
    if [[ "$filename" =~ ^\. ]] || [[ "$filename" =~ \.tmp- ]] || [[ "$filename" =~ ^\..*\.tmp ]]; then
        log "DEBUG: Skipping temporary file pattern: $filepath"
        return 1
    fi
    
    # Extract extension (everything after the last dot, lowercase)
    local ext=""
    if [[ "$filename" =~ \. ]]; then
        ext="${filename##*.}"
        ext="${ext,,}"  # Convert to lowercase
    fi
    
    # Handle special case: files ending with ~ (like file.txt~)
    if [[ "$filename" =~ ~$ ]]; then
        log "DEBUG: Skipping file with ~ suffix: $filepath"
        return 1
    fi
    
    # Check blacklist first
    if [[ -n "$ext" ]]; then
        for blacklisted in "${BLACKLIST_ARRAY[@]}"; do
            blacklisted="${blacklisted,,}"  # Convert to lowercase
            blacklisted="${blacklisted# }"   # Trim leading space
            blacklisted="${blacklisted% }"   # Trim trailing space
            if [[ "$ext" == "$blacklisted" ]]; then
                log "DEBUG: Skipping blacklisted extension .$ext: $filepath"
                return 1
            fi
        done
    fi
    
    # Check whitelist
    if [[ "$FILE_MONITOR_WHITELIST" != "*" ]]; then
        # Whitelist is specific, check if extension is allowed
        if [[ -z "$ext" ]]; then
            # No extension, check if empty string is in whitelist
            local found=0
            for allowed in "${WHITELIST_ARRAY[@]}"; do
                allowed="${allowed# }"   # Trim spaces
                allowed="${allowed% }"
                if [[ -z "$allowed" ]]; then
                    found=1
                    break
                fi
            done
            if [[ $found -eq 0 ]]; then
                log "DEBUG: File without extension not in whitelist: $filepath"
                return 1
            fi
        else
            # Check if extension is in whitelist
            local found=0
            for allowed in "${WHITELIST_ARRAY[@]}"; do
                allowed="${allowed,,}"  # Convert to lowercase
                allowed="${allowed# }"   # Trim spaces
                allowed="${allowed% }"
                if [[ "$ext" == "$allowed" ]]; then
                    found=1
                    break
                fi
            done
            if [[ $found -eq 0 ]]; then
                log "DEBUG: Extension .$ext not in whitelist: $filepath"
                return 1
            fi
        fi
    fi
    
    return 0
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
log "Extension filtering - Blacklist: $FILE_MONITOR_BLACKLIST"
log "Extension filtering - Whitelist: $FILE_MONITOR_WHITELIST"

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
    declare -g -A MONITOR_PATHS  # Global: paths to monitor
    declare -g -A PATH_TYPES      # Global: track if path is file or dir
    
    for rule in "${RULES[@]}"; do
        local if_count
        if_count=$(echo "$rule" | yq eval '.if | length' -)
        
        for ((j=0; j<if_count; j++)); do
            local path
            path=$(echo "$rule" | yq eval ".if[$j].path" -)
            
            # Remove trailing slash if present
            path="${path%/}"
            
            # Check if path exists
            if [[ ! -e "$path" ]]; then
                log "WARNING: Path does not exist: $path"
                # For non-existent paths, determine type by checking if it has an extension or ends with /
                # If original path had trailing /, it's a directory
                local original_path
                original_path=$(echo "$rule" | yq eval ".if[$j].path" -)
                
                if [[ "$original_path" =~ /$ ]]; then
                    # Original had trailing slash, it's a directory - monitor parent
                    local parent_dir
                    parent_dir=$(dirname "$path")
                    if [[ -d "$parent_dir" ]]; then
                        MONITOR_PATHS["$parent_dir"]=1
                        PATH_TYPES["$parent_dir"]="dir"
                        log "DEBUG: Will monitor parent directory: $parent_dir (for future directory $path)"
                    else
                        log "WARNING: Parent directory does not exist: $parent_dir"
                    fi
                elif [[ "$path" =~ \.[a-zA-Z0-9]+$ ]]; then
                    # Has file extension, likely a file - monitor parent directory
                    local parent_dir
                    parent_dir=$(dirname "$path")
                    if [[ -d "$parent_dir" ]]; then
                        MONITOR_PATHS["$parent_dir"]=1
                        PATH_TYPES["$parent_dir"]="dir"
                        log "DEBUG: Will monitor parent directory: $parent_dir (for future file $path)"
                    else
                        log "WARNING: Parent directory does not exist: $parent_dir"
                    fi
                else
                    # Ambiguous, assume directory - monitor parent
                    local parent_dir
                    parent_dir=$(dirname "$path")
                    if [[ -d "$parent_dir" ]]; then
                        MONITOR_PATHS["$parent_dir"]=1
                        PATH_TYPES["$parent_dir"]="dir"
                        log "DEBUG: Will monitor parent directory: $parent_dir (for future $path)"
                    else
                        log "WARNING: Parent directory does not exist: $parent_dir"
                    fi
                fi
                continue
            fi
            
            # Track whether this is a file or directory
            if [[ -f "$path" ]]; then
                MONITOR_PATHS["$path"]=1
                PATH_TYPES["$path"]="file"
                log "DEBUG: Added file to monitor: $path"
            elif [[ -d "$path" ]]; then
                MONITOR_PATHS["$path"]=1
                PATH_TYPES["$path"]="dir"
                log "DEBUG: Added directory to monitor: $path"
            fi
        done
    done
    
    if [[ ${#MONITOR_PATHS[@]} -eq 0 ]]; then
        log "ERROR: No valid paths to monitor"
        exit 1
    fi
    
    log "DEBUG: Total paths to monitor: ${#MONITOR_PATHS[@]}"
}

match_path_condition() {
    local fullpath="$1"
    local condition_path="$2"
    local event="$3"
    local ops="$4"
    
    # Check if the changed file matches the condition path
    local matches=0
    
    if [[ -d "$condition_path" ]]; then
        # Directory: check if file is within it (recursive)
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
    
    # Check if the file extension should be processed
    if ! should_process_extension "$fullpath"; then
        return 0
    fi
    
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
            
            # Remove trailing slash
            condition_path="${condition_path%/}"
            
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
    
    # Stop enrollment monitor
    if [[ -n "${ENROLLMENT_MONITOR_PID:-}" ]] && kill -0 "$ENROLLMENT_MONITOR_PID" 2>/dev/null; then
        kill "$ENROLLMENT_MONITOR_PID" 2>/dev/null || true
        wait "$ENROLLMENT_MONITOR_PID" 2>/dev/null || true
    fi
    rm -f "/var/run/file-monitor-enrollment.pid"
    
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
    
    log "DEBUG: Building monitor list..."
    build_monitor_list
    log "DEBUG: Monitor list built, found ${#MONITOR_PATHS[@]} paths"
    
    # Start the enrollment monitor
    start_enrollment_monitor
    
    # Separate files and directories
    local monitor_files=()
    local monitor_dirs=()
    
    for path in "${!MONITOR_PATHS[@]}"; do
        log "DEBUG: Processing path: $path (type: ${PATH_TYPES[$path]})"
        if [[ "${PATH_TYPES[$path]}" == "file" ]]; then
            monitor_files+=("$path")
        else
            monitor_dirs+=("$path")
        fi
    done
    
    log "DEBUG: Separated into ${#monitor_files[@]} files and ${#monitor_dirs[@]} directories"
    
    if [[ ${#monitor_files[@]} -gt 0 ]]; then
        log "Monitoring files: ${monitor_files[*]}"
    fi
    if [[ ${#monitor_dirs[@]} -gt 0 ]]; then
        log "Monitoring directories (recursive): ${monitor_dirs[*]}"
    fi
    
    if [[ ${#monitor_files[@]} -eq 0 && ${#monitor_dirs[@]} -eq 0 ]]; then
        log "ERROR: No paths to monitor after processing"
        exit 1
    fi
    
    # Build inotifywait command
    local inotify_args=()
    
    # Add files (non-recursive)
    for file in "${monitor_files[@]}"; do
        inotify_args+=("$file")
    done
    
    # Add directories (recursive)
    local recursive_flag=""
    if [[ ${#monitor_dirs[@]} -gt 0 ]]; then
        recursive_flag="-r"
    fi
    
    while true; do
        if [[ ${#monitor_files[@]} -gt 0 && ${#monitor_dirs[@]} -gt 0 ]]; then
            # Monitor both files and directories
            # Use two separate inotifywait processes and merge output
            {
                inotifywait -m -e modify,create,delete,move \
                    --format '%w|%e|%f' \
                    "${monitor_files[@]}" 2>>"$LOG_FILE" &
                local files_pid=$!
                
                inotifywait -m -r -e modify,create,delete,move \
                    --format '%w|%e|%f' \
                    "${monitor_dirs[@]}" 2>>"$LOG_FILE" &
                local dirs_pid=$!
                
                # Wait for either to exit
                wait -n
                
                # Kill both
                kill $files_pid $dirs_pid 2>/dev/null || true
                wait
            } | while IFS='|' read -r path event file; do
                execute_action "$path" "$event" "$file"
            done
        elif [[ ${#monitor_files[@]} -gt 0 ]]; then
            # Only files
            inotifywait -m -e modify,create,delete,move \
                --format '%w|%e|%f' \
                "${monitor_files[@]}" 2>>"$LOG_FILE" | \
            while IFS='|' read -r path event file; do
                execute_action "$path" "$event" "$file"
            done
        else
            # Only directories
            inotifywait -m -r -e modify,create,delete,move \
                --format '%w|%e|%f' \
                "${monitor_dirs[@]}" 2>>"$LOG_FILE" | \
            while IFS='|' read -r path event file; do
                execute_action "$path" "$event" "$file"
            done
        fi
        
        log "WARNING: inotifywait exited, restarting in 5 seconds..."
        sleep 5
    done
}

main