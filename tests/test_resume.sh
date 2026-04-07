#!/usr/bin/env bash
# tests/test_resume.sh — tests for core/resume/context-generator.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=core/resume/context-generator.sh
source "$PROJECT_ROOT/core/resume/context-generator.sh"
# shellcheck source=core/resume/resume-runner.sh
source "$PROJECT_ROOT/core/resume/resume-runner.sh"

# ---------------------------------------------------------------------------
# Helper: create a test workspace with a populated pool
# ---------------------------------------------------------------------------
_create_test_workspace() {
    local ws_date="${1:-2026-04-06}"
    local workspace="$TEST_TMPDIR/workspace/$ws_date"
    mkdir -p "$workspace"

    local pool_file="$workspace/pool.json"
    pool_init "$pool_file"

    # Add a landed entry
    pool_add_entry "$pool_file" '{
        "id": "chg-001",
        "status": "landed",
        "title": "Add retry logic",
        "description": "Implement exponential backoff for API calls",
        "history": [
            {"timestamp": "2026-04-06T10:00:00Z", "event": "created", "detail": "Proposed by strategize phase"},
            {"timestamp": "2026-04-06T12:00:00Z", "event": "landed", "detail": "Passed all validations and was merged"}
        ]
    }'

    # Add a killed entry
    pool_add_entry "$pool_file" '{
        "id": "chg-002",
        "status": "killed",
        "title": "Rewrite logging subsystem",
        "description": "Complete rewrite of logging to use structured format",
        "history": [
            {"timestamp": "2026-04-06T10:00:00Z", "event": "created", "detail": "Proposed by strategize phase"},
            {"timestamp": "2026-04-06T11:00:00Z", "event": "killed", "detail": "Too risky — affects 12 files with no rollback path"}
        ]
    }'

    # Add a reverted entry
    pool_add_entry "$pool_file" '{
        "id": "chg-003",
        "status": "reverted",
        "title": "Optimize query cache",
        "description": "Cache frequently used database queries",
        "history": [
            {"timestamp": "2026-04-06T10:00:00Z", "event": "created", "detail": "Proposed by strategize phase"},
            {"timestamp": "2026-04-06T13:00:00Z", "event": "reverted", "detail": "Caused memory spike in production"}
        ]
    }'

    # Add a pending entry (should NOT be picked up by generate_all)
    pool_add_entry "$pool_file" '{
        "id": "chg-004",
        "status": "pending",
        "title": "Future work",
        "description": "Something still in progress"
    }'

    printf '%s' "$workspace"
}

# ---------------------------------------------------------------------------
# test 1: generate_resume_context creates correct file for "landed"
# ---------------------------------------------------------------------------
test_generate_context_landed() {
    echo "test_generate_context_landed"
    setup_test_env

    local workspace
    workspace="$(_create_test_workspace "2026-04-06")"

    local result
    result="$(generate_resume_context "$TEST_TMPDIR" "$workspace" "chg-001" "landed")"

    # File should exist
    assert_file_exists "$result" "landed context file exists"

    # Check file path structure
    assert_contains "$result" "resume-context/2026-04-06/chg-001-landed.md" "file path contains expected structure"

    # Check contents
    local content
    content="$(cat "$result")"
    assert_contains "$content" "# Resume Context: chg-001" "contains header"
    assert_contains "$content" "was landed" "contains decision type"
    assert_contains "$content" "Add retry logic" "contains title from pool entry"
    assert_contains "$content" "Pool Entry Snapshot" "contains pool snapshot section"
    assert_contains "$content" "Available Actions" "contains available actions"
    assert_contains "$content" "Override" "lists override action"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test 2: generate_resume_context creates correct file for "killed"
# ---------------------------------------------------------------------------
test_generate_context_killed() {
    echo "test_generate_context_killed"
    setup_test_env

    local workspace
    workspace="$(_create_test_workspace "2026-04-06")"

    local result
    result="$(generate_resume_context "$TEST_TMPDIR" "$workspace" "chg-002" "killed")"

    assert_file_exists "$result" "killed context file exists"
    assert_contains "$result" "chg-002-killed.md" "filename contains killed suffix"

    local content
    content="$(cat "$result")"
    assert_contains "$content" "was killed" "contains killed decision"
    assert_contains "$content" "Rewrite logging subsystem" "contains title"
    assert_contains "$content" "Too risky" "contains decision summary from history"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test 3: generate_all_resume_contexts processes all settled entries
# ---------------------------------------------------------------------------
test_generate_all_contexts() {
    echo "test_generate_all_contexts"
    setup_test_env

    local workspace
    workspace="$(_create_test_workspace "2026-04-06")"
    local pool_file="$workspace/pool.json"

    local count
    count="$(generate_all_resume_contexts "$TEST_TMPDIR" "$workspace" "$pool_file")"

    # Should generate 3 contexts: 1 landed + 1 killed + 1 reverted
    # (chg-004 is pending, should be skipped)
    assert_eq "3" "$count" "generates context for all 3 settled entries"

    # Verify all files exist
    assert_file_exists "$TEST_TMPDIR/resume-context/2026-04-06/chg-001-landed.md" "landed context file"
    assert_file_exists "$TEST_TMPDIR/resume-context/2026-04-06/chg-002-killed.md" "killed context file"
    assert_file_exists "$TEST_TMPDIR/resume-context/2026-04-06/chg-003-reverted.md" "reverted context file"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test 4: list_resume_contexts returns contexts sorted newest first
# ---------------------------------------------------------------------------
test_list_contexts_sorted() {
    echo "test_list_contexts_sorted"
    setup_test_env

    # Create contexts for two different dates
    local ws1
    ws1="$(_create_test_workspace "2026-04-05")"
    generate_resume_context "$TEST_TMPDIR" "$ws1" "chg-001" "landed" >/dev/null

    local ws2_dir="$TEST_TMPDIR/workspace/2026-04-06"
    mkdir -p "$ws2_dir"
    local pf2="$ws2_dir/pool.json"
    pool_init "$pf2"
    pool_add_entry "$pf2" '{"id":"chg-010","status":"killed","title":"Newer change","description":"A newer killed change"}'
    generate_resume_context "$TEST_TMPDIR" "$ws2_dir" "chg-010" "killed" >/dev/null

    local output
    output="$(list_resume_contexts "$TEST_TMPDIR")"

    # Should show 2026-04-06 before 2026-04-05 (newest first)
    local line_06 line_05
    line_06="$(echo "$output" | grep -n "2026-04-06" | head -1 | cut -d: -f1)"
    line_05="$(echo "$output" | grep -n "2026-04-05" | head -1 | cut -d: -f1)"

    local newer_first=0
    if [[ -n "$line_06" && -n "$line_05" ]] && (( line_06 < line_05 )); then
        newer_first=1
    fi
    assert_eq "1" "$newer_first" "2026-04-06 appears before 2026-04-05"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test 5: generate_circuit_breaker_context creates the special context file
# ---------------------------------------------------------------------------
test_circuit_breaker_context() {
    echo "test_circuit_breaker_context"
    setup_test_env

    local workspace
    workspace="$(_create_test_workspace "2026-04-06")"

    # Create a trip marker
    echo "Tripped at 2026-04-06T14:00:00Z — 3 negative impacts in 24h" > "$TEST_TMPDIR/circuit-breaker.trip"

    local result
    result="$(generate_circuit_breaker_context "$TEST_TMPDIR" "$workspace")"

    assert_file_exists "$result" "circuit breaker context file exists"

    local content
    content="$(cat "$result")"
    assert_contains "$content" "Circuit Breaker Trip" "contains circuit breaker header"
    assert_contains "$content" "Tripped at" "contains trip information"
    assert_contains "$content" "Negative Impacts" "contains negative impacts section"
    assert_contains "$content" "Available Actions" "contains available actions"
    assert_contains "$content" "Reset" "lists reset action"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_generate_context_landed
test_generate_context_killed
test_generate_all_contexts
test_list_contexts_sorted
test_circuit_breaker_context

report_results
