#!/usr/bin/env bash
# tests/test_orchestrator.sh — tests for core/orchestrator.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=core/orchestrator.sh
source "$PROJECT_ROOT/core/orchestrator.sh"

# ---------------------------------------------------------------------------
# test_workspace_creation
# create_workspace creates the directory and initialises pool.json inside it
# ---------------------------------------------------------------------------
test_workspace_creation() {
    echo "test_workspace_creation"
    setup_test_env

    local ws
    ws="$(create_workspace "$TEST_TMPDIR")"

    # Directory must exist
    local dir_exists=0
    [[ -d "$ws" ]] && dir_exists=1
    assert_eq "1" "$dir_exists" "workspace directory was created"

    # pool.json must exist inside it
    assert_file_exists "$ws/pool.json" "pool.json initialised in workspace"

    # pool.json must be an empty JSON array
    local contents
    contents="$(cat "$ws/pool.json")"
    assert_eq "[]" "$contents" "pool.json contains empty array"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_convergence_detection
# A pool where all entries are in terminal states returns 0 (converged)
# ---------------------------------------------------------------------------
test_convergence_detection() {
    echo "test_convergence_detection"
    setup_test_env

    local pool_file="$TEST_TMPDIR/pool.json"
    pool_init "$pool_file"

    # Add entries in all terminal states
    pool_add_entry "$pool_file" '{"id":"e1","status":"landed"}'
    pool_add_entry "$pool_file" '{"id":"e2","status":"reverted"}'
    pool_add_entry "$pool_file" '{"id":"e3","status":"killed"}'
    pool_add_entry "$pool_file" '{"id":"e4","status":"landed-pending-kpi"}'

    # check_convergence with no prev_hash — all settled => return 0
    check_convergence "$pool_file"
    local rc=$?
    assert_eq "0" "$rc" "settled pool returns 0 (converged)"

    # Empty pool also converges
    local empty_pool="$TEST_TMPDIR/empty_pool.json"
    pool_init "$empty_pool"
    check_convergence "$empty_pool"
    local empty_rc=$?
    assert_eq "0" "$empty_rc" "empty pool returns 0 (converged)"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_stall_detection
# Pool with active entries and same prev_hash returns 1 (not converged / stalled)
# ---------------------------------------------------------------------------
test_stall_detection() {
    echo "test_stall_detection"
    setup_test_env

    local pool_file="$TEST_TMPDIR/pool.json"
    pool_init "$pool_file"

    # Add a non-terminal entry so pool is NOT settled
    pool_add_entry "$pool_file" '{"id":"e1","status":"pending"}'
    pool_add_entry "$pool_file" '{"id":"e2","status":"implemented"}'

    # Compute current hash and pass it back as prev_hash — this simulates a stall
    local current_hash
    current_hash="$(pool_status_hash "$pool_file")"

    check_convergence "$pool_file" "$current_hash"
    local rc=$?
    assert_eq "1" "$rc" "active pool with same prev_hash returns 1 (stalled, not converged)"

    # Verify that changing a status breaks the stall (hash changes, still returns 1
    # because pool is not settled, but the hash mismatch case is handled)
    pool_set_status "$pool_file" "e1" "landed"
    local new_hash
    new_hash="$(pool_status_hash "$pool_file")"

    local hash_changed=0
    [[ "$new_hash" != "$current_hash" ]] && hash_changed=1
    assert_eq "1" "$hash_changed" "hash changes after status update (stall broken)"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_workspace_creation
test_convergence_detection
test_stall_detection

report_results
