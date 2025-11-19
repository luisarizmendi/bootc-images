#!/bin/bash
set -euo pipefail

CONFIG_PATH="${FILE_MONITOR_CONFIG:-/usr/lib/flightctl/hooks.d}"
LOG_FILE="${FILE_MONITOR_LOG:-/var/log/file-monitor.log}"
PID_FILE="/var/run/file-monitor.pid"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
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
    if ! ls "$CONFIG_DIR"/*.yaml "$CONFIG_DIR"/*.yml 2>/dev/null | grep -q .; then
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

echo $ > "$PID_FILE"
log "Starting file monitor service"

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

execute_action() {
    local path="$1"
    local event="$2"
    local file="$3"
    
    local fullpath="${path}${file}"
    
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
        
        # Execute the run command
        local run_cmd
        run_cmd=$(echo "$rule" | yq eval '.run' -)
        
        local timeout
        timeout=$(echo "$rule" | yq eval '.timeout // "10s"' -)
        
        local workdir
        workdir=$(echo "$rule" | yq eval '.workDir // "/"' -)
        
        log "Event '$event' on '$fullpath' matches rule $rule_idx → Executing: $run_cmd"
        
        # Prepare environment variables
        export MONITOR_EVENT="$normalized_event"
        export MONITOR_FILE="$file"
        export MONITOR_FULLPATH="$fullpath"
        
        # Set Flight Control-style variables for the first condition path
        if [[ ${#condition_paths[@]} -gt 0 ]]; then
            local first_path="${condition_paths[0]}"
            export Path="$first_path"
            export Files="${all_files[$first_path]% }"
            export CreatedFiles="${created_files[$first_path]% }"
            export UpdatedFiles="${updated_files[$first_path]% }"
            export RemovedFiles="${removed_files[$first_path]% }"
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
            log "Action completed successfully"
        else
            local exit_code=$?
            if [[ $exit_code -eq 124 ]]; then
                log "ERROR: Action timed out after $timeout"
            else
                log "ERROR: Action failed with exit code $exit_code"
            fi
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
            execute_action "$path" "$event" "$file"
        done
        
        log "WARNING: inotifywait exited, restarting in 5 seconds..."
        sleep 5
    done
}

main