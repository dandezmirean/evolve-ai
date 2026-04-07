#!/usr/bin/env bash
# core/lock.sh — global lock management with flock-based atomic locking

EVOLVE_DEFAULT_LOCK="${EVOLVE_ROOT:-.}/.evolve-lock"
EVOLVE_LOCK_FD=9

# acquire_lock [lock_file]
# Uses flock for atomic lock acquisition. Writes PID + timestamp for diagnostics.
# Returns 1 if locked by another process, 0 on success.
acquire_lock() {
    local lock_file="${1:-$EVOLVE_DEFAULT_LOCK}"

    # Open FD for locking (create file if needed)
    eval "exec ${EVOLVE_LOCK_FD}>\"$lock_file\""

    if ! flock -n "$EVOLVE_LOCK_FD"; then
        return 1
    fi

    # Write PID + timestamp for diagnostics
    echo "$$ $(date +%s)" >&${EVOLVE_LOCK_FD}

    return 0
}

# release_lock [lock_file]
# Releases the flock and removes the lock file.
release_lock() {
    local lock_file="${1:-$EVOLVE_DEFAULT_LOCK}"
    flock -u "$EVOLVE_LOCK_FD" 2>/dev/null || true
    eval "exec ${EVOLVE_LOCK_FD}>&-" 2>/dev/null || true
    rm -f "$lock_file"
}

# is_locked [lock_file]
# Returns 0 if locked by a live process, 1 otherwise.
is_locked() {
    local lock_file="${1:-$EVOLVE_DEFAULT_LOCK}"

    if [[ ! -f "$lock_file" ]]; then
        return 1
    fi

    # Try to acquire on a different FD to test
    local test_result
    (
        exec 8>"$lock_file"
        flock -n 8 && exit 0 || exit 1
    )
    test_result=$?

    if [[ $test_result -eq 0 ]]; then
        return 1  # NOT locked (we could acquire)
    else
        return 0  # locked
    fi
}

# lock_owner_pid [lock_file]
# Outputs the PID stored in the lock file.
lock_owner_pid() {
    local lock_file="${1:-$EVOLVE_DEFAULT_LOCK}"
    awk '{print $1}' "$lock_file" 2>/dev/null
}

# lock_is_stale [lock_file] [max_age_seconds]
# Returns 0 (true) if the lock file exists and its timestamp is older than max_age.
lock_is_stale() {
    local lock_file="$1"
    local max_age="${2:-7200}"

    [ ! -f "$lock_file" ] && return 1

    local lock_ts
    lock_ts=$(awk '{print $2}' "$lock_file" 2>/dev/null || echo "")
    [ -z "$lock_ts" ] && return 1

    local now age
    now=$(date +%s)
    age=$((now - lock_ts))

    [ "$age" -gt "$max_age" ]
}
