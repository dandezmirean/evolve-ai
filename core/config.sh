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

    _CONFIG_CACHE="$(awk '
    BEGIN {
        section = ""
    }

    # Skip blank lines and comment-only lines
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/  { next }

    {
        # Strip inline comments (anything after " #" that is not inside quotes)
        # Simple approach: strip trailing " #..." portion
        line = $0

        # Detect indentation level
        indent = 0
        tmp = line
        while (substr(tmp,1,1) == " ") {
            indent++
            tmp = substr(tmp,2)
        }

        # Strip leading whitespace
        sub(/^[[:space:]]+/, "", line)
        # Strip inline comment: space + "#" followed by anything
        sub(/[[:space:]]+#.*$/, "", line)

        # Skip list items (lines starting with "- ") at top or nested level — not scalar k/v
        # But we do want to skip them silently since we only parse scalar key: value pairs
        if (substr(line,1,2) == "- ") {
            next
        }

        # Check if this is a key: value line
        colon = index(line, ":")
        if (colon == 0) { next }

        key   = substr(line, 1, colon - 1)
        value = substr(line, colon + 1)

        # Strip leading/trailing whitespace from key and value
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

        # Strip surrounding quotes from value
        if ((substr(value,1,1) == "\"" && substr(value,length(value),1) == "\"") ||
            (substr(value,1,1) == "'"'"'" && substr(value,length(value),1) == "'"'"'")) {
            value = substr(value, 2, length(value) - 2)
        }

        if (indent == 0) {
            if (value == "") {
                # Section header (no value) — set current section
                section = key
            } else {
                # Top-level scalar
                section = ""
                print key "=" value
            }
        } else {
            # Nested key under current section
            if (section != "" && key != "") {
                print section "." key "=" value
            }
        }
    }
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
