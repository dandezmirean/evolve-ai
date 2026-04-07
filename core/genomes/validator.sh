#!/usr/bin/env bash
# core/genomes/validator.sh — Genome schema validation, loading, and listing
# Sourced by other scripts — do not set -e here (breaks assert_exit_code in tests)

_VALIDATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CORE_DIR="$(cd "$_VALIDATOR_DIR/.." && pwd)"

# Source config parser if not already loaded
if ! declare -f load_config >/dev/null 2>&1; then
    source "$_CORE_DIR/config.sh"
fi

# Required top-level fields in genome.yaml
_GENOME_REQUIRED_FIELDS=(
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
# validate_genome <genome_dir>
# Validates that genome_dir contains a valid genome.yaml with all required
# fields. Returns 0 if valid, 1 with error messages to stderr if invalid.
# ---------------------------------------------------------------------------
validate_genome() {
    local genome_dir="$1"
    local genome_yaml="$genome_dir/genome.yaml"
    local errors=0

    if [[ ! -d "$genome_dir" ]]; then
        echo "validate_genome: directory not found: $genome_dir" >&2
        return 1
    fi

    if [[ ! -f "$genome_yaml" ]]; then
        echo "validate_genome: genome.yaml not found in $genome_dir" >&2
        return 1
    fi

    # Load the genome config to check for required fields
    local saved_cache="$_CONFIG_CACHE"
    load_config "$genome_yaml"

    for field in "${_GENOME_REQUIRED_FIELDS[@]}"; do
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
                if ! grep -qE "^${field}:" "$genome_yaml" 2>/dev/null; then
                    echo "validate_genome: missing required field '$field' in $genome_yaml" >&2
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
# load_genome <genome_dir>
# Sources genome.yaml values into shell variables using the config parser.
# Sets GENOME_NAME, GENOME_DESCRIPTION, and loads the full config cache.
# ---------------------------------------------------------------------------
load_genome() {
    local genome_dir="$1"
    local genome_yaml="$genome_dir/genome.yaml"

    if [[ ! -f "$genome_yaml" ]]; then
        echo "load_genome: genome.yaml not found in $genome_dir" >&2
        return 1
    fi

    load_config "$genome_yaml"

    GENOME_NAME="$(config_get "name")"
    GENOME_DESCRIPTION="$(config_get "description")"
    GENOME_DIR="$genome_dir"

    export GENOME_NAME GENOME_DESCRIPTION GENOME_DIR
}

# ---------------------------------------------------------------------------
# list_genomes <genomes_dir>
# Lists all valid genome directories under genomes_dir (skipping _template).
# Prints one line per valid genome: "name — description"
# ---------------------------------------------------------------------------
list_genomes() {
    local genomes_dir="$1"
    local count=0

    if [[ ! -d "$genomes_dir" ]]; then
        echo "list_genomes: directory not found: $genomes_dir" >&2
        return 1
    fi

    local saved_cache="$_CONFIG_CACHE"

    for genome_dir in "$genomes_dir"/*/; do
        # Skip _template directory
        local dirname
        dirname="$(basename "$genome_dir")"
        if [[ "$dirname" == "_template" ]]; then
            continue
        fi

        # Skip if not a valid genome
        if ! validate_genome "$genome_dir" 2>/dev/null; then
            continue
        fi

        load_config "$genome_dir/genome.yaml"
        local name desc
        name="$(config_get "name")"
        desc="$(config_get "description")"
        echo "$name — $desc"
        count=$(( count + 1 ))
    done

    _CONFIG_CACHE="$saved_cache"

    if [[ "$count" -eq 0 ]]; then
        echo "No valid genomes found in $genomes_dir" >&2
        return 1
    fi

    return 0
}
