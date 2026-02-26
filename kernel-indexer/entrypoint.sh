#!/bin/bash
set -euo pipefail

# Exit codes
EXIT_SUCCESS=0
EXIT_GENERAL_ERROR=1
EXIT_MISSING_DEPS=2
EXIT_KERNEL_ROOT_INVALID=3
EXIT_INDEX_FAILED=4
EXIT_COLLATE_FAILED=5
EXIT_CATALOG_UPDATE_FAILED=6

# Default configuration
DEFAULT_KERNEL_ROOT="/sw/icrn/jupyter/icrn_ncsa_resources/Kernels"

# Environment variables with defaults
KERNEL_ROOT="${KERNEL_ROOT:-${DEFAULT_KERNEL_ROOT}}"
# When running in container with standard mount (/app/data), use host path for catalog entries
# so catalog paths are valid on the host/NFS, not inside the container.
if [ -n "${KERNEL_ROOT_HOST:-}" ]; then
    : # use explicit KERNEL_ROOT_HOST
elif [ "${KERNEL_ROOT}" = "/app/data" ]; then
    KERNEL_ROOT_HOST="/sw/icrn/dev/kernels"
else
    KERNEL_ROOT_HOST="${KERNEL_ROOT}"
fi
OUTPUT_DIR="${OUTPUT_DIR:-${KERNEL_ROOT}}"
LANGUAGE_FILTER="${LANGUAGE_FILTER:-}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
ATOMIC_WRITES="${ATOMIC_WRITES:-true}"

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "[${timestamp}] [${level}] ${message}"
}

log_info() {
    if [[ "${LOG_LEVEL}" == "DEBUG" ]] || [[ "${LOG_LEVEL}" == "INFO" ]]; then
        log "INFO" "$@"
    fi
}

log_error() {
    log "ERROR" "$@" >&2
}

log_warn() {
    if [[ "${LOG_LEVEL}" != "ERROR" ]]; then
        log "WARN" "$@" >&2
    fi
}

log_debug() {
    if [[ "${LOG_LEVEL}" == "DEBUG" ]]; then
        log "DEBUG" "$@"
    fi
}

# Validation functions
check_dependencies() {
    log_info "Checking dependencies..."
    
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed or not in PATH"
        exit $EXIT_MISSING_DEPS
    fi
    
    if ! command -v conda &> /dev/null; then
        log_error "conda is not installed or not in PATH"
        exit $EXIT_MISSING_DEPS
    fi
    
    if ! command -v kernel_indexer &> /dev/null; then
        log_error "kernel_indexer script is not found or not in PATH"
        exit $EXIT_MISSING_DEPS
    fi
    
    if [ ! -x "$(command -v kernel_indexer)" ]; then
        log_error "kernel_indexer script is not executable"
        exit $EXIT_MISSING_DEPS
    fi
    
    log_info "All dependencies found"
}

validate_kernel_root() {
    log_info "Validating kernel root: ${KERNEL_ROOT}"
    
    # Check if directory exists (do NOT create it - this is core infrastructure)
    if [ ! -d "${KERNEL_ROOT}" ]; then
        log_error "Kernel root directory does not exist: ${KERNEL_ROOT}"
        log_error "This is core infrastructure - if missing, something is seriously wrong"
        exit $EXIT_KERNEL_ROOT_INVALID
    fi
    
    # Check if directory is readable
    if [ ! -r "${KERNEL_ROOT}" ]; then
        log_error "Kernel root directory is not readable: ${KERNEL_ROOT}"
        exit $EXIT_KERNEL_ROOT_INVALID
    fi
    
    # Check if directory is writable (needed for writing manifests)
    if [ ! -w "${KERNEL_ROOT}" ]; then
        log_error "Kernel root directory is not writable: ${KERNEL_ROOT}"
        log_error "Write access is required to create package_manifest.json files"
        exit $EXIT_KERNEL_ROOT_INVALID
    fi
    
    log_info "Kernel root validation passed"
}

validate_output_dir() {
    log_info "Validating output directory: ${OUTPUT_DIR}"
    
    # Check if output directory exists
    if [ ! -d "${OUTPUT_DIR}" ]; then
        log_error "Output directory does not exist: ${OUTPUT_DIR}"
        exit $EXIT_KERNEL_ROOT_INVALID
    fi
    
    # Check if output directory is writable
    if [ ! -w "${OUTPUT_DIR}" ]; then
        log_error "Output directory is not writable: ${OUTPUT_DIR}"
        exit $EXIT_KERNEL_ROOT_INVALID
    fi
    
    log_info "Output directory validation passed"
}

# Validate collated file
validate_collated_file() {
    local output_file="$1"
    local file_description="$2"
    
    log_info "Validating ${file_description}: ${output_file}"
    
    # Check if file exists
    if [ ! -f "${output_file}" ]; then
        log_error "${file_description} not found: ${output_file}"
        return 1
    fi
    
    # Validate JSON structure
    if ! jq '.' "${output_file}" >/dev/null 2>&1; then
        log_error "Invalid JSON in ${file_description}: ${output_file}"
        return 1
    fi
    
    # Get file size for logging (portable approach)
    local file_size
    if command -v stat &> /dev/null; then
        file_size=$(stat -f%z "${output_file}" 2>/dev/null || stat -c%s "${output_file}" 2>/dev/null || wc -c < "${output_file}" 2>/dev/null || echo "unknown")
    else
        file_size=$(wc -c < "${output_file}" 2>/dev/null || echo "unknown")
    fi
    log_info "${file_description} validated successfully (size: ${file_size} bytes)"
    return 0
}

# Normalize language name to match catalog conventions (capitalize first letter)
normalize_language() {
    local lang="$1"
    if [ -z "$lang" ]; then
        echo ""
        return
    fi
    # Capitalize first letter, lowercase the rest
    local first_char=$(echo "${lang:0:1}" | tr '[:lower:]' '[:upper:]')
    local rest_chars=$(echo "${lang:1}" | tr '[:upper:]' '[:lower:]')
    echo "${first_char}${rest_chars}"
}

# Update icrn_kernel_catalog.json with discovered kernels
update_kernel_catalog() {
    local collated_manifests="$1"
    local catalog_file="${KERNEL_ROOT}/icrn_kernel_catalog.json"
    
    log_info "Starting catalog update phase..."
    log_info "Reading collated manifests from: ${collated_manifests}"
    log_info "Catalog file: ${catalog_file}"
    
    # Check if collated manifests file exists
    if [ ! -f "${collated_manifests}" ]; then
        log_error "Collated manifests file not found: ${collated_manifests}"
        return 1
    fi
    
    # Validate collated manifests JSON
    if ! jq '.' "${collated_manifests}" >/dev/null 2>&1; then
        log_error "Invalid JSON in collated manifests: ${collated_manifests}"
        return 1
    fi
    
    # Load existing catalog or create empty structure
    local existing_catalog
    if [ -f "${catalog_file}" ]; then
        log_info "Loading existing catalog from: ${catalog_file}"
        if ! jq '.' "${catalog_file}" >/dev/null 2>&1; then
            log_error "Invalid JSON in existing catalog: ${catalog_file}"
            return 1
        fi
        existing_catalog=$(cat "${catalog_file}")
    else
        log_info "Catalog file does not exist, creating new catalog"
        existing_catalog="{}"
    fi
    
    # Create temporary file for updated catalog
    local temp_catalog=$(mktemp)
    
    # Process each kernel from collated manifests
    local kernel_count=0
    local updated_count=0
    local added_count=0
    
    # Extract kernels array and process each kernel
    local kernels_json=$(jq -c '.kernels[]?' "${collated_manifests}" 2>/dev/null)
    
    if [ -z "$kernels_json" ]; then
        log_warn "No kernels found in collated manifests"
        # If no kernels and catalog doesn't exist, create empty catalog
        if [ ! -f "${catalog_file}" ]; then
            echo "{}" | jq '.' > "${temp_catalog}"
            if [ "${ATOMIC_WRITES}" = "true" ]; then
                mv "${temp_catalog}" "${catalog_file}"
            else
                cp "${temp_catalog}" "${catalog_file}"
                rm -f "${temp_catalog}"
            fi
            log_info "Created empty catalog file"
        fi
        return 0
    fi
    
    # Start with existing catalog
    local updated_catalog="$existing_catalog"
    
    # Process each kernel
    while IFS= read -r kernel_json; do
        [ -z "$kernel_json" ] && continue
        
        kernel_count=$((kernel_count + 1))
        
        # Extract kernel information
        local kernel_name=$(echo "$kernel_json" | jq -r '.kernel_name // empty')
        local kernel_version=$(echo "$kernel_json" | jq -r '.kernel_version // empty')
        local language=$(echo "$kernel_json" | jq -r '.language // empty')
        
        if [ -z "$kernel_name" ] || [ -z "$kernel_version" ] || [ -z "$language" ]; then
            log_warn "Skipping kernel with missing required fields: ${kernel_json}"
            continue
        fi
        
        # Normalize language name
        local normalized_lang=$(normalize_language "$language")
        
        # Construct paths using host path instead of container path
        local environment_location="${KERNEL_ROOT_HOST}/${normalized_lang}/${kernel_name}/${kernel_version}"
        local manifest_path="${KERNEL_ROOT_HOST}/${normalized_lang}/${kernel_name}/${kernel_version}/package_manifest.json"
        
        log_debug "Processing kernel: ${normalized_lang}/${kernel_name}/${kernel_version}"
        
        # Check if kernel entry already exists in catalog
        if echo "$updated_catalog" | jq -e --arg lang "$normalized_lang" --arg name "$kernel_name" --arg ver "$kernel_version" \
            '.[$lang][$name][$ver] != null' >/dev/null 2>&1; then
            # Update existing entry
            updated_catalog=$(echo "$updated_catalog" | jq --arg lang "$normalized_lang" \
                --arg name "$kernel_name" \
                --arg ver "$kernel_version" \
                --arg env_loc "$environment_location" \
                --arg manifest "$manifest_path" \
                '.[$lang][$name][$ver].environment_location = $env_loc | 
                 .[$lang][$name][$ver].manifest = $manifest')
            updated_count=$((updated_count + 1))
            log_debug "Updated existing catalog entry: ${normalized_lang}/${kernel_name}/${kernel_version}"
        else
            # Add new entry
            updated_catalog=$(echo "$updated_catalog" | jq --arg lang "$normalized_lang" \
                --arg name "$kernel_name" \
                --arg ver "$kernel_version" \
                --arg env_loc "$environment_location" \
                --arg manifest "$manifest_path" \
                'if .[$lang] == null then .[$lang] = {} else . end |
                 if .[$lang][$name] == null then .[$lang][$name] = {} else . end |
                 .[$lang][$name][$ver] = {
                     environment_location: $env_loc,
                     manifest: $manifest
                 }')
            added_count=$((added_count + 1))
            log_debug "Added new catalog entry: ${normalized_lang}/${kernel_name}/${kernel_version}"
        fi
    done <<< "$kernels_json"
    
    # Write updated catalog to temp file
    echo "$updated_catalog" | jq '.' > "${temp_catalog}"
    
    if [ $? -ne 0 ]; then
        log_error "Failed to write updated catalog to temp file"
        rm -f "${temp_catalog}"
        return 1
    fi
    
    # Validate the updated catalog JSON
    if ! jq '.' "${temp_catalog}" >/dev/null 2>&1; then
        log_error "Invalid JSON in updated catalog"
        rm -f "${temp_catalog}"
        return 1
    fi
    
    # Write catalog file (atomic if enabled)
    if [ "${ATOMIC_WRITES}" = "true" ]; then
        mv "${temp_catalog}" "${catalog_file}"
        log_info "Catalog updated atomically: ${catalog_file}"
    else
        cp "${temp_catalog}" "${catalog_file}"
        rm -f "${temp_catalog}"
        log_info "Catalog updated: ${catalog_file}"
    fi
    
    # Set permissions: user+group read/write, others read-only
    chmod 664 "${catalog_file}"
    log_debug "Set catalog file permissions to 664 (rw-rw-r--): ${catalog_file}"
    
    log_info "Catalog update completed successfully"
    log_info "  Processed kernels: ${kernel_count}"
    log_info "  Updated entries: ${updated_count}"
    log_info "  Added entries: ${added_count}"
    
    return 0
}

# Main execution
main() {
    log_info "Starting kernel indexer container"
    log_info "KERNEL_ROOT: ${KERNEL_ROOT}"
    log_info "KERNEL_ROOT_HOST: ${KERNEL_ROOT_HOST}"
    log_info "OUTPUT_DIR: ${OUTPUT_DIR}"
    if [ -n "${LANGUAGE_FILTER}" ]; then
        log_info "LANGUAGE_FILTER: ${LANGUAGE_FILTER}"
    else
        log_info "LANGUAGE_FILTER: (all languages)"
    fi
    
    # Validation phase
    check_dependencies
    validate_kernel_root
    validate_output_dir
    
    # Build index command
    local index_cmd="kernel_indexer index --kernel-root '${KERNEL_ROOT}'"
    if [ -n "${LANGUAGE_FILTER}" ]; then
        index_cmd="${index_cmd} --language '${LANGUAGE_FILTER}'"
    fi
    
    # Build collate command
    local collate_cmd="kernel_indexer collate --kernel-root '${KERNEL_ROOT}' --output-dir '${OUTPUT_DIR}'"
    if [ -n "${LANGUAGE_FILTER}" ]; then
        collate_cmd="${collate_cmd} --language '${LANGUAGE_FILTER}'"
    fi
    
    # Execute indexing phase
    log_info "Starting indexing phase..."
    log_debug "Command: ${index_cmd}"
    
    if eval "${index_cmd}"; then
        log_info "Indexing phase completed successfully"
    else
        local exit_code=$?
        log_error "Indexing phase failed with exit code: ${exit_code}"
        exit $EXIT_INDEX_FAILED
    fi
    
    # Execute collation phase
    log_info "Starting collation phase..."
    log_debug "Command: ${collate_cmd}"
    
    # If atomic writes are enabled, we need to intercept the output
    # kernel_indexer writes directly, so we'll validate after
    if eval "${collate_cmd}"; then
        log_info "Collation command completed"
        
        # Validate collated files
        log_info "Validating collated output files..."
        
        local collated_manifests="${OUTPUT_DIR}/collated_manifests.json"
        local package_index="${OUTPUT_DIR}/package_index.json"
        
        if ! validate_collated_file "${collated_manifests}" "collated manifests"; then
            exit $EXIT_COLLATE_FAILED
        fi
        
        if ! validate_collated_file "${package_index}" "package index"; then
            exit $EXIT_COLLATE_FAILED
        fi
        
        log_info "All collated files validated successfully"
        
        log_info "Collation phase completed successfully"
    else
        local exit_code=$?
        log_error "Collation phase failed with exit code: ${exit_code}"
        exit $EXIT_COLLATE_FAILED
    fi
    
    # Execute catalog update phase
    log_info "Starting catalog update phase..."
    
    if update_kernel_catalog "${collated_manifests}"; then
        log_info "Catalog update phase completed successfully"
        
        # Validate updated catalog file
        local catalog_file="${KERNEL_ROOT}/icrn_kernel_catalog.json"
        if ! validate_collated_file "${catalog_file}" "kernel catalog"; then
            log_error "Catalog file validation failed"
            exit $EXIT_CATALOG_UPDATE_FAILED
        fi
    else
        local exit_code=$?
        log_error "Catalog update phase failed with exit code: ${exit_code}"
        exit $EXIT_CATALOG_UPDATE_FAILED
    fi
    
    log_info "Kernel indexing completed successfully"
    exit $EXIT_SUCCESS
}

# Run main function
main "$@"

