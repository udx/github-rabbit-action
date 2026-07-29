#!/usr/bin/env bash
# Configuration management - all global configuration in one place

# Guard against multiple sourcing
if [[ "${CONFIG_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
BUNDLED_LIFECYCLE_POLICY_FILE="$PROJECT_ROOT/src/configs/lifecycle-policy.yaml"

# A caller may provide a policy relative to the checked-out repository. The
# same resolved file is used by lifecycle resolution and config merging.
if [[ -z "${LIFECYCLE_POLICY_FILE:-}" ]]; then
    if [[ -n "${INPUT_LIFECYCLE_POLICY_PATH:-}" ]]; then
        if [[ "$INPUT_LIFECYCLE_POLICY_PATH" == /* ]]; then
            LIFECYCLE_POLICY_FILE="$INPUT_LIFECYCLE_POLICY_PATH"
        else
            LIFECYCLE_POLICY_FILE="${GITHUB_WORKSPACE:-$PWD}/$INPUT_LIFECYCLE_POLICY_PATH"
        fi
    else
        LIFECYCLE_POLICY_FILE="$BUNDLED_LIFECYCLE_POLICY_FILE"
    fi
fi
export LIFECYCLE_POLICY_FILE

_yaml_get_or_default() {
    local query="$1"
    local fallback="$2"

    if command -v yq >/dev/null 2>&1 && [[ -f "$LIFECYCLE_POLICY_FILE" ]]; then
        local value
        value=$(yq eval "$query // \"\"" "$LIFECYCLE_POLICY_FILE" 2>/dev/null || true)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    echo "$fallback"
}

_yaml_csv_or_default() {
    local query="$1"
    local fallback="$2"

    if command -v yq >/dev/null 2>&1 && [[ -f "$LIFECYCLE_POLICY_FILE" ]]; then
        local value
        value=$(yq eval "$query // [] | join(\",\")" "$LIFECYCLE_POLICY_FILE" 2>/dev/null || true)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    fi

    echo "$fallback"
}

# ============================================================================
# GLOBAL CONFIGURATION
# ============================================================================

# File naming conventions (can be overridden via GitHub Action inputs)
export MERGED_FILE_PREFIX="${INPUT_MERGED_FILE_PREFIX:-merged-}"
export CONFIG_FILE_EXTENSIONS="${INPUT_CONFIG_FILE_EXTENSIONS:-yml,yaml}"
export NO_ENVIRONMENT_VALUE="${INPUT_NO_ENVIRONMENT_VALUE:-none}"

# Discovery configuration (can be overridden via GitHub Action inputs)
export SKIP_DIRECTORIES="${INPUT_SKIP_DIRECTORIES:-node_modules,vendor}"

# Rabbit config layout (can be overridden via GitHub Action inputs)
DEFAULT_LIFECYCLE_PRODUCTION="production"
DEFAULT_LIFECYCLE_STAGING="staging"
DEFAULT_LIFECYCLE_DEVELOPMENT="development"
DEFAULT_SUBDIRECTORY_LIFECYCLES="$(_yaml_csv_or_default '.config.lifecycles | to_entries | map(select(.value.allow_subdirs == true) | .key)' 'production,development')"
DEFAULT_STABLE_LIFECYCLES="$(_yaml_csv_or_default '.config.lifecycles | to_entries | map(select(.value.allow_subdirs != true) | .key)' 'staging')"
DEFAULT_ALL_LIFECYCLES="production,staging,development"
DEFAULT_PROTECTED_BRANCH_LIFECYCLE="$(_yaml_get_or_default '.config.lifecycles | to_entries | map(select(.value.protected_only == true) | .key) | .[0]' "$DEFAULT_LIFECYCLE_PRODUCTION")"
DEFAULT_FALLBACK_LIFECYCLE="$(_yaml_get_or_default '.config.lifecycles | to_entries | map(select(.value.is_fallback == true) | .key) | .[0]' "$DEFAULT_LIFECYCLE_DEVELOPMENT")"
DEFAULT_SUBDIR_PREFERRED_LIFECYCLE="${DEFAULT_FALLBACK_LIFECYCLE}"

export LIFECYCLE_PRODUCTION="${INPUT_LIFECYCLE_PRODUCTION:-$DEFAULT_LIFECYCLE_PRODUCTION}"
export LIFECYCLE_STAGING="${INPUT_LIFECYCLE_STAGING:-$DEFAULT_LIFECYCLE_STAGING}"
export LIFECYCLE_DEVELOPMENT="${INPUT_LIFECYCLE_DEVELOPMENT:-$DEFAULT_LIFECYCLE_DEVELOPMENT}"

# Lifecycles that support subdirectories with smart merge
# Production and Development support subdirs, Staging does not
export SUBDIRECTORY_LIFECYCLES="${INPUT_SUBDIRECTORY_LIFECYCLES:-$DEFAULT_SUBDIRECTORY_LIFECYCLES}"

# Build lifecycle groups (exported as comma-separated strings for modules)
export STABLE_LIFECYCLES_STR="${INPUT_STABLE_LIFECYCLES:-$DEFAULT_STABLE_LIFECYCLES}"
export ALL_LIFECYCLES_STR="${INPUT_ALL_LIFECYCLES:-$DEFAULT_ALL_LIFECYCLES}"
export SUBDIR_PREFERRED_LIFECYCLE="${INPUT_SUBDIR_PREFERRED_LIFECYCLE:-$DEFAULT_SUBDIR_PREFERRED_LIFECYCLE}"
export PROTECTED_BRANCH_LIFECYCLE="${INPUT_PROTECTED_BRANCH_LIFECYCLE:-$DEFAULT_PROTECTED_BRANCH_LIFECYCLE}"
export FALLBACK_LIFECYCLE="${INPUT_FALLBACK_LIFECYCLE:-$DEFAULT_FALLBACK_LIFECYCLE}"

# Exported lifecycle metadata. The composite action resolves these in-repo;
# local script runs retain the compatibility fallback when no value is supplied.
export LIFECYCLE="${INPUT_LIFECYCLE:-}"
export IS_PROTECTED="${INPUT_IS_PROTECTED:-}"
export RESOLUTION_REASON="${INPUT_RESOLUTION_REASON:-}"

# ============================================================================
# INPUT PARAMETERS
# ============================================================================

# User-facing parameters with defaults
export SOURCE_DIR="${INPUT_SOURCE_DIR:-.rabbit}"
export ENV_NAME="${INPUT_ENV_NAME:-}"
export EXCLUDE="${INPUT_EXCLUDE:-**/merged*.yml,**/merged*.yaml}"
export RECURSIVE="${INPUT_RECURSIVE:-true}"
export FILE_PATTERNS="${INPUT_FILE_PATTERNS:-*.yml,*.yaml}"
export OUTPUT_FORMAT="${INPUT_OUTPUT_FORMAT:-yaml}"
export DEBUG="${INPUT_DEBUG:-false}"
export ENABLE_ANNOTATIONS="${ENABLE_ANNOTATIONS:-false}"
export GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

readonly CONFIG_LIB_LOADED="true"
