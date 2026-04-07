#!/usr/bin/env bash
# tests/test_pool.sh — tests for core/pool.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=core/pool.sh
source "$PROJECT_ROOT/core/pool.sh"

# ---------------------------------------------------------------------------
# test_pool_create_entry
# init pool, add entry, verify count=1 and status=pending
# ---------------------------------------------------------------------------
test_pool_create_entry() {
    echo "test_pool_create_entry"
    setup_test_env

    local pool_file="$TEST_TMPDIR/pool.json"
    pool_init "$pool_file"

    local entry='{"id":"abc1","status":"pending","description":"first entry"}'
    pool_add_entry "$pool_file" "$entry"

    local count
    count="$(pool_count "$pool_file")"
    assert_eq "1" "$count" "count is 1 after adding one entry"

    local status
    status="$(pool_get_status "$pool_file" "abc1")"
    assert_eq "pending" "$status" "status is pending after add"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_pool_status_transition
# add entry, transition pending→implemented→landed, verify each
# ---------------------------------------------------------------------------
test_pool_status_transition() {
    echo "test_pool_status_transition"
    setup_test_env

    local pool_file="$TEST_TMPDIR/pool.json"
    pool_init "$pool_file"
    pool_add_entry "$pool_file" '{"id":"e1","status":"pending"}'

    assert_eq "pending" "$(pool_get_status "$pool_file" "e1")" "initial status is pending"

    pool_set_status "$pool_file" "e1" "implemented"
    assert_eq "implemented" "$(pool_get_status "$pool_file" "e1")" "status is implemented after transition"

    pool_set_status "$pool_file" "e1" "landed"
    assert_eq "landed" "$(pool_get_status "$pool_file" "e1")" "status is landed after transition"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_pool_is_settled
# pool with all landed/reverted = settled; add a pending entry = not settled
# ---------------------------------------------------------------------------
test_pool_is_settled() {
    echo "test_pool_is_settled"
    setup_test_env

    local pool_file="$TEST_TMPDIR/pool.json"
    pool_init "$pool_file"

    # Empty pool is settled (vacuously all entries are terminal)
    assert_exit_code 0 "empty pool is settled" pool_is_settled "$pool_file"

    pool_add_entry "$pool_file" '{"id":"e1","status":"landed"}'
    pool_add_entry "$pool_file" '{"id":"e2","status":"reverted"}'
    pool_add_entry "$pool_file" '{"id":"e3","status":"killed"}'
    pool_add_entry "$pool_file" '{"id":"e4","status":"landed-pending-kpi"}'

    assert_exit_code 0 "all terminal entries = settled" pool_is_settled "$pool_file"

    pool_add_entry "$pool_file" '{"id":"e5","status":"pending"}'

    assert_exit_code 1 "pending entry = not settled" pool_is_settled "$pool_file"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_pool_status_hash
# same state = same hash; change status = different hash
# ---------------------------------------------------------------------------
test_pool_status_hash() {
    echo "test_pool_status_hash"
    setup_test_env

    local pool_file="$TEST_TMPDIR/pool.json"
    pool_init "$pool_file"
    pool_add_entry "$pool_file" '{"id":"e1","status":"pending"}'
    pool_add_entry "$pool_file" '{"id":"e2","status":"implemented"}'

    local hash1 hash2
    hash1="$(pool_status_hash "$pool_file")"
    hash2="$(pool_status_hash "$pool_file")"
    assert_eq "$hash1" "$hash2" "same state produces same hash"

    pool_set_status "$pool_file" "e1" "landed"
    local hash3
    hash3="$(pool_status_hash "$pool_file")"
    local different=0
    [[ "$hash1" != "$hash3" ]] && different=1
    assert_eq "1" "$different" "changed status produces different hash"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_pool_get_by_status
# add 3 entries (2 pending, 1 landed), verify get_ids_by_status("pending") returns exactly 2
# ---------------------------------------------------------------------------
test_pool_get_by_status() {
    echo "test_pool_get_by_status"
    setup_test_env

    local pool_file="$TEST_TMPDIR/pool.json"
    pool_init "$pool_file"
    pool_add_entry "$pool_file" '{"id":"p1","status":"pending"}'
    pool_add_entry "$pool_file" '{"id":"p2","status":"pending"}'
    pool_add_entry "$pool_file" '{"id":"l1","status":"landed"}'

    local ids
    ids="$(pool_get_ids_by_status "$pool_file" "pending")"

    # Should contain both pending IDs
    assert_contains "$ids" "p1" "pending ids contains p1"
    assert_contains "$ids" "p2" "pending ids contains p2"

    # Should NOT contain the landed ID
    local has_l1=0
    [[ "$ids" == *"l1"* ]] && has_l1=1
    assert_eq "0" "$has_l1" "pending ids does not contain l1"

    # Exactly 2 IDs returned
    local count
    count="$(printf '%s\n' "$ids" | grep -c '.')"
    assert_eq "2" "$count" "exactly 2 pending ids returned"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_pool_create_entry
test_pool_status_transition
test_pool_is_settled
test_pool_status_hash
test_pool_get_by_status

report_results
