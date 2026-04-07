#!/usr/bin/env bash
# core/providers/openai.sh — OpenAI-compatible provider (stub)

# openai_invoke <prompt_file> <max_turns> <workspace> <phase_name>
# Stub: not yet implemented.
openai_invoke() {
    local prompt_file="$1"
    local max_turns="$2"
    local workspace="$3"
    local phase_name="$4"

    echo "[openai] Provider not yet implemented" >&2
    return 1
}

# openai_check
# Stub: checks for OPENAI_API_KEY environment variable.
openai_check() {
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        return 0
    else
        echo "[openai] OPENAI_API_KEY not set" >&2
        return 1
    fi
}
