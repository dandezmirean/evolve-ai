#!/usr/bin/env bash
# core/config.sh — YAML config parser for evolve-ai (no external deps beyond coreutils/awk)

# Internal cache: newline-separated "section.key=value" or "key=value" pairs
_CONFIG_CACHE=""

# load_config <config_file>
# Parses a YAML file into a flat key=value cache stored in _CONFIG_CACHE.
# Handles top-level scalar keys and one-level nested keys (section.key).
# Strips inline comments and surrounding quotes.
load_config() {
    local config_file="$1"

    if [[ -z "$config_file" ]]; then
        echo "load_config: no config file specified" >&2
        return 1
    fi

    if [[ ! -f "$config_file" ]]; then
        echo "load_config: file not found: $config_file" >&2
        return 1
    fi

    # Use yq to flatten YAML into key.path=value pairs
    _CONFIG_CACHE="$(yq '
        .. | select(tag != "!!map" and tag != "!!seq") |
        (path | join(".")) + "=" + (. | tostring)
    ' "$config_file")"

    return 0
}

# config_get <key>
# Returns the value for a key from _CONFIG_CACHE.
# Key can be "version" (top-level) or "provider.type" (nested).
# Prints empty string if key not found.
config_get() {
    local key="$1"
    local result

    result="$(printf '%s\n' "$_CONFIG_CACHE" | awk -F'=' -v k="$key" '
        $1 == k {
            # Rejoin value in case it contained "="
            val = $2
            for (i = 3; i <= NF; i++) val = val "=" $i
            print val
            exit
        }
    ')"

    printf '%s' "$result"
}

# config_get_default <key> <default>
# Returns the value for a key, or <default> if the key is missing or empty.
config_get_default() {
    local key="$1"
    local default="$2"
    local value

    value="$(config_get "$key")"

    if [[ -z "$value" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}
