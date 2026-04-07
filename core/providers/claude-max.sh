#!/usr/bin/env bash
# core/providers/claude-max.sh — Claude Max plan provider (default)

# claude_max_invoke <prompt_file> <max_turns> <workspace> <phase_name>
# Invokes claude CLI with the Max plan (no API key needed).
# 1. Reads the prompt file
# 2. Replaces {{WORKSPACE}} with the actual workspace path
# 3. Calls claude -p with --dangerously-skip-permissions --output-format json --max-turns
# 4. Parses the JSON response
# 5. Writes normalized response to workspace: {phase_name}-response.json
# 6. Checks for rate limiting
# 7. Writes to usage.log and cost.log
claude_max_invoke() {
    local prompt_file="$1"
    local max_turns="$2"
    local workspace="$3"
    local phase_name="$4"

    if [[ ! -f "$prompt_file" ]]; then
        echo "[claude-max] Prompt file not found: $prompt_file" >&2
        return 1
    fi

    # 1. Read and template the prompt
    local prompt_text
    prompt_text="$(cat "$prompt_file")"

    # 2. Replace {{WORKSPACE}} placeholder
    prompt_text="${prompt_text//\{\{WORKSPACE\}\}/$workspace}"

    # 3. Invoke claude CLI
    local raw_output
    local exit_code=0
    raw_output="$(claude -p "$prompt_text" \
        --dangerously-skip-permissions \
        --output-format json \
        --max-turns "$max_turns" 2>&1)" || exit_code=$?

    # 5. Write raw response to workspace
    local response_file="$workspace/${phase_name}-response.json"
    echo "$raw_output" > "$response_file"

    # 6. Rate limit detection
    local is_rate_limited=0
    local rate_limit_reset=""
    if echo "$raw_output" | grep -qi "you've hit your limit\|rate.limit\|overloaded\|too many requests"; then
        is_rate_limited=1
        # Try to extract reset time from error message
        rate_limit_reset="$(echo "$raw_output" | grep -oP '(?:resets?\s+(?:at|in)\s+)\K[^\."]+' 2>/dev/null || true)"
        echo "[claude-max] Rate limited. Reset: ${rate_limit_reset:-unknown}" >&2
    fi

    # 4. Parse usage from JSON response
    local input_tokens=0 output_tokens=0 cache_read=0 cache_create=0
    local turns_used=0

    if command -v jq >/dev/null 2>&1 && echo "$raw_output" | jq empty 2>/dev/null; then
        input_tokens="$(echo "$raw_output" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo 0)"
        output_tokens="$(echo "$raw_output" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo 0)"
        cache_read="$(echo "$raw_output" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null || echo 0)"
        cache_create="$(echo "$raw_output" | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null || echo 0)"
        turns_used="$(echo "$raw_output" | jq -r '.num_turns // 0' 2>/dev/null || echo 0)"
    fi

    # Determine status
    local status="ok"
    if [[ $exit_code -ne 0 ]]; then
        status="error"
    fi
    if [[ $is_rate_limited -eq 1 ]]; then
        status="rate_limited"
    fi

    # 7. Write to usage.log and cost.log
    # Claude Max plan has no per-token cost ($0.00), but we log for tracking
    local cost_usd="0.00"

    if declare -f _log_usage >/dev/null 2>&1; then
        _log_usage "$phase_name" "$input_tokens" "$output_tokens" "$cache_read" "$cache_create" "$cost_usd" "$status" "$turns_used"
    fi
    if declare -f _log_cost >/dev/null 2>&1; then
        _log_cost "$phase_name" "$cost_usd"
    fi

    # Output the response file path
    echo "$response_file"

    return $exit_code
}

# claude_max_check
# Verifies that the claude CLI command is available.
# Returns 0 if available, 1 otherwise.
claude_max_check() {
    if command -v claude >/dev/null 2>&1; then
        return 0
    else
        echo "[claude-max] 'claude' command not found in PATH" >&2
        return 1
    fi
}
