#!/usr/bin/env bash
# core/lock.sh — global lock management with PID-based stale detection

EVOLVE_DEFAULT_LOCK="/tmp/evolve-ai.lock"

# acquire_lock [lock_file]
# Creates lock file with current PID.
# Returns 1 if locked by a live process, 0 on success.
acquire_lock() {
    local lock_file="${1:-$EVOLVE_DEFAULT_LOCK}"

    if [[ -f "$lock_file" ]]; then
        local existing_pid
        existing_pid="$(cat "$lock_file" 2>/dev/null)"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            # Lock held by a live process
            return 1
        fi
        # Stale lock — remove it
        rm -f "$lock_file"
    fi

    echo "$$" > "$lock_file"
    return 0
}

# release_lock [lock_file]
# Removes the lock file.
release_lock() {
    local lock_file="${1:-$EVOLVE_DEFAULT_LOCK}"
    rm -f "$lock_file"
}

# is_locked [lock_file]
# Returns 0 if locked by a live process, 1 otherwise.
is_locked() {
    local lock_file="${1:-$EVOLVE_DEFAULT_LOCK}"

    if [[ ! -f "$lock_file" ]]; then
        return 1
    fi

    local existing_pid
    existing_pid="$(cat "$lock_file" 2>/dev/null)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
        return 0
    fi

    return 1
}

# lock_owner_pid [lock_file]
# Outputs the PID stored in the lock file.
lock_owner_pid() {
    local lock_file="${1:-$EVOLVE_DEFAULT_LOCK}"
    cat "$lock_file" 2>/dev/null
}
