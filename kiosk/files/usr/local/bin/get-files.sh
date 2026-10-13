#!/bin/bash
set -euo pipefail

# get-files.sh - Download files from multiple sources based on configuration
# Usage: get-files.sh [config-file]
#
# The YAML parsing is done with awk (no yq needed). It supports the flat
# structure below: a top-level "files:" list whose items have simple
# "key: value" pairs (quoted or unquoted, with optional trailing comments).
#
#   files:
#     - type: http
#       source: https://example.com/file.bin
#       destination: /var/lib/foo/file.bin
#       owner: root:root
#       mode: "0644"
#       selinux_context: system_u:object_r:var_lib_t:s0
#       force: true
#     - type: container
#       source: quay.io/example/image:latest
#       container_file_path: /opt/model.onnx
#       destination: /var/lib/foo/model.onnx

VERSION="1.1.0"
DEFAULT_CONFIG="/etc/get-files/config.yaml"
CONFIG_FILE="${1:-$DEFAULT_CONFIG}"
LOG_ENABLED="${LOG_ENABLED:-1}"

# Field separator used between parsed fields (ASCII Unit Separator).
# It is a non-whitespace IFS character, so empty fields are preserved by `read`.
FS_CHAR=$'\037'

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    if [[ "$LOG_ENABLED" == "1" ]]; then
        echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${level}: $*" >&2
    fi
}

log_info() { log "${GREEN}INFO${NC}" "$@"; }
log_warn() { log "${YELLOW}WARN${NC}" "$@"; }
log_error() { log "${RED}ERROR${NC}" "$@"; }

# Check if required commands are available
check_requirements() {
    local missing=0

    if ! command -v curl &> /dev/null; then
        log_error "curl is not installed"
        missing=1
    fi

    if ! command -v awk &> /dev/null; then
        log_error "awk is not installed (required for YAML parsing)"
        missing=1
    fi

    if ! command -v podman &> /dev/null; then
        log_warn "podman is not installed (required for container registry downloads)"
    fi

    if [[ $missing -eq 1 ]]; then
        exit 1
    fi
}

# Minimal YAML reader for the "files:" list.
# Prints one line per entry with fields separated by $FS_CHAR, in this order:
#   type, source, destination, owner, mode, selinux_context, container_file_path, force
read -r -d '' AWK_PARSER <<'AWK_EOF' || true
function trim(s) {
    sub(/^[ \t]+/, "", s)
    sub(/[ \t]+$/, "", s)
    return s
}

function unquote(v) {
    v = trim(v)
    if (v ~ /^"/) {            # double-quoted: take text up to the next quote
        sub(/^"/, "", v)
        sub(/".*$/, "", v)
        return v
    }
    if (v ~ /^'/) {            # single-quoted
        sub(/^'/, "", v)
        sub(/'.*$/, "", v)
        return v
    }
    sub(/[ \t]+#.*$/, "", v)   # strip trailing comment on unquoted values
    v = trim(v)
    if (v == "null" || v == "~") v = ""
    return v
}

function flush(   i, out) {
    if (!started) return
    out = ""
    for (i = 1; i <= nkeys; i++) {
        out = out (i > 1 ? FSC : "") data[order[i]]
    }
    print out
    split("", data)
    started = 0
}

BEGIN {
    nkeys = split("type source destination owner mode selinux_context container_file_path force", order, " ")
    in_files = 0
    started = 0
}

{
    sub(/\r$/, "")
    line = $0

    if (line ~ /^[ \t]*(#.*)?$/) next          # blank / comment
    if (line ~ /^(---|\.\.\.)[ \t]*$/) next    # document markers

    if (line ~ /^files:[ \t]*(#.*)?$/) {       # start of the list
        in_files = 1
        next
    }
    if (line ~ /^[^ \t-]/) {                   # another top-level key
        flush()
        in_files = 0
        next
    }
    if (!in_files) next

    if (line ~ /^[ \t]*-([ \t]|$)/) {          # new list item
        flush()
        sub(/^[ \t]*-[ \t]*/, "", line)
        started = 1
    }
    if (!started) next

    if (match(line, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*:/)) {
        key = substr(line, 1, RLENGTH - 1)
        val = substr(line, RLENGTH + 1)
        key = trim(key)
        data[key] = unquote(val)
    }
}

END { flush() }
AWK_EOF

parse_yaml_files() {
    awk -v FSC="$FS_CHAR" "$AWK_PARSER" "$1"
}

# Download file via HTTP/HTTPS
download_http() {
    local source="$1"
    local destination="$2"
    local owner="$3"
    local mode="$4"
    local selinux_context="$5"
    local force="$6"

    # Check if file exists and skip if not forcing
    if [[ -e "$destination" ]] && [[ "$force" != "true" ]]; then
        log_info "File already exists, skipping: $destination"
        return 0
    fi

    log_info "Downloading from HTTP(S): $source"

    # Create destination directory if it doesn't exist
    local dest_dir=$(dirname "$destination")
    mkdir -p "$dest_dir"

    # Download with curl
    if curl -Lk -o "$destination" "$source"; then
        log_info "Successfully downloaded to: $destination"

        # Set ownership if specified
        if [[ -n "$owner" && "$owner" != "null" ]]; then
            chown "$owner" "$destination" || log_warn "Failed to set ownership to $owner"
        fi

        # Set permissions if specified
        if [[ -n "$mode" && "$mode" != "null" ]]; then
            chmod "$mode" "$destination" || log_warn "Failed to set permissions to $mode"
        fi

        # Set SELinux context if specified and available
        if [[ -n "$selinux_context" && "$selinux_context" != "null" ]] && command -v chcon &> /dev/null; then
            if chcon "$selinux_context" "$destination"; then
                log_info "Set SELinux context to $selinux_context"
                # Use restorecon to make the context persistent
                if command -v restorecon &> /dev/null; then
                    restorecon -v "$destination" || log_warn "restorecon failed, context may not persist"
                fi
            else
                log_warn "Failed to set SELinux context to $selinux_context"
            fi
        fi

        return 0
    else
        log_error "Failed to download from: $source"
        return 1
    fi
}

# Download file from container registry
download_container() {
    local source="$1"
    local file_path="$2"
    local destination="$3"
    local owner="$4"
    local mode="$5"
    local selinux_context="$6"
    local force="$7"

    # Check if file exists and skip if not forcing
    if [[ -e "$destination" ]] && [[ "$force" != "true" ]]; then
        log_info "File already exists, skipping: $destination"
        return 0
    fi

    log_info "Extracting from container: $source"

    # Create temporary directory
    local temp_dir=$(mktemp -d)
    local container_name="temp-get-files-$$-$RANDOM"

    # Cleanup function
    cleanup_container() {
        log_info "Cleaning up temporary container resources"
        podman rm -f "$container_name" 2>/dev/null || true
        podman rmi -f "$source" 2>/dev/null || true
        rm -rf "$temp_dir"
    }

    trap cleanup_container EXIT

    # Create container
    if ! podman create --name "$container_name" "$source" &>/dev/null; then
        log_error "Failed to create container from: $source"
        return 1
    fi

    # Copy files from container
    if ! podman cp "${container_name}:${file_path}" "$temp_dir/" &>/dev/null; then
        log_error "Failed to copy file from container: $file_path"
        return 1
    fi

    # Extract the actual file from temp directory
    local extracted_file="${temp_dir}${file_path}"

    if [[ ! -f "$extracted_file" ]] && [[ ! -d "$extracted_file" ]]; then
        log_error "File not found in container: $file_path"
        return 1
    fi

    # Create destination directory if it doesn't exist
    local dest_dir=$(dirname "$destination")
    mkdir -p "$dest_dir"

    # Move file to destination
    if cp -r "$extracted_file" "$destination"; then
        log_info "Successfully extracted to: $destination"

        # Set ownership if specified
        if [[ -n "$owner" && "$owner" != "null" ]]; then
            chown -R "$owner" "$destination" || log_warn "Failed to set ownership to $owner"
        fi

        # Set permissions if specified
        if [[ -n "$mode" && "$mode" != "null" ]]; then
            chmod "$mode" "$destination" || log_warn "Failed to set permissions to $mode"
        fi

        # Set SELinux context if specified and available
        if [[ -n "$selinux_context" && "$selinux_context" != "null" ]] && command -v chcon &> /dev/null; then
            if chcon -R "$selinux_context" "$destination"; then
                log_info "Set SELinux context to $selinux_context"
                # Use restorecon to make the context persistent
                if command -v restorecon &> /dev/null; then
                    restorecon -Rv "$destination" || log_warn "restorecon failed, context may not persist"
                fi
            else
                log_warn "Failed to set SELinux context to $selinux_context"
            fi
        fi

        cleanup_container
        trap - EXIT
        return 0
    else
        log_error "Failed to copy file to destination: $destination"
        return 1
    fi
}

# Process a single configuration entry
process_entry() {
    local type="$1"
    local source="$2"
    local destination="$3"
    local owner="${4:-}"
    local mode="${5:-}"
    local selinux_context="${6:-}"
    local container_file_path="${7:-}"
    local force="${8:-false}"

    case "$type" in
        http|https|HTTP|HTTPS)
            download_http "$source" "$destination" "$owner" "$mode" "$selinux_context" "$force"
            ;;
        container|CONTAINER)
            if [[ -z "$container_file_path" || "$container_file_path" == "null" ]]; then
                log_error "Container file path not specified for: $source"
                return 1
            fi
            download_container "$source" "$container_file_path" "$destination" "$owner" "$mode" "$selinux_context" "$force"
            ;;
        *)
            log_error "Unknown type: $type"
            return 1
            ;;
    esac
}

# Parse and process YAML configuration file
parse_config() {
    local config="$1"

    if [[ ! -f "$config" ]]; then
        log_error "Configuration file not found: $config"
        exit 0
    fi

    log_info "Processing configuration file: $config"

    # Load all entries (one per line, fields separated by $FS_CHAR)
    local -a entries=()
    mapfile -t entries < <(parse_yaml_files "$config")

    local file_count=${#entries[@]}

    if [[ "$file_count" -eq 0 ]]; then
        log_warn "No files defined in configuration"
        return 0
    fi

    local success_count=0
    local fail_count=0
    local skipped_count=0

    # Process each file entry
    local i
    for ((i=0; i<file_count; i++)); do
        local type source destination owner mode selinux_context container_file_path force
        IFS="$FS_CHAR" read -r type source destination owner mode selinux_context container_file_path force <<< "${entries[$i]}"
        force="${force:-false}"

        log_info "Processing entry $((i+1))/$file_count: $type -> $destination"

        # Check if file exists before processing
        if [[ -e "$destination" ]] && [[ "$force" != "true" ]]; then
            log_info "File already exists, skipping: $destination"
            skipped_count=$((skipped_count + 1))
            continue
        fi

        if process_entry "$type" "$source" "$destination" "$owner" "$mode" "$selinux_context" "$container_file_path" "$force"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    log_info "Processing complete: $success_count succeeded, $fail_count failed, $skipped_count skipped"

    if [[ $fail_count -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Main execution
main() {
    log_info "get-files.sh version $VERSION"

    check_requirements
    parse_config "$CONFIG_FILE"
}

main "$@"