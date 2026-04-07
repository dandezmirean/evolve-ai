#!/usr/bin/env bash
# core/notifications/discord.sh — Discord notification provider

# notify_discord <message> <webhook_url>
# Posts a message to a Discord webhook. Silent on failure.
notify_discord() {
    local message="$1"
    local webhook_url="$2"

    if [[ -z "$webhook_url" ]]; then
        return 0
    fi

    local payload
    payload="$(jq -n --arg text "$message" '{"content": $text}')"

    curl -s -X POST "$webhook_url" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        >/dev/null 2>&1 || true
}
