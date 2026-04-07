#!/usr/bin/env bash
# core/notifications/engine.sh — Main notification router for evolve-ai

_NOTIF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_NOTIF_CORE_DIR="$(cd "$_NOTIF_DIR/.." && pwd)"

# Source config and all notification providers
source "$_NOTIF_CORE_DIR/config.sh"
source "$_NOTIF_DIR/stdout.sh"
source "$_NOTIF_DIR/telegram.sh"
source "$_NOTIF_DIR/slack.sh"
source "$_NOTIF_DIR/discord.sh"

# Internal array of notification entries parsed from config.
# Each entry is stored as "type|param1|param2" in _NOTIFICATION_ENTRIES.
_NOTIFICATION_ENTRIES=()

# load_notification_config <config_file>
# Parses the notifications array from an evolve.yaml config file.
# Populates _NOTIFICATION_ENTRIES with parsed provider entries.
# Falls back to stdout if no notifications section is found.
load_notification_config() {
    local config_file="$1"

    _NOTIFICATION_ENTRIES=()

    if [[ ! -f "$config_file" ]]; then
        # Default to stdout if no config file
        _NOTIFICATION_ENTRIES+=("stdout||")
        return 0
    fi

    # Parse notification entries from YAML.
    # We look for lines under "notifications:" that start with "- type:"
    # and subsequent indented lines for parameters (bot_token, chat_id, webhook_url).
    local in_notifications=0
    local current_type=""
    local current_param1=""
    local current_param2=""

    while IFS= read -r line; do
        # Strip trailing whitespace / carriage returns
        line="${line%"${line##*[![:space:]]}"}"

        # Detect notifications section
        if [[ "$line" =~ ^notifications: ]]; then
            in_notifications=1
            continue
        fi

        # If we hit a new top-level section, stop parsing notifications
        if [[ $in_notifications -eq 1 && "$line" =~ ^[a-zA-Z] && ! "$line" =~ ^[[:space:]] ]]; then
            # Save any pending entry before leaving the section
            if [[ -n "$current_type" ]]; then
                _NOTIFICATION_ENTRIES+=("${current_type}|${current_param1}|${current_param2}")
            fi
            in_notifications=0
            break
        fi

        if [[ $in_notifications -eq 0 ]]; then
            continue
        fi

        # Skip blank lines and comments
        local stripped="${line#"${line%%[![:space:]]*}"}"
        if [[ -z "$stripped" || "$stripped" == \#* ]]; then
            continue
        fi

        # New list item: "  - type: xxx"
        if [[ "$stripped" =~ ^-[[:space:]]+type:[[:space:]]*(.+) ]]; then
            # Save previous entry if any
            if [[ -n "$current_type" ]]; then
                _NOTIFICATION_ENTRIES+=("${current_type}|${current_param1}|${current_param2}")
            fi
            current_type="${BASH_REMATCH[1]}"
            # Strip quotes
            current_type="${current_type%\"}"
            current_type="${current_type#\"}"
            current_type="${current_type%\'}"
            current_type="${current_type#\'}"
            current_param1=""
            current_param2=""
            continue
        fi

        # Continuation lines for the current entry
        if [[ -n "$current_type" ]]; then
            # bot_token
            if [[ "$stripped" =~ ^bot_token:[[:space:]]*(.+) ]]; then
                current_param1="${BASH_REMATCH[1]}"
                current_param1="${current_param1%\"}"
                current_param1="${current_param1#\"}"
                current_param1="${current_param1%\'}"
                current_param1="${current_param1#\'}"
            fi
            # chat_id
            if [[ "$stripped" =~ ^chat_id:[[:space:]]*(.+) ]]; then
                current_param2="${BASH_REMATCH[1]}"
                current_param2="${current_param2%\"}"
                current_param2="${current_param2#\"}"
                current_param2="${current_param2%\'}"
                current_param2="${current_param2#\'}"
            fi
            # webhook_url (used by slack and discord)
            if [[ "$stripped" =~ ^webhook_url:[[:space:]]*(.+) ]]; then
                current_param1="${BASH_REMATCH[1]}"
                current_param1="${current_param1%\"}"
                current_param1="${current_param1#\"}"
                current_param1="${current_param1%\'}"
                current_param1="${current_param1#\'}"
            fi
        fi
    done < "$config_file"

    # Save final entry if file ended inside notifications section
    if [[ $in_notifications -eq 1 && -n "$current_type" ]]; then
        _NOTIFICATION_ENTRIES+=("${current_type}|${current_param1}|${current_param2}")
    fi

    # Default to stdout if nothing was parsed
    if [[ ${#_NOTIFICATION_ENTRIES[@]} -eq 0 ]]; then
        _NOTIFICATION_ENTRIES+=("stdout||")
    fi
}

# notify <message>
# Routes a message to all configured notification providers.
# Config must be loaded first via load_notification_config.
# If no config was loaded, defaults to stdout.
notify() {
    local message="$1"

    # If no entries loaded, default to stdout
    if [[ ${#_NOTIFICATION_ENTRIES[@]} -eq 0 ]]; then
        notify_stdout "$message"
        return 0
    fi

    local entry
    for entry in "${_NOTIFICATION_ENTRIES[@]}"; do
        local ntype param1 param2
        IFS='|' read -r ntype param1 param2 <<< "$entry"

        case "$ntype" in
            stdout)
                notify_stdout "$message"
                ;;
            telegram)
                notify_telegram "$message" "$param1" "$param2"
                ;;
            slack)
                notify_slack "$message" "$param1"
                ;;
            discord)
                notify_discord "$message" "$param1"
                ;;
            *)
                echo "[notifications] Unknown provider type: $ntype" >&2
                ;;
        esac
    done
}
