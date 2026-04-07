#!/usr/bin/env bash
# core/notifications/telegram.sh — Telegram notification provider

# notify_telegram <message> <bot_token> <chat_id>
# Sends a message via Telegram Bot API. Silent on failure.
notify_telegram() {
    local message="$1"
    local bot_token="$2"
    local chat_id="$3"

    if [[ -z "$bot_token" || -z "$chat_id" ]]; then
        return 0
    fi

    curl -s -X POST \
        "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d chat_id="$chat_id" \
        -d text="$message" \
        >/dev/null 2>&1 || true
}
