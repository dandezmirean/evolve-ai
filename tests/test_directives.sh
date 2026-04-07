#!/usr/bin/env bash
# tests/test_directives.sh — tests for core/directives/manager.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=core/directives/manager.sh
source "$PROJECT_ROOT/core/directives/manager.sh"

# ---------------------------------------------------------------------------
# test 1: directive_create writes valid YAML with correct fields
# ---------------------------------------------------------------------------
test_directive_create_valid_yaml() {
    echo "test_directive_create_valid_yaml"
    setup_test_env

    local directives_dir="$TEST_TMPDIR/directives"
    local result
    result="$(directive_create "$directives_dir" "lock" "src/auth/login.sh" "Do not modify auth login" "human-resume" "null")"

    assert_file_exists "$result" "directive file was created"

    local content
    content="$(cat "$result")"
    assert_contains "$content" "type: 'lock'" "contains type field"
    assert_contains "$content" "target: 'src/auth/login.sh'" "contains target field"
    assert_contains "$content" "rule: 'Do not modify auth login'" "contains rule field"
    assert_contains "$content" "source: 'human-resume'" "contains source field"
    assert_contains "$content" "expires: null" "contains null expires"
    assert_contains "$content" "created:" "contains created timestamp"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test 2: directive_create generates correct filename
# ---------------------------------------------------------------------------
test_directive_create_filename() {
    echo "test_directive_create_filename"
    setup_test_env

    local directives_dir="$TEST_TMPDIR/directives"
    local result
    result="$(directive_create "$directives_dir" "lock" "src/auth/*" "Lock auth directory" "test" "null")"

    local filename
    filename="$(basename "$result")"
    assert_eq "lock-src-auth.yaml" "$filename" "filename is sanitized from type-target"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test 3: directive_list shows active directives only (not expired)
# ---------------------------------------------------------------------------
test_directive_list_active_only() {
    echo "test_directive_list_active_only"
    setup_test_env

    local directives_dir="$TEST_TMPDIR/directives"
    mkdir -p "$directives_dir"

    # Create an active directive (no expiry)
    directive_create "$directives_dir" "lock" "src/core.sh" "Active lock" "test" "null" >/dev/null

    # Create an expired directive
    cat > "$directives_dir/constraint-old-rule.yaml" <<'EOF'
type: "constraint"
target: "old-rule"
rule: "Expired constraint"
created: "2025-01-01T00:00:00Z"
source: "test"
expires: "2025-01-02"
EOF

    local output
    output="$(directive_list "$directives_dir")"

    assert_contains "$output" "Active lock" "shows active directive"

    # The expired one should NOT appear
    local has_expired=0
    [[ "$output" == *"Expired constraint"* ]] && has_expired=1
    assert_eq "0" "$has_expired" "does not show expired directive"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test 4: directive_check_lock returns 0 for locked path
# ---------------------------------------------------------------------------
test_directive_check_lock_locked() {
    echo "test_directive_check_lock_locked"
    setup_test_env

    local directives_dir="$TEST_TMPDIR/directives"
    directive_create "$directives_dir" "lock" "src/auth/login.sh" "Locked file" "test" "null" >/dev/null

    assert_exit_code 0 "exact path match returns locked" directive_check_lock "$directives_dir" "src/auth/login.sh"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test 5: directive_check_lock returns 1 for unlocked path
# ---------------------------------------------------------------------------
test_directive_check_lock_unlocked() {
    echo "test_directive_check_lock_unlocked"
    setup_test_env

    local directives_dir="$TEST_TMPDIR/directives"
    directive_create "$directives_dir" "lock" "src/auth/login.sh" "Locked file" "test" "null" >/dev/null

    assert_exit_code 1 "non-matching path returns unlocked" directive_check_lock "$directives_dir" "src/utils/helper.sh"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test 6: directive_check_lock handles glob patterns
# ---------------------------------------------------------------------------
test_directive_check_lock_glob() {
    echo "test_directive_check_lock_glob"
    setup_test_env

    local directives_dir="$TEST_TMPDIR/directives"
    directive_create "$directives_dir" "lock" "src/auth/*" "Lock auth directory" "test" "null" >/dev/null

    assert_exit_code 0 "glob src/auth/* matches src/auth/login.sh" directive_check_lock "$directives_dir" "src/auth/login.sh"
    assert_exit_code 0 "glob src/auth/* matches src/auth/session.sh" directive_check_lock "$directives_dir" "src/auth/session.sh"
    assert_exit_code 1 "glob src/auth/* does not match src/utils/foo.sh" directive_check_lock "$directives_dir" "src/utils/foo.sh"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test 7: directive_check_override returns verdict for matching change ID
# ---------------------------------------------------------------------------
test_directive_check_override() {
    echo "test_directive_check_override"
    setup_test_env

    local directives_dir="$TEST_TMPDIR/directives"
    directive_create "$directives_dir" "override" "chg-042" "force-land" "human-resume" "null" >/dev/null

    local verdict
    verdict="$(directive_check_override "$directives_dir" "chg-042")"
    assert_eq "force-land" "$verdict" "returns forced verdict for matching change"

    local no_verdict
    no_verdict="$(directive_check_override "$directives_dir" "chg-999")"
    assert_eq "" "$no_verdict" "returns empty for non-matching change"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test 8: directive_cleanup_expired removes old directives
# ---------------------------------------------------------------------------
test_directive_cleanup_expired() {
    echo "test_directive_cleanup_expired"
    setup_test_env

    local directives_dir="$TEST_TMPDIR/directives"
    mkdir -p "$directives_dir"

    # Active directive (no expiry)
    directive_create "$directives_dir" "lock" "keep-this" "Active" "test" "null" >/dev/null

    # Expired directive
    cat > "$directives_dir/constraint-remove-this.yaml" <<'EOF'
type: "constraint"
target: "remove-this"
rule: "Should be cleaned up"
created: "2025-01-01T00:00:00Z"
source: "test"
expires: "2025-01-02"
EOF

    # Another expired directive
    cat > "$directives_dir/lock-also-expired.yaml" <<'EOF'
type: "lock"
target: "also-expired"
rule: "Should also be cleaned"
created: "2025-06-01T00:00:00Z"
source: "test"
expires: "2025-06-02"
EOF

    local cleaned
    cleaned="$(directive_cleanup_expired "$directives_dir")"
    assert_eq "2" "$cleaned" "removes 2 expired directives"

    # Active one should remain
    assert_file_exists "$directives_dir/lock-keep-this.yaml" "active directive still exists"

    # Expired ones should be gone
    local expired_exists=0
    [[ -f "$directives_dir/constraint-remove-this.yaml" ]] && expired_exists=1
    assert_eq "0" "$expired_exists" "expired constraint was removed"

    local expired2_exists=0
    [[ -f "$directives_dir/lock-also-expired.yaml" ]] && expired2_exists=1
    assert_eq "0" "$expired2_exists" "expired lock was removed"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_directive_create_valid_yaml
test_directive_create_filename
test_directive_list_active_only
test_directive_check_lock_locked
test_directive_check_lock_unlocked
test_directive_check_lock_glob
test_directive_check_override
test_directive_cleanup_expired

report_results
