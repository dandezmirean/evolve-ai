#!/usr/bin/env bash
# core/notifications/stdout.sh — stdout notification provider

# notify_stdout <message>
# Prints message to stdout with ISO timestamp prefix.
notify_stdout() {
    local message="$1"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $message"
}
