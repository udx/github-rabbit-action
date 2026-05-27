#!/usr/bin/env bash
# Environment detection and filtering utilities

# Guard against multiple sourcing
if [[ "${ENVIRONMENT_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi

# Source dependencies
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/logging.sh"
source "$LIB_DIR/lifecycle.sh"

# PRIVATE: Check if file is a direct child of directory (not in subdirectory)
_is_direct_file() {
    local file="$1"
    local dir="$2"
    local file_dir=$(dirname "$file")
    [[ "$file_dir" == "$dir" ]]
}

# PRIVATE: Check if file belongs to environment (used in auto-detect mode)
_file_belongs_to_env() {
    local file="$1"
    local env="$2"
    local file_dir=$(dirname "$file")
    [[ "$file" == *"/$env/"* ]] || [[ "$file_dir" == *"/$env" ]]
}

# PRIVATE: Check if file should be included based on lifecycle rules
_should_include_file() {
    local file="$1"
    local best_dir="$2"
    local env_type="$3"
    local is_lifecycle_root="$4"
    
    # File must be in the selected directory
    [[ "$file" != "$best_dir"* ]] && return 1
    
    # Lifecycle roots and root-only lifecycles use direct files only.
    if [[ "$is_lifecycle_root" == "true" ]] || ! _lifecycle_allows_subdirectories "$env_type"; then
        _is_direct_file "$file" "$best_dir" && return 0
        return 1
    fi
    
    # Development subdirectory: include all files
    if [[ "$best_dir" == *"/$LIFECYCLE_DEVELOPMENT/"* ]]; then
        return 0
    fi
    
    # Development root: only direct files
    _is_direct_file "$file" "$best_dir" && return 0
    return 1
}

# PRIVATE: Collect files from environment directory
_collect_environment_files() {
    local best_dir="$1"
    local env_type="$2"
    local -n input_files_ref=$3
    local -n env_files_ref=$4
    local -n subdir_files_ref=$5
    
    # Determine if we're using lifecycle root (for fallback) or subdirectory
    local is_lifecycle_root="false"
    if [[ "$best_dir" == *"/$env_type" ]] && [[ "$best_dir" != *"/$env_type/"* ]]; then
        is_lifecycle_root="true"
        dbg "  Using $env_type root directory as default"
    fi
    
    # Collect files based on lifecycle rules
    for file in "${input_files_ref[@]}"; do
        if _should_include_file "$file" "$best_dir" "$env_type" "$is_lifecycle_root"; then
            env_files_ref+=("$file")
            
            # Track subdirectory files for smart merge (production or development)
            if [[ "$best_dir" == *"/$env_type/"* ]]; then
                subdir_files_ref+=("$(basename "$file")")
                dbg "  Environment file ($env_type subdirectory): $file"
            else
                dbg "  Environment file ($env_type root): $file"
            fi
        fi
    done
}

# PRIVATE: Add lifecycle defaults (smart merge for subdirectories)
# Works for both production and development subdirectories
# NOTE: Files with matching basenames are INCLUDED (not skipped) to enable
# service-level deep merging. The merge.sh module handles service-level merging by module+id.
_add_lifecycle_defaults() {
    local lifecycle_root_dir="$1"
    local lifecycle_name="$2"
    local -n input_files_ref=$3
    local -n env_files_ref=$4
    local -n subdir_files_ref=$5
    
    for file in "${input_files_ref[@]}"; do
        if ! _is_direct_file "$file" "$lifecycle_root_dir"; then
            continue
        fi
        
        local file_basename=$(basename "$file")
        local has_subdirectory_version=false
        
        # Check if subdirectory has a file with same basename
        for subdir_file in "${subdir_files_ref[@]}"; do
            if [[ "$subdir_file" == "$file_basename" ]]; then
                has_subdirectory_version=true
                break
            fi
        done
        
        # Always include default files - service-level merge will handle conflicts
        env_files_ref+=("$file")
        if [[ "$has_subdirectory_version" == "true" ]]; then
            dbg "  Environment file ($lifecycle_name default, will be service-merged with subdirectory): $file"
        else
            dbg "  Environment file ($lifecycle_name default for smart merge): $file"
        fi
    done
}

# PUBLIC: Environment-aware file filtering (applies lifecycle rules for file inclusion)
environment_filter_files() {
    local -n input_files=$1
    local -n output_files=$2
    output_files=()
    
    if [[ -z "$ENV_NAME" ]]; then
        output_files=("${input_files[@]}")
        return
    fi
    
    dbg "Filtering files for environment: $ENV_NAME"
    
    # Get unique directories from input files
    local unique_dirs=($(printf '%s\n' "${input_files[@]}" | xargs -n1 dirname | sort -u))
    dbg "  Available directories: ${unique_dirs[*]}"
    
    # Find best directory using lifecycle rules
    local result=$(lifecycle_get_info "$ENV_NAME" "${unique_dirs[@]}")
    local env_type=$(echo "$result" | cut -d'|' -f1)
    local best_dir=$(echo "$result" | cut -d'|' -f2)
    
    # No environment directory found
    if [[ -z "$best_dir" ]]; then
        warn "No supported config directory found for environment '$ENV_NAME'"
        return 1
    fi
    
    dbg "  Selected environment directory: $best_dir"
    dbg "  Lifecycle: $env_type"
    
    # Collect files - ORDER MATTERS for service-level merge!
    # 1. First add defaults (base)
    # 2. Then add subdirectory files (overrides)
    local env_files=()
    local subdir_files=()
    local subdir_env_files=()
    
    # If this is a subdirectory, collect defaults first
    if [[ "$best_dir" == *"/$env_type/"* ]]; then
        local lifecycle_root_dir="${best_dir%/$env_type/*}/$env_type"
        dbg "  $env_type subdirectory detected, will merge with defaults from: $lifecycle_root_dir"
        # Add defaults first (base for merging)
        _add_lifecycle_defaults "$lifecycle_root_dir" "$env_type" input_files env_files subdir_files
        # Then collect subdirectory files (overrides)
        _collect_environment_files "$best_dir" "$env_type" input_files subdir_env_files subdir_files
        # Append subdirectory files after defaults
        env_files+=("${subdir_env_files[@]}")
    else
        # Root directory only - no subdirectory merging
        _collect_environment_files "$best_dir" "$env_type" input_files env_files subdir_files
    fi
    
    # Set output
    if (( ${#env_files[@]} > 0 )); then
        output_files=("${env_files[@]}")
        dbg "Using ${#env_files[@]} files from environment directory '$best_dir' for '$ENV_NAME'"
    else
        warn "No config files found in selected directory '$best_dir' for '$ENV_NAME'"
        return 1
    fi
    
    return 0
}

readonly ENVIRONMENT_LIB_LOADED="true"
