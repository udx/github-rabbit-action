#!/usr/bin/env bash
# Configuration management - all global configuration in one place

# Guard against multiple sourcing
if [[ "${CONFIG_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
LIFECYCLE_POLICY_FILE="${LIFECYCLE_POLICY_FILE:-$PROJECT_ROOT/src/configs/lifecycle-policy.yaml}"

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
DEFAULT_FALLBACK_LIFECYCLE="$DEFAULT_LIFECYCLE_DEVELOPMENT"
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
export FALLBACK_LIFECYCLE="${INPUT_FALLBACK_LIFECYCLE:-$DEFAULT_FALLBACK_LIFECYCLE}"

# Exported lifecycle metadata. INPUT_LIFECYCLE is supplied by udx/rabbit-lifecycle
# in the composite action path; local script runs can still resolve internally.
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
export GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

readonly CONFIG_LIB_LOADED="true"
