#!/usr/bin/env bash
# core/providers/interface.sh — Provider contract and dispatch for evolve-ai

_PROVIDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROVIDER_CORE_DIR="$(cd "$_PROVIDER_DIR/.." && pwd)"

source "$_PROVIDER_CORE_DIR/config.sh"
source "$_PROVIDER_DIR/claude-max.sh"
source "$_PROVIDER_DIR/claude-api.sh"
source "$_PROVIDER_DIR/openai.sh"

# provider_invoke <prompt_file> <max_turns> <workspace> <phase_name>
# Dispatches to the configured provider based on provider.type in config.
# Returns normalized JSON response to stdout.
provider_invoke() {
    local prompt_file="$1"
    local max_turns="$2"
    local workspace="$3"
    local phase_name="$4"

    local provider_type
    provider_type="$(config_get_default "provider.type" "claude-max")"

    case "$provider_type" in
        claude-max)
            claude_max_invoke "$prompt_file" "$max_turns" "$workspace" "$phase_name"
            ;;
        claude-api)
            claude_api_invoke "$prompt_file" "$max_turns" "$workspace" "$phase_name"
            ;;
        openai)
            openai_invoke "$prompt_file" "$max_turns" "$workspace" "$phase_name"
            ;;
        custom)
            echo "[provider] Custom provider not configured" >&2
            return 1
            ;;
        *)
            echo "[provider] Unknown provider type: $provider_type" >&2
            return 1
            ;;
    esac
}

# provider_parse_usage <response_file>
# Extracts usage stats from a provider response file.
# Outputs: input_tokens output_tokens cache_read cache_create
provider_parse_usage() {
    local response_file="$1"

    if [[ ! -f "$response_file" ]]; then
        echo "0 0 0 0"
        return 1
    fi

    local input_tokens output_tokens cache_read cache_create
    input_tokens="$(jq -r '.usage.input_tokens // 0' "$response_file" 2>/dev/null)"
    output_tokens="$(jq -r '.usage.output_tokens // 0' "$response_file" 2>/dev/null)"
    cache_read="$(jq -r '.usage.cache_read_input_tokens // 0' "$response_file" 2>/dev/null)"
    cache_create="$(jq -r '.usage.cache_creation_input_tokens // 0' "$response_file" 2>/dev/null)"

    echo "$input_tokens $output_tokens $cache_read $cache_create"
}

# provider_check
# Verifies the configured provider is available.
# Returns 0 if available, 1 otherwise.
provider_check() {
    local provider_type
    provider_type="$(config_get_default "provider.type" "claude-max")"

    case "$provider_type" in
        claude-max)
            claude_max_check
            ;;
        claude-api)
            claude_api_check
            ;;
        openai)
            openai_check
            ;;
        custom)
            echo "[provider] Custom provider not configured" >&2
            return 1
            ;;
        *)
            echo "[provider] Unknown provider type: $provider_type" >&2
            return 1
            ;;
    esac
}

# _log_usage <phase_name> <input_tokens> <output_tokens> <cache_read> <cache_create> <cost_usd> <status> <turns_used>
# Appends a usage entry to $EVOLVE_ROOT/usage.log
_log_usage() {
    local phase_name="$1"
    local input_tokens="$2"
    local output_tokens="$3"
    local cache_read="$4"
    local cache_create="$5"
    local cost_usd="$6"
    local status="$7"
    local turns_used="$8"

    local log_dir="${EVOLVE_ROOT:-.}"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    echo "${ts} | ${phase_name} | ${input_tokens} | ${output_tokens} | ${cache_read} | ${cache_create} | ${cost_usd} | ${status} | ${turns_used}" \
        >> "$log_dir/usage.log"
}

# _log_cost <phase_name> <cost_usd>
# Appends a cost entry to $EVOLVE_ROOT/cost.log
_log_cost() {
    local phase_name="$1"
    local cost_usd="$2"

    local log_dir="${EVOLVE_ROOT:-.}"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    echo "${ts} | ${phase_name} | \$${cost_usd}" >> "$log_dir/cost.log"
}
