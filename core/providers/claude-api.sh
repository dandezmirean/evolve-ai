#!/usr/bin/env bash
# core/providers/claude-api.sh — Claude API provider (stub)

# claude_api_invoke <prompt_file> <max_turns> <workspace> <phase_name>
# Stub: not yet implemented.
claude_api_invoke() {
    local prompt_file="$1"
    local max_turns="$2"
    local workspace="$3"
    local phase_name="$4"

    echo "[claude-api] Provider not yet implemented" >&2
    return 1
}

# claude_api_check
# Stub: checks for ANTHROPIC_API_KEY environment variable.
claude_api_check() {
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        return 0
    else
        echo "[claude-api] ANTHROPIC_API_KEY not set" >&2
        return 1
    fi
}
