#!/usr/bin/env bash
# tests/test_lock.sh — tests for core/lock.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/../core/lock.sh"

# -----------------------------------------------------------------------
# test_acquire_and_release
# acquire creates file with current PID; release removes it
# -----------------------------------------------------------------------
test_acquire_and_release() {
    echo "test_acquire_and_release"
    setup_test_env

    local lock_file="$TEST_TMPDIR/test.lock"

    acquire_lock "$lock_file"
    assert_file_exists "$lock_file" "lock file created after acquire"

    local stored_pid
    stored_pid="$(lock_owner_pid "$lock_file")"
    assert_eq "$$" "$stored_pid" "lock file contains current PID"

    release_lock "$lock_file"
    local exists=0
    [[ -f "$lock_file" ]] && exists=1
    assert_eq "0" "$exists" "lock file removed after release"

    teardown_test_env
}

# -----------------------------------------------------------------------
# test_lock_blocks_second_acquire
# second acquire while first is held returns exit code 1
# -----------------------------------------------------------------------
test_lock_blocks_second_acquire() {
    echo "test_lock_blocks_second_acquire"
    setup_test_env

    local lock_file="$TEST_TMPDIR/test.lock"

    acquire_lock "$lock_file"

    # Second acquire from a SUBSHELL must fail because flock is held by parent
    local second_rc=0
    (
        exec 9>"$lock_file"
        flock -n 9 && exit 0 || exit 1
    ) || second_rc=$?

    assert_eq "1" "$second_rc" "second acquire from subshell returns 1 while first is held"

    release_lock "$lock_file"
    teardown_test_env
}

# -----------------------------------------------------------------------
# test_stale_lock_cleanup
# a lock file containing a nonexistent PID is treated as stale;
# acquire succeeds and replaces the PID with the current one
# -----------------------------------------------------------------------
test_stale_lock_cleanup() {
    echo "test_stale_lock_cleanup"
    setup_test_env

    local lock_file="$TEST_TMPDIR/test.lock"

    # Write a stale lock file (no flock held — simulates dead process)
    echo "99999999 $(date +%s)" > "$lock_file"

    # acquire should succeed because no flock is actually held
    acquire_lock "$lock_file"
    local rc=$?
    assert_eq "0" "$rc" "acquire succeeds over stale lock"

    local stored_pid
    stored_pid="$(lock_owner_pid "$lock_file")"
    assert_eq "$$" "$stored_pid" "stale PID replaced with current PID"

    release_lock "$lock_file"
    teardown_test_env
}

# -----------------------------------------------------------------------
# test_lock_file_contains_timestamp
# lock file written by acquire_lock has two fields: PID and timestamp
# -----------------------------------------------------------------------
test_lock_file_contains_timestamp() {
    echo "test_lock_file_contains_timestamp"
    setup_test_env

    local lock_file="$TEST_TMPDIR/test.lock"
    echo "$$ $(date +%s)" > "$lock_file"
    local parts
    parts=$(wc -w < "$lock_file")
    assert_eq "2" "$parts" "lock file contains PID and timestamp"

    teardown_test_env
}

# -----------------------------------------------------------------------
# test_lock_is_stale_old_lock
# lock_is_stale returns true (exit 0) when timestamp exceeds max_age
# -----------------------------------------------------------------------
test_lock_is_stale_old_lock() {
    echo "test_lock_is_stale_old_lock"
    setup_test_env

    local lock_file="$TEST_TMPDIR/test.lock"
    local old_ts=$(( $(date +%s) - 8000 ))
    echo "99999 $old_ts" > "$lock_file"

    lock_is_stale "$lock_file" 7200
    assert_eq "0" "$?" "lock_is_stale returns true for old lock"

    teardown_test_env
}

# -----------------------------------------------------------------------
# test_lock_is_stale_fresh_lock
# lock_is_stale returns false (exit 1) for a recently written lock
# -----------------------------------------------------------------------
test_lock_is_stale_fresh_lock() {
    echo "test_lock_is_stale_fresh_lock"
    setup_test_env

    local lock_file="$TEST_TMPDIR/test.lock"
    echo "99999 $(date +%s)" > "$lock_file"

    lock_is_stale "$lock_file" 7200
    assert_eq "1" "$?" "lock_is_stale returns false for recent lock"

    teardown_test_env
}

# -----------------------------------------------------------------------
# Run all tests
# -----------------------------------------------------------------------
test_acquire_and_release
test_lock_blocks_second_acquire
test_stale_lock_cleanup
test_lock_file_contains_timestamp
test_lock_is_stale_old_lock
test_lock_is_stale_fresh_lock

report_results
