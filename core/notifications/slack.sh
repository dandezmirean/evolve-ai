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

    curl -s -X POST "$webhook_url" \
        -H 'Content-Type: application/json' \
        -d "{\"text\": \"$message\"}" \
        >/dev/null 2>&1 || true
}
