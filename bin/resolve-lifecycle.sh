#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/validation.sh"
source "$SCRIPT_DIR/lib/discovery.sh"
source "$SCRIPT_DIR/lib/github.sh"
source "$SCRIPT_DIR/lib/lifecycle.sh"

write_output() {
    local key="$1"
    local value="$2"
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
}

collect_dirs() {
    local source_dir="$1"
    local -n dirs_ref=$2
    dirs_ref=()

    if [[ ! -d "$source_dir" ]]; then
        dbg "Source directory '$source_dir' does not exist; resolving without directory hints"
        return 0
    fi

    while IFS= read -r dir; do
        dirs_ref+=("$dir")
    done < <(find "$source_dir" -type d -mindepth 1 2>/dev/null | sort)
}

main() {
    if [[ -z "$ENV_NAME" ]]; then
        err "Environment name is required. Pass environment or run inside a GitHub event with a resolvable ref."
        exit 1
    fi

    if ! validation_check_policy; then
        exit 1
    fi

    local directories=()
    collect_dirs "$SOURCE_DIR" directories

    local is_protected="false"
    if github_check_branch_protection "$ENV_NAME"; then
        is_protected="true"
    fi

    local resolution lifecycle reason
    resolution="$(lifecycle_resolve "$ENV_NAME" "$is_protected" "${directories[@]}")"
    lifecycle="${resolution%%|*}"
    reason="${resolution#*|}"

    log "Resolved environment '$ENV_NAME' to lifecycle '$lifecycle' ($reason)"
    write_output "environment" "$ENV_NAME"
    write_output "lifecycle" "$lifecycle"
    write_output "is_protected" "$is_protected"
    write_output "resolution_reason" "$reason"
    write_output "lifecycle_policy_path" "$LIFECYCLE_POLICY_FILE"
}

main "$@"
