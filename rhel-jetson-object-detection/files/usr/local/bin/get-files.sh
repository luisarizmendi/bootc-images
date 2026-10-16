#!/usr/bin/env bash
set -euo pipefail

# get-files.sh - Download files from HTTP(S) or container images using YAML configuration.
# Usage: get-files.sh [config-file]

VERSION="1.1.0"
DEFAULT_CONFIG="/etc/get-files/config.yaml"
CONFIG_FILE="${1:-$DEFAULT_CONFIG}"
LOG_ENABLED="${LOG_ENABLED:-1}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Set by each processed entry.
ENTRY_CHANGED=0
ENTRY_STATE=""

log() {
    local level="$1"
    shift

    if [[ "$LOG_ENABLED" == "1" ]]; then
        printf '[%s] %b: %s\n' \
            "$(date +'%Y-%m-%d %H:%M:%S')" \
            "$level" \
            "$*" >&2
    fi
}

log_info() { log "${GREEN}INFO${NC}" "$@"; }
log_warn() { log "${YELLOW}WARN${NC}" "$@"; }
log_error() { log "${RED}ERROR${NC}" "$@"; }

check_requirements() {
    local missing=0
    local command

    for command in curl yq cmp mktemp; do
        if ! command -v "$command" >/dev/null 2>&1; then
            log_error "$command is not installed"
            missing=1
        fi
    done

    if ! command -v podman >/dev/null 2>&1; then
        log_warn "podman is not installed; container entries will fail"
    fi

    if [[ "$missing" -eq 1 ]]; then
        exit 1
    fi
}

validate_when_exists() {
    case "$1" in
        skip|replace|if-different)
            return 0
            ;;
        *)
            log_error "Invalid when_exists value: $1"
            log_error "Allowed values: skip, replace, if-different"
            return 1
            ;;
    esac
}

apply_metadata() {
    local destination="$1"
    local owner="$2"
    local mode="$3"
    local selinux_context="$4"

    if [[ -n "$owner" && "$owner" != "null" ]]; then
        if ! chown -- "$owner" "$destination"; then
            log_warn "Failed to set ownership to $owner: $destination"
        fi
    fi

    if [[ -n "$mode" && "$mode" != "null" ]]; then
        if ! chmod -- "$mode" "$destination"; then
            log_warn "Failed to set mode to $mode: $destination"
        fi
    fi

    if [[ -n "$selinux_context" && "$selinux_context" != "null" ]]; then
        if command -v chcon >/dev/null 2>&1; then
            if ! chcon "$selinux_context" "$destination"; then
                log_warn "Failed to set SELinux context to $selinux_context"
            fi
        else
            log_warn "chcon is not available; SELinux context was not changed"
        fi
    fi
}

set_default_http_mode() {
    local file="$1"
    local current_umask
    local default_mode

    # Match curl's usual behavior when creating a file directly.
    current_umask=$(umask)
    printf -v default_mode '%04o' "$((0666 & ~8#$current_umask))"

    chmod "$default_mode" "$file" ||
        log_warn "Failed to apply default mode $default_mode to $file"
}

install_downloaded_file() {
    local candidate="$1"
    local destination="$2"
    local owner="$3"
    local mode="$4"
    local selinux_context="$5"
    local when_exists="$6"

    ENTRY_CHANGED=0
    ENTRY_STATE=""

    if [[ ! -f "$candidate" ]]; then
        log_error "Downloaded content is not a regular file: $candidate"
        return 1
    fi

    # Avoid accidentally moving a file into an existing directory.
    if [[ -d "$destination" && ! -L "$destination" ]]; then
        log_error "Destination is a directory, but a file was expected: $destination"
        return 1
    fi

    if [[ -e "$destination" || -L "$destination" ]]; then
        case "$when_exists" in
            skip)
                rm -f -- "$candidate"
                ENTRY_STATE="skipped"
                log_info "File already exists, skipping: $destination"
                return 0
                ;;
            if-different)
                if [[ -f "$destination" ]] && cmp -s -- "$candidate" "$destination"; then
                    rm -f -- "$candidate"
                    ENTRY_STATE="unchanged"
                    log_info "Downloaded content is unchanged: $destination"
                    return 0
                fi
                ;;
            replace)
                ;;
        esac
    fi

    # candidate is created in destination's directory, so this replacement is atomic.
    if ! mv -f -- "$candidate" "$destination"; then
        log_error "Failed to install file: $destination"
        return 1
    fi

    apply_metadata "$destination" "$owner" "$mode" "$selinux_context"

    ENTRY_CHANGED=1
    ENTRY_STATE="updated"
    log_info "Installed updated file: $destination"
}

download_http() {
    local source="$1"
    local destination="$2"
    local owner="$3"
    local mode="$4"
    local selinux_context="$5"
    local when_exists="$6"
    local dest_dir
    local candidate

    # Preserve the original behavior: do not even download if policy is skip.
    if [[ "$when_exists" == "skip" ]] &&
       [[ -e "$destination" || -L "$destination" ]]; then
        ENTRY_CHANGED=0
        ENTRY_STATE="skipped"
        log_info "File already exists, skipping: $destination"
        return 0
    fi

    dest_dir=$(dirname "$destination")
    mkdir -p "$dest_dir"

    if ! candidate=$(mktemp "${dest_dir}/.get-files.XXXXXX"); then
        log_error "Unable to create temporary file in: $dest_dir"
        return 1
    fi

    log_info "Downloading from HTTP(S): $source"

    # --insecure preserves the original script's curl -k behavior.
    if ! curl --fail --show-error --location --insecure \
        --output "$candidate" -- "$source"; then
        rm -f -- "$candidate"
        log_error "Failed to download from: $source"
        return 1
    fi

    # mktemp creates mode 0600; restore curl-like defaults when no explicit mode exists.
    if [[ -z "$mode" || "$mode" == "null" ]]; then
        set_default_http_mode "$candidate"
    fi

    if ! install_downloaded_file \
        "$candidate" "$destination" "$owner" "$mode" \
        "$selinux_context" "$when_exists"; then
        rm -f -- "$candidate"
        return 1
    fi
}

download_container() {
    local source="$1"
    local file_path="$2"
    local destination="$3"
    local owner="$4"
    local mode="$5"
    local selinux_context="$6"
    local when_exists="$7"
    local dest_dir
    local candidate
    local container_name

    # Preserve the original behavior: do not access Podman if policy is skip.
    if [[ "$when_exists" == "skip" ]] &&
       [[ -e "$destination" || -L "$destination" ]]; then
        ENTRY_CHANGED=0
        ENTRY_STATE="skipped"
        log_info "File already exists, skipping: $destination"
        return 0
    fi

    if ! command -v podman >/dev/null 2>&1; then
        log_error "podman is required for container entries"
        return 1
    fi

    dest_dir=$(dirname "$destination")
    mkdir -p "$dest_dir"

    if ! candidate=$(mktemp "${dest_dir}/.get-files.XXXXXX"); then
        log_error "Unable to create temporary file in: $dest_dir"
        return 1
    fi
    rm -f -- "$candidate"

    container_name="get-files-${$}-${RANDOM}"

    log_info "Extracting from container: $source"

    if ! podman create --name "$container_name" "$source" >/dev/null; then
        rm -f -- "$candidate"
        log_error "Failed to create container from: $source"
        return 1
    fi

    if ! podman cp "${container_name}:${file_path}" "$candidate"; then
        podman rm -f "$container_name" >/dev/null 2>&1 || true
        rm -f -- "$candidate"
        log_error "Failed to copy file from container: $file_path"
        return 1
    fi

    podman rm -f "$container_name" >/dev/null 2>&1 || true

    if ! install_downloaded_file \
        "$candidate" "$destination" "$owner" "$mode" \
        "$selinux_context" "$when_exists"; then
        rm -f -- "$candidate"
        return 1
    fi
}

process_entry() {
    local type="$1"
    local source="$2"
    local destination="$3"
    local owner="${4:-}"
    local mode="${5:-}"
    local selinux_context="${6:-}"
    local container_file_path="${7:-}"
    local when_exists="${8:-skip}"

    if ! validate_when_exists "$when_exists"; then
        return 1
    fi

    case "$type" in
        http|https|HTTP|HTTPS)
            download_http "$source" "$destination" "$owner" "$mode" \
                "$selinux_context" "$when_exists"
            ;;
        container|CONTAINER)
            if [[ -z "$container_file_path" || "$container_file_path" == "null" ]]; then
                log_error "container_file_path is required for container source: $source"
                return 1
            fi

            download_container "$source" "$container_file_path" "$destination" \
                "$owner" "$mode" "$selinux_context" "$when_exists"
            ;;
        *)
            log_error "Unknown type: $type"
            return 1
            ;;
    esac
}

run_post_commands() {
    local config="$1"
    local index="$2"
    local command
    local commands_output

    if ! commands_output=$(
        yq eval -r "(.files[$index].post_commands // []) | .[]" "$config"
    ); then
        log_error "Failed to read post_commands for entry $((index + 1))"
        return 1
    fi

    while IFS= read -r command; do
        [[ -z "$command" ]] && continue

        log_info "Running post-download command: $command"

        # post_commands are trusted administrator-supplied configuration.
        if ! bash -c "$command"; then
            log_error "Post-download command failed: $command"
            return 1
        fi
    done <<< "$commands_output"
}

parse_config() {
    local config="$1"
    local file_count
    local updated_count=0
    local unchanged_count=0
    local skipped_count=0
    local fail_count=0
    local i

    if [[ ! -f "$config" ]]; then
        log_error "Configuration file not found: $config"
        return 1
    fi

    log_info "Processing configuration file: $config"

    file_count=$(yq eval -r '(.files // []) | length' "$config")

    if [[ "$file_count" == "0" ]]; then
        log_warn "No files defined in configuration"
        return 0
    fi

    for ((i = 0; i < file_count; i++)); do
        local type
        local source
        local destination
        local owner
        local mode
        local selinux_context
        local container_file_path
        local when_exists
        local legacy_force
        local post_commands_when

        type=$(yq eval -r ".files[$i].type // \"\"" "$config")
        source=$(yq eval -r ".files[$i].source // \"\"" "$config")
        destination=$(yq eval -r ".files[$i].destination // \"\"" "$config")
        owner=$(yq eval -r ".files[$i].owner // \"\"" "$config")
        mode=$(yq eval -r ".files[$i].mode // \"\"" "$config")
        selinux_context=$(yq eval -r ".files[$i].selinux_context // \"\"" "$config")
        container_file_path=$(yq eval -r ".files[$i].container_file_path // \"\"" "$config")
        when_exists=$(yq eval -r ".files[$i].when_exists // \"\"" "$config")
        legacy_force=$(yq eval -r ".files[$i].force // false" "$config")
        post_commands_when=$(yq eval -r ".files[$i].post_commands_when // \"changed\"" "$config")

        if [[ -z "$type" || -z "$source" || -z "$destination" ]]; then
            log_error "Entry $((i + 1)) requires type, source, and destination"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Compatibility with the original configuration format.
        if [[ -z "$when_exists" ]]; then
            if [[ "$legacy_force" == "true" ]]; then
                when_exists="replace"
            else
                when_exists="skip"
            fi
        fi

        case "$post_commands_when" in
            changed|always)
                ;;
            *)
                log_error "Invalid post_commands_when value '$post_commands_when' in entry $((i + 1))"
                fail_count=$((fail_count + 1))
                continue
                ;;
        esac

        log_info "Processing entry $((i + 1))/$file_count: $type -> $destination"

        if ! process_entry \
            "$type" "$source" "$destination" "$owner" "$mode" \
            "$selinux_context" "$container_file_path" "$when_exists"; then
            fail_count=$((fail_count + 1))
            continue
        fi

        if [[ "$ENTRY_CHANGED" == "1" || "$post_commands_when" == "always" ]]; then
            if ! run_post_commands "$config" "$i"; then
                fail_count=$((fail_count + 1))
                continue
            fi
        fi

        case "$ENTRY_STATE" in
            updated)
                updated_count=$((updated_count + 1))
                ;;
            unchanged)
                unchanged_count=$((unchanged_count + 1))
                ;;
            skipped)
                skipped_count=$((skipped_count + 1))
                ;;
        esac
    done

    log_info "Processing complete: $updated_count updated, $unchanged_count unchanged, $skipped_count skipped, $fail_count failed"

    [[ "$fail_count" -eq 0 ]]
}

main() {
    log_info "get-files.sh version $VERSION"
    check_requirements
    parse_config "$CONFIG_FILE"
}

main "$@"
