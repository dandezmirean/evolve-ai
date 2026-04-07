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

    # Second acquire must fail (return 1) because PID $$ is alive
    acquire_lock "$lock_file"
    local second_rc=$?
    assert_eq "1" "$second_rc" "second acquire returns 1 while first is held"

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
    local dead_pid=99999999

    # Write a stale lock manually
    echo "$dead_pid" > "$lock_file"

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
# Run all tests
# -----------------------------------------------------------------------
test_acquire_and_release
test_lock_blocks_second_acquire
test_stale_lock_cleanup

report_results
