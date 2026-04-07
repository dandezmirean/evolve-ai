#!/usr/bin/env bash
# core/notifications/slack.sh — Slack notification provider

# notify_slack <message> <webhook_url>
# Posts a message to a Slack incoming webhook. Silent on failure.
notify_slack() {
    local message="$1"
    local webhook_url="$2"

    if [[ -z "$webhook_url" ]]; then
        return 0
    fi

    local payload
    payload="$(jq -n --arg text "$message" '{"text": $text}')"

    curl -s -X POST "$webhook_url" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        >/dev/null 2>&1 || true
}
