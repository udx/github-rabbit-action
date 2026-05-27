#!/usr/bin/env bash
set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library modules
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/validation.sh"
source "$SCRIPT_DIR/lib/discovery.sh"
source "$SCRIPT_DIR/lib/merge.sh"
source "$SCRIPT_DIR/lib/environment.sh"
source "$SCRIPT_DIR/lib/output.sh"

# Main execution logic
main() {
    # Validate inputs
    if ! validation_check_inputs; then
        exit 1
    fi
    
    dbg "Configuration:"
    dbg "  Source directory: $SOURCE_DIR"
    dbg "  Environment: ${ENV_NAME:-auto-detect}"
    dbg "  Output format: $OUTPUT_FORMAT"
    dbg "  Recursive: $RECURSIVE"
    dbg "  File patterns: $FILE_PATTERNS"
    dbg "  Exclude patterns: $EXCLUDE"
    
    # Find all configuration files
    local all_files=()
    discovery_find_config_files "$SOURCE_DIR" all_files
    
    if (( ${#all_files[@]} == 0 )); then
        warn "No configuration files found in '$SOURCE_DIR'"
        output_generate_empty
        output_write_empty_summary "No configuration files were found under \`$SOURCE_DIR\`."
        exit 0
    fi
    
    # Validate that files are in lifecycle directories (not root level)
    local valid_files=()
    for file in "${all_files[@]}"; do
        local relative_file="${file#$SOURCE_DIR/}"
        local lifecycle_root="${relative_file%%/*}"
        local file_dir=$(dirname "$file")
        local parent_dir=$(basename "$file_dir")

        if [[ ",$ALL_LIFECYCLES_STR," != *",$lifecycle_root,"* ]]; then
            dbg "Skipping file outside configured lifecycle roots: $file"
            continue
        fi
        
        # Skip root-level files - configs must be in lifecycle directories
        if [[ "$parent_dir" == "$(basename "$SOURCE_DIR")" ]]; then
            dbg "Skipping root-level file (not in lifecycle dir): $file"
            continue
        fi
        
        valid_files+=("$file")
    done
    
    if (( ${#valid_files[@]} == 0 )); then
        warn "No configuration files found in lifecycle directories (production/staging/development)"
        output_generate_empty
        output_write_empty_summary "Config files were found, but none were inside supported lifecycle directories."
        exit 0
    fi
    
    # Use only valid files from here on
    all_files=("${valid_files[@]}")
    dbg "Found ${#all_files[@]} configuration files in lifecycle directories"
    
    # Determine which environments to process
    local environments=()
    if [[ -n "$ENV_NAME" ]]; then
        # Single environment mode
        log "Processing environment: $ENV_NAME"
        environments=("$ENV_NAME")
    else
        # Auto-detect mode: scan for all environments
        log "Auto-detect mode: scanning for environments..."
        lifecycle_detect_environments "$SOURCE_DIR" environments
        log "Detected ${#environments[@]} environment(s): ${environments[*]}"
        log "Will create ${#environments[@]} file(s), each named: ${MERGED_FILE_PREFIX}<environment>-infra.yaml"
    fi
    
    # Process each environment (unified logic for both modes)
    local merged_files=()
    local total_files=0
    
    for env in "${environments[@]}"; do
        dbg "Processing environment: $env"
        
        # Filter files for this environment (use global to avoid nameref scope issues)
        FILTERED_ENV_FILES=()
        # In single-env mode, ENV_NAME is already set; in auto-detect, we need to set it temporarily
        if [[ ${#environments[@]} -gt 1 ]]; then
            local saved_env="$ENV_NAME"
            export ENV_NAME="$env"
            if ! environment_filter_files all_files FILTERED_ENV_FILES; then
                export ENV_NAME="$saved_env"
                warn "Skipping environment '$env': no valid config files for resolved lifecycle"
                continue
            fi
            export ENV_NAME="$saved_env"
        else
            # Single-env mode: ENV_NAME already set correctly
            if ! environment_filter_files all_files FILTERED_ENV_FILES; then
                err "No valid config files found for environment '$env'"
                exit 1
            fi
        fi
        
        if (( ${#FILTERED_ENV_FILES[@]} == 0 )); then
            warn "No configuration files found for environment '$env'"
            # In single-env mode, this is an error; in auto-detect, just skip
            if [[ ${#environments[@]} -eq 1 ]]; then
                exit 1
            fi
            continue
        fi
        
        dbg "Found ${#FILTERED_ENV_FILES[@]} configuration files for $env"
        
        # Determine lifecycle and directory
        local unique_dirs=($(printf '%s\n' "${FILTERED_ENV_FILES[@]}" | xargs -n1 dirname | sort -u))
        local result=$(lifecycle_get_info "$env" "${unique_dirs[@]}")
        local lifecycle=$(echo "$result" | cut -d'|' -f1)
        local best_dir=$(echo "$result" | cut -d'|' -f2)
        local is_protected=$(echo "$result" | cut -d'|' -f3)
        
        dbg "Lifecycle: $lifecycle, Directory: $best_dir, Protected: $is_protected"
        
        # Determine output filename
        local output_file=$(output_determine_filename "$SOURCE_DIR" "$env")
        
        # Set lifecycle for single-env mode
        if [[ ${#environments[@]} -eq 1 ]]; then
            export LIFECYCLE="$lifecycle"
            
            # Show protected branch info if applicable
            if [[ "$is_protected" == "true" ]]; then
                log "Branch '$env' is protected → using production lifecycle"
            fi
            
            local log_msg=$(output_generate_log_message "$env" "$lifecycle" "$best_dir")
            log "$log_msg"
            
            # Show which files are being merged
            log "Merging ${#FILTERED_ENV_FILES[@]} file(s):"
            for file in "${FILTERED_ENV_FILES[@]}"; do
                local rel_path="${file#$SOURCE_DIR/}"
                log "  - $rel_path"
            done
        fi
        
        # Merge configuration files
        if merge_yaml_files "$output_file" "${FILTERED_ENV_FILES[@]}"; then
            output_track_merged_file "$output_file" "${FILTERED_ENV_FILES[@]}"
            merged_files+=("$output_file")
            total_files=$((total_files + ${#FILTERED_ENV_FILES[@]}))
            
            # Different logging for single vs multi-env
            if [[ ${#environments[@]} -eq 1 ]]; then
                local output_filename=$(basename "$output_file")
                log "✓ Created $output_filename"
            else
                # Determine env info for better messaging in auto-detect
                local output_filename=$(basename "$output_file")
                local env_info=""
                if [[ "$best_dir" == *"/$lifecycle/$env" ]]; then
                    env_info="$lifecycle/$env/ (smart merge)"
                    elif [[ "$best_dir" == *"/$lifecycle" ]]; then
                    env_info="$lifecycle/"
                else
                    env_info="$best_dir"
                fi
                log "Environment '$env': Created $output_filename (${#FILTERED_ENV_FILES[@]} config(s) from $env_info)"
            fi
        else
            err "Failed to create merged file for $env"
            exit 1
        fi
    done
    
    # Verify we created at least one file
    if (( ${#merged_files[@]} == 0 )); then
        err "No merged files were created"
        exit 1
    fi
    
    # Generate GitHub Actions outputs
    output_generate "${merged_files[@]}"
    output_write_summary "${merged_files[@]}"
    
    # Final summary (only for auto-detect mode)
    if [[ ${#environments[@]} -gt 1 ]]; then
        log "✓ Summary: Created ${#merged_files[@]} merged file(s) from $total_files config(s) across ${#environments[@]} environment(s)"
    fi
}

# Run main function
main "$@"
