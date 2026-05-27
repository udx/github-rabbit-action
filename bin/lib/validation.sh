#!/usr/bin/env bash
# Input validation utilities

# Guard against multiple sourcing
if [[ "${VALIDATION_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi

# Source dependencies
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/logging.sh"

# Valid output formats
readonly VALID_FORMATS=("yaml" "json")

# PRIVATE: Check if value is in array
_is_valid_format() {
    local format="$1"
    for valid in "${VALID_FORMATS[@]}"; do
        [[ "$format" == "$valid" ]] && return 0
    done
    return 1
}

_policy_eval() {
    local query="$1"
    yq eval "$query" "$LIFECYCLE_POLICY_FILE" 2>/dev/null
}

_require_equal() {
    local actual="$1"
    local expected="$2"
    local message="$3"

    if [[ "$actual" != "$expected" ]]; then
        err "$message"
        return 1
    fi

    return 0
}

_require_true() {
    local actual="$1"
    local message="$2"

    if [[ "$actual" != "true" ]]; then
        err "$message"
        return 1
    fi

    return 0
}

_require_non_empty() {
    local actual="$1"
    local message="$2"

    if [[ -z "$actual" || "$actual" == "null" ]]; then
        err "$message"
        return 1
    fi

    return 0
}

_validation_check_policy() {
    if [[ ! -f "$LIFECYCLE_POLICY_FILE" ]]; then
        err "Rabbit config layout file not found: $LIFECYCLE_POLICY_FILE"
        return 1
    fi

    if ! command -v yq >/dev/null 2>&1; then
        err "yq is required to validate lifecycle policy"
        return 1
    fi

    local kind version lifecycle_keys
    mapfile -t policy_meta < <(_policy_eval '
      .kind,
      .version,
      (.config.lifecycles | keys | join(","))
    ')

    kind="${policy_meta[0]:-}"
    version="${policy_meta[1]:-}"
    lifecycle_keys="${policy_meta[2]:-}"

    if ! _require_equal "$kind" "rabbitConfigLayout" "Rabbit config layout kind must be 'rabbitConfigLayout', got '$kind'"; then
        return 1
    fi

    if ! _require_non_empty "$version" "Rabbit config layout must define a version"; then
        return 1
    fi

    if ! _require_equal "$lifecycle_keys" "production,staging,development" "Supported lifecycle set is production, staging, development; got '$lifecycle_keys'"; then
        return 1
    fi

    local development_allows_subdirs
    development_allows_subdirs=$(_policy_eval '.config.lifecycles.development.allow_subdirs == true')
    if ! _require_true "$development_allows_subdirs" "Development config layout must allow subdirectories"; then
        return 1
    fi

    local staging_allows_subdirs
    staging_allows_subdirs=$(_policy_eval '.config.lifecycles.staging.allow_subdirs == true')
    if [[ "$staging_allows_subdirs" == "true" ]]; then
        err "Staging is a reserved root-only lifecycle and cannot allow subdirectories"
        return 1
    fi

    return 0
}

validation_check_policy() {
    _validation_check_policy
}

# PUBLIC: Validation function
validation_check_inputs() {
    # Validate output format
    if ! _is_valid_format "$OUTPUT_FORMAT"; then
        err "Output format must be one of: ${VALID_FORMATS[*]}, got '$OUTPUT_FORMAT'"
        return 1
    fi
    
    # Validate source directory exists
    if [[ ! -d "$SOURCE_DIR" ]]; then
        err "Source directory '$SOURCE_DIR' does not exist"
        return 1
    fi

    if ! validation_check_policy; then
        return 1
    fi
    
    return 0
}

readonly VALIDATION_LIB_LOADED="true"
