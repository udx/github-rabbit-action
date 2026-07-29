#!/usr/bin/env bash
# Lifecycle detection utilities

# Guard against multiple sourcing
if [[ "${LIFECYCLE_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi

# Source dependencies
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/logging.sh"
source "$LIB_DIR/discovery.sh"

# Note: Configuration is set in index.sh and passed via environment variables:
# - LIFECYCLE_PRODUCTION, LIFECYCLE_STAGING, LIFECYCLE_DEVELOPMENT
# - STABLE_LIFECYCLES_STR, ALL_LIFECYCLES_STR (comma-separated)
# - SUBDIRECTORY_LIFECYCLES (comma-separated)
# - SUBDIR_PREFERRED_LIFECYCLE
# - FALLBACK_LIFECYCLE
#
# Lifecycle Rules (applied throughout the codebase):
# - Only configured subdirectory lifecycles support lifecycle/<env>/ smart merge
# - The composite action resolves lifecycle metadata before config merging
# - Local direct script runs retain a simple fallback without GitHub metadata

# Build lifecycle arrays from environment variables
IFS=',' read -ra STABLE_LIFECYCLES <<< "${STABLE_LIFECYCLES_STR}"
IFS=',' read -ra ALL_LIFECYCLES <<< "${ALL_LIFECYCLES_STR}"

# PRIVATE: Check if lifecycle is stable (production or staging)
_is_stable_lifecycle() {
    local lifecycle="$1"
    for stable in "${STABLE_LIFECYCLES[@]}"; do
        [[ "$lifecycle" == "$stable" ]] && return 0
    done
    return 1
}

# PRIVATE: Check if lifecycle allows subdirectories
_lifecycle_allows_subdirectories() {
    local lifecycle="$1"
    IFS=',' read -ra subdirectory_lifecycles <<< "${SUBDIRECTORY_LIFECYCLES}"
    for subdir_lifecycle in "${subdirectory_lifecycles[@]}"; do
        subdir_lifecycle="${subdir_lifecycle// /}" # Remove spaces
        [[ "$lifecycle" == "$subdir_lifecycle" ]] && return 0
    done
    return 1
}

# PRIVATE: Find directory for a specific lifecycle
# Returns: directory path or empty string
# Lookup order:
# 1. For subdirectory-enabled lifecycles: lifecycle/{env_name}/ → lifecycle/
# 2. For other lifecycles: lifecycle/ only
_find_directory_for_lifecycle() {
    local lifecycle="$1"
    local env_name="$2"
    shift 2
    local unique_dirs=("$@")
    local dir=""
    
    # Try lifecycle-specific subdirectory first (development/env or production/env)
    if _lifecycle_allows_subdirectories "$lifecycle"; then
        if dir=$(discovery_find_dir_matching "*/$lifecycle/$env_name" "${unique_dirs[@]}"); then
            dbg "Found $lifecycle subdirectory: $dir" >&2
            echo "$dir|$lifecycle"
            return 0
        fi
    fi
    
    # Try lifecycle root directory (production/, staging/, development/)
    if dir=$(discovery_find_dir_matching "*/$lifecycle" "${unique_dirs[@]}"); then
        dbg "Found $lifecycle directory: $dir" >&2
        echo "$dir|$lifecycle"
        return 0
    fi
    
    echo "|"
    return 1
}

# PRIVATE: Find best directory for environment
# Returns: directory|lifecycle or empty string
# Lookup order:
# 1. Determine lifecycle (production/staging/development)
# 2. Look for lifecycle-specific configs
# 3. Return lifecycle root as default if no specific configs found
_find_env_directory() {
    local env_name="$1"
    shift
    local unique_dirs=("$@")
    
    local lifecycle=$(_determine_lifecycle_for_env "$env_name" "${unique_dirs[@]}")
    dbg "Lifecycle for '$env_name': $lifecycle" >&2
    
    # Find directory for determined lifecycle
    local result=$(_find_directory_for_lifecycle "$lifecycle" "$env_name" "${unique_dirs[@]}")
    
    echo "$result"
}

# PRIVATE: Minimal fallback for direct script usage when no lifecycle metadata
# is supplied. The composite action resolves lifecycle before config merging.
_determine_lifecycle_for_env() {
    local env_name="$1"
    shift
    local unique_dirs=("$@")
    
    # Explicit lifecycle names
    for lifecycle in "${ALL_LIFECYCLES[@]}"; do
        if [[ "$env_name" == "$lifecycle" ]]; then
            dbg "Explicit lifecycle name: $lifecycle" >&2
            echo "$lifecycle"
            return
        fi
    done
    
    # Check if preferred lifecycle subdirectory exists
    local preferred_subdir=""
    if preferred_subdir=$(discovery_find_dir_matching "*/$SUBDIR_PREFERRED_LIFECYCLE/$env_name" "${unique_dirs[@]}"); then
        dbg "Found $SUBDIR_PREFERRED_LIFECYCLE subdirectory for '$env_name' → $SUBDIR_PREFERRED_LIFECYCLE lifecycle" >&2
        echo "$SUBDIR_PREFERRED_LIFECYCLE"
        return
    fi

    dbg "No pre-resolved lifecycle for '$env_name'; using local fallback lifecycle '$FALLBACK_LIFECYCLE'" >&2
    echo "$FALLBACK_LIFECYCLE"
}

# PUBLIC: Resolve a lifecycle and preserve the rule that selected it.
# Usage: lifecycle_resolve "environment" "is_protected" "directories..."
lifecycle_resolve() {
    local env_name="$1"
    local is_protected="$2"
    shift 2
    local unique_dirs=("$@")
    local lifecycle

    for lifecycle in "${ALL_LIFECYCLES[@]}"; do
        if [[ "$env_name" == "$lifecycle" ]]; then
            echo "$lifecycle|explicit_lifecycle"
            return 0
        fi
    done

    if _lifecycle_allows_subdirectories "$SUBDIR_PREFERRED_LIFECYCLE" && \
       discovery_find_dir_matching "*/$SUBDIR_PREFERRED_LIFECYCLE/$env_name" "${unique_dirs[@]}" >/dev/null; then
        echo "$SUBDIR_PREFERRED_LIFECYCLE|environment_subdirectory"
        return 0
    fi

    if [[ "$is_protected" == "true" ]]; then
        echo "$PROTECTED_BRANCH_LIFECYCLE|protected_branch"
        return 0
    fi

    echo "$FALLBACK_LIFECYCLE|fallback"
}

# PUBLIC: Get lifecycle and directory info for environment
# Returns: lifecycle|directory|is_protected (pipe-separated)
# Usage: result=$(lifecycle_get_info "$env_name" "unique_dirs_array")
#        lifecycle=$(echo "$result" | cut -d'|' -f1)
#        directory=$(echo "$result" | cut -d'|' -f2)
#        is_protected=$(echo "$result" | cut -d'|' -f3)
lifecycle_get_info() {
    local env_name="$1"
    shift
    local unique_dirs=("$@")
    
    local lifecycle="${LIFECYCLE:-}"
    local is_protected="${IS_PROTECTED:-false}"
    local result

    if [[ -n "$lifecycle" ]]; then
        dbg "Using pre-resolved lifecycle for '$env_name': $lifecycle" >&2
        result=$(_find_directory_for_lifecycle "$lifecycle" "$env_name" "${unique_dirs[@]}")
    else
        lifecycle=$(_determine_lifecycle_for_env "$env_name" "${unique_dirs[@]}")
        dbg "Determined lifecycle for '$env_name': $lifecycle" >&2

        # Find directory for this environment
        result=$(_find_env_directory "$env_name" "${unique_dirs[@]}")
    fi

    local best_dir=$(echo "$result" | cut -d'|' -f1)
    local actual_lifecycle=$(echo "$result" | cut -d'|' -f2)

    if [[ -z "$actual_lifecycle" ]]; then
        actual_lifecycle="$lifecycle"
    fi

    echo "$actual_lifecycle|$best_dir|$is_protected"
}

# PUBLIC: Detect all environments from source directory
# Returns: array of environment names via reference
# LIFECYCLE RULES APPLIED:
# - Production/Staging: Only root directories, subdirectories IGNORED
# - Development: Root + subdirectories allowed
lifecycle_detect_environments() {
    local source_dir="$1"
    local -n envs_ref=$2
    envs_ref=()
    
    local found_lifecycles=()
    
    # Find all directories with YAML files
    while IFS= read -r dir; do
        local relative_dir="${dir#$source_dir/}"
        local lifecycle_root="${relative_dir%%/*}"
        local dir_name=$(basename "$dir")
        local parent_name=$(basename "$(dirname "$dir")")

        if [[ ",$ALL_LIFECYCLES_STR," != *",$lifecycle_root,"* ]]; then
            dbg "Ignoring directory outside configured lifecycle roots: $dir" >&2
            continue
        fi
        
        # Skip hidden/common directories
        if discovery_should_skip_directory "$dir_name"; then
            continue
        fi
        
        # Only process directories with YAML files
        if ! discovery_has_yaml_files "$dir"; then
            continue
        fi
        
        # Standard lifecycle directories (production, staging, development)
        if [[ " ${ALL_LIFECYCLES[@]} " =~ " ${dir_name} " ]]; then
            # Add once
            if [[ ! " ${found_lifecycles[@]} " =~ " ${dir_name} " ]]; then
                envs_ref+=("$dir_name")
                found_lifecycles+=("$dir_name")
                dbg "Detected $dir_name at: $dir" >&2
            fi
        # Subdirectory-enabled lifecycle subdirectories (LIFECYCLE RULE)
        elif _lifecycle_allows_subdirectories "$parent_name"; then
            envs_ref+=("$dir_name")
            dbg "Detected $parent_name subdirectory: $dir_name at $dir" >&2
        # Production/Staging subdirectories (LIFECYCLE RULE: ignored)
        elif _is_stable_lifecycle "$parent_name"; then
            dbg "Ignoring subdirectory under $parent_name: $dir_name (lifecycle rule)" >&2
        fi
    done < <(find "$source_dir" -type d -mindepth 1 2>/dev/null | sort)
}

readonly LIFECYCLE_LIB_LOADED="true"
