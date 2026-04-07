#!/usr/bin/env bash
# core/packs/validator.sh — Pack schema validation, loading, and listing
# Sourced by other scripts — do not set -e here (breaks assert_exit_code in tests)

_VALIDATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CORE_DIR="$(cd "$_VALIDATOR_DIR/.." && pwd)"

# Source config parser if not already loaded
if ! declare -f load_config >/dev/null 2>&1; then
    source "$_CORE_DIR/config.sh"
fi

# Required top-level fields in pack.yaml
_PACK_REQUIRED_FIELDS=(
    name
    description
    scan_commands
    health_checks
    safety_rules
    reversibility
    commit_categories
    challenge_vectors
)

# ---------------------------------------------------------------------------
# validate_pack <pack_dir>
# Validates that pack_dir contains a valid pack.yaml with all required fields.
# Returns 0 if valid, 1 with error messages to stderr if invalid.
# ---------------------------------------------------------------------------
validate_pack() {
    local pack_dir="$1"
    local pack_yaml="$pack_dir/pack.yaml"
    local errors=0

    if [[ ! -d "$pack_dir" ]]; then
        echo "validate_pack: directory not found: $pack_dir" >&2
        return 1
    fi

    if [[ ! -f "$pack_yaml" ]]; then
        echo "validate_pack: pack.yaml not found in $pack_dir" >&2
        return 1
    fi

    # Load the pack config to check for required fields
    local saved_cache="$_CONFIG_CACHE"
    load_config "$pack_yaml"

    for field in "${_PACK_REQUIRED_FIELDS[@]}"; do
        local value
        value="$(config_get "$field")"
        # For fields that are section headers (no scalar value), check if any
        # key starts with "field." in the cache
        if [[ -z "$value" ]]; then
            # Check if it exists as a section (has nested keys)
            local has_section
            has_section="$(printf '%s\n' "$_CONFIG_CACHE" | grep -c "^${field}\." || true)"
            if [[ "$has_section" -eq 0 ]]; then
                # Also check if the raw YAML has the field as a list header
                if ! grep -qE "^${field}:" "$pack_yaml" 2>/dev/null; then
                    echo "validate_pack: missing required field '$field' in $pack_yaml" >&2
                    errors=$(( errors + 1 ))
                fi
            fi
        fi
    done

    # Restore previous config cache
    _CONFIG_CACHE="$saved_cache"

    if [[ "$errors" -gt 0 ]]; then
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# load_pack <pack_dir>
# Sources pack.yaml values into shell variables using the config parser.
# Sets PACK_NAME, PACK_DESCRIPTION, and loads the full config cache.
# ---------------------------------------------------------------------------
load_pack() {
    local pack_dir="$1"
    local pack_yaml="$pack_dir/pack.yaml"

    if [[ ! -f "$pack_yaml" ]]; then
        echo "load_pack: pack.yaml not found in $pack_dir" >&2
        return 1
    fi

    load_config "$pack_yaml"

    PACK_NAME="$(config_get "name")"
    PACK_DESCRIPTION="$(config_get "description")"
    PACK_DIR="$pack_dir"

    export PACK_NAME PACK_DESCRIPTION PACK_DIR
}

# ---------------------------------------------------------------------------
# list_packs <packs_dir>
# Lists all valid pack directories under packs_dir (skipping _template).
# Prints one line per valid pack: "name — description"
# ---------------------------------------------------------------------------
list_packs() {
    local packs_dir="$1"
    local count=0

    if [[ ! -d "$packs_dir" ]]; then
        echo "list_packs: directory not found: $packs_dir" >&2
        return 1
    fi

    local saved_cache="$_CONFIG_CACHE"

    for pack_dir in "$packs_dir"/*/; do
        # Skip _template directory
        local dirname
        dirname="$(basename "$pack_dir")"
        if [[ "$dirname" == "_template" ]]; then
            continue
        fi

        # Skip if not a valid pack
        if ! validate_pack "$pack_dir" 2>/dev/null; then
            continue
        fi

        load_config "$pack_dir/pack.yaml"
        local name desc
        name="$(config_get "name")"
        desc="$(config_get "description")"
        echo "$name — $desc"
        count=$(( count + 1 ))
    done

    _CONFIG_CACHE="$saved_cache"

    if [[ "$count" -eq 0 ]]; then
        echo "No valid packs found in $packs_dir" >&2
        return 1
    fi

    return 0
}
