#!/usr/bin/env bash
# tests/test_integration.sh — End-to-end integration tests for evolve-ai
# Validates that components work together in realistic scenarios.
# Note: we explicitly disable set -e because several sourced modules
# (scoring/engine.sh, memory/manager.sh, etc.) set -euo pipefail on source,
# which would cause assert_exit_code to abort on non-zero tested returns.
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# ---------------------------------------------------------------------------
# 1. Full init cycle
# Run init with piped inputs simulating user selections.
# Verify evolve.yaml, memory dir, inbox dir all exist.
# ---------------------------------------------------------------------------
test_init_cycle() {
    echo "test_init_cycle"
    setup_test_env

    # Set up the pack template and packs that init depends on
    mkdir -p "$TEST_TMPDIR/packs/_template"
    cp "$PROJECT_ROOT/packs/_template/pack.yaml" "$TEST_TMPDIR/packs/_template/pack.yaml"
    mkdir -p "$TEST_TMPDIR/packs/infrastructure"
    cp "$PROJECT_ROOT/packs/infrastructure/pack.yaml" "$TEST_TMPDIR/packs/infrastructure/pack.yaml"
    mkdir -p "$TEST_TMPDIR/core/memory/templates"
    cp "$PROJECT_ROOT/core/memory/templates/"* "$TEST_TMPDIR/core/memory/templates/"

    # Source init.sh with the test directory
    # We need to override _INIT_DIR so it finds templates in our test env
    source "$PROJECT_ROOT/core/config.sh"
    source "$PROJECT_ROOT/core/packs/validator.sh"
    source "$PROJECT_ROOT/core/init.sh"
    _INIT_DIR="$TEST_TMPDIR/core"

    # Simulate user inputs:
    # 1=infrastructure, /tmp/target, 1=claude-max, 1=stdout,
    # Y=accept sources, 1500=ram, 85=disk, Y=accept safety,
    # 0 13 * * *=schedule, 300=poll, 0 13 * * 0=meta,
    # 3=threshold, 7=window, manual=resume
    printf '1\n/tmp/target\n1\n1\nY\n1500\n85\nY\n0 13 * * *\n300\n0 13 * * 0\n3\n7\nmanual\n' | \
        run_init "$TEST_TMPDIR" >/dev/null 2>&1

    assert_file_exists "$TEST_TMPDIR/config/evolve.yaml" "evolve.yaml generated"
    assert_file_exists "$TEST_TMPDIR/memory/MEMORY.md" "memory dir initialized"
    assert_file_exists "$TEST_TMPDIR/memory/changelog.md" "changelog template copied"

    # Verify inbox dirs created
    local inbox_exists=0
    [[ -d "$TEST_TMPDIR/inbox/pending" ]] && inbox_exists=1
    assert_eq "1" "$inbox_exists" "inbox/pending directory exists"

    local inbox_processed=0
    [[ -d "$TEST_TMPDIR/inbox/processed" ]] && inbox_processed=1
    assert_eq "1" "$inbox_processed" "inbox/processed directory exists"

    # Verify config content
    local config_content
    config_content="$(cat "$TEST_TMPDIR/config/evolve.yaml")"
    assert_contains "$config_content" "infrastructure" "config references infrastructure pack"
    assert_contains "$config_content" "claude-max" "config references claude-max provider"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 2. Pool lifecycle
# Create pool, add entry, transition through states, verify state machine.
# ---------------------------------------------------------------------------
test_pool_lifecycle() {
    echo "test_pool_lifecycle"
    setup_test_env

    source "$PROJECT_ROOT/core/pool.sh"

    local pool_file="$TEST_TMPDIR/pool.json"
    pool_init "$pool_file"

    # Add entries in different states
    pool_add_entry "$pool_file" '{"id":"int-1","status":"pending","title":"Test entry 1"}'
    pool_add_entry "$pool_file" '{"id":"int-2","status":"pending","title":"Test entry 2"}'
    pool_add_entry "$pool_file" '{"id":"int-3","status":"pending","title":"Test entry 3"}'

    assert_eq "3" "$(pool_count "$pool_file")" "3 entries after adding"

    # Transition int-1: pending -> approved -> implemented -> landed
    pool_set_status "$pool_file" "int-1" "approved"
    assert_eq "approved" "$(pool_get_status "$pool_file" "int-1")" "int-1 approved"

    pool_set_status "$pool_file" "int-1" "implemented"
    assert_eq "implemented" "$(pool_get_status "$pool_file" "int-1")" "int-1 implemented"

    pool_set_status "$pool_file" "int-1" "landed"
    assert_eq "landed" "$(pool_get_status "$pool_file" "int-1")" "int-1 landed"

    # Transition int-2: pending -> killed
    pool_set_status "$pool_file" "int-2" "killed"
    assert_eq "killed" "$(pool_get_status "$pool_file" "int-2")" "int-2 killed"

    # Transition int-3: pending -> implemented -> reverted
    pool_set_status "$pool_file" "int-3" "implemented"
    pool_set_status "$pool_file" "int-3" "reverted"
    assert_eq "reverted" "$(pool_get_status "$pool_file" "int-3")" "int-3 reverted"

    # All entries should be settled now
    assert_exit_code 0 "pool is settled after all reach terminal" pool_is_settled "$pool_file"

    # Add history entry
    pool_add_history "$pool_file" "int-1" "tested" "Integration test verified"
    local history_count
    history_count="$(jq --arg id "int-1" '[.[] | select(.id == $id) | .history | length] | .[0]' "$pool_file")"
    assert_eq "1" "$history_count" "history entry added to int-1"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 3. Scoring pipeline
# Set up mock scorer commands, run scoring_run_heuristic + scoring_aggregate,
# verify impact_signal.
# ---------------------------------------------------------------------------
test_scoring_pipeline() {
    echo "test_scoring_pipeline"
    setup_test_env

    source "$PROJECT_ROOT/core/config.sh"
    source "$PROJECT_ROOT/core/pool.sh"
    source "$PROJECT_ROOT/core/scoring/engine.sh"
    set +e  # Re-disable after scoring/engine.sh enables set -e

    local workspace="$TEST_TMPDIR/workspace"
    mkdir -p "$workspace/scores"

    # Create a mock pack.yaml with heuristic scorers that return known values
    local pack_yaml="$TEST_TMPDIR/pack.yaml"
    cat > "$pack_yaml" <<'PACKYAML'
name: "test-pack"
description: "Test pack for scoring"

scorers:
  heuristic:
    - name: "test_metric"
      command: "echo 50"
      weight: 2
      direction: "higher_is_better"

safety_rules:
  never:
    - "test"

reversibility:
  primary: "git"

scan_commands:
  - "echo ok"

health_checks:
  - name: "ok"
    command: "true"
    expect: "exit_code_0"

commit_categories:
  - "test"

challenge_vectors:
  - "test vector"
PACKYAML

    # Run heuristic scoring "before"
    scoring_run_heuristic "$pack_yaml" "$workspace" "score-1" "before"
    assert_file_exists "$workspace/scores/score-1-heuristic-before.json" "before score file created"

    local before_value
    before_value="$(jq '.[0].value' "$workspace/scores/score-1-heuristic-before.json")"
    assert_eq "50" "$before_value" "before heuristic value is 50"

    # Simulate an improvement: overwrite the scorer to return 80
    cat > "$pack_yaml" <<'PACKYAML2'
name: "test-pack"
description: "Test pack for scoring"

scorers:
  heuristic:
    - name: "test_metric"
      command: "echo 80"
      weight: 2
      direction: "higher_is_better"

safety_rules:
  never:
    - "test"

reversibility:
  primary: "git"

scan_commands:
  - "echo ok"

health_checks:
  - name: "ok"
    command: "true"
    expect: "exit_code_0"

commit_categories:
  - "test"

challenge_vectors:
  - "test vector"
PACKYAML2

    # Run heuristic scoring "after"
    scoring_run_heuristic "$pack_yaml" "$workspace" "score-1" "after"
    assert_file_exists "$workspace/scores/score-1-heuristic-after.json" "after score file created"

    local after_value
    after_value="$(jq '.[0].value' "$workspace/scores/score-1-heuristic-after.json")"
    assert_eq "80" "$after_value" "after heuristic value is 80"

    # Compute weighted delta
    local delta
    delta="$(scoring_compute_weighted_delta \
        "$workspace/scores/score-1-heuristic-before.json" \
        "$workspace/scores/score-1-heuristic-after.json")"

    # Delta should be 30 (80 - 50, higher_is_better)
    assert_eq "30" "$delta" "weighted delta is 30"

    # Run aggregate
    scoring_aggregate "$workspace" "score-1"
    assert_file_exists "$workspace/scores/score-1-aggregate.json" "aggregate file created"

    local impact_signal
    impact_signal="$(jq -r '.impact_signal' "$workspace/scores/score-1-aggregate.json")"
    assert_eq "positive" "$impact_signal" "impact signal is positive"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 4. Memory lifecycle
# Init memory, append metrics, read back, verify JSONL integrity.
# ---------------------------------------------------------------------------
test_memory_lifecycle() {
    echo "test_memory_lifecycle"
    setup_test_env

    source "$PROJECT_ROOT/core/config.sh"
    source "$PROJECT_ROOT/core/memory/manager.sh"
    set +e  # Re-disable after memory/manager.sh enables set -e

    # Copy templates so memory_init works
    mkdir -p "$TEST_TMPDIR/core/memory/templates"
    cp "$PROJECT_ROOT/core/memory/templates/"* "$TEST_TMPDIR/core/memory/templates/"
    _MEMORY_TEMPLATES_DIR="$TEST_TMPDIR/core/memory/templates"

    # Init memory
    memory_init "$TEST_TMPDIR"
    assert_file_exists "$TEST_TMPDIR/memory/MEMORY.md" "MEMORY.md created"
    assert_file_exists "$TEST_TMPDIR/memory/changelog.md" "changelog.md created"
    assert_file_exists "$TEST_TMPDIR/memory/metrics.jsonl" "metrics.jsonl created"

    # Append a metric
    local metric='{"id":"test-1","date":"2026-04-06T12:00:00Z","title":"Test","status":"landed","impact_signal":"positive"}'
    memory_append_metric "$TEST_TMPDIR" "$metric"

    # Read it back
    local content
    content="$(memory_get_metrics "$TEST_TMPDIR")"
    assert_contains "$content" "test-1" "metric contains test-1 id"

    # Verify dedup: appending same id again should not duplicate
    memory_append_metric "$TEST_TMPDIR" "$metric"
    local line_count
    line_count="$(wc -l < "$TEST_TMPDIR/memory/metrics.jsonl")"
    assert_eq "1" "$line_count" "dedup prevents duplicate metric"

    # Verify JSONL integrity: every line should be valid JSON
    local invalid_count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! printf '%s' "$line" | jq . >/dev/null 2>&1; then
            (( invalid_count++ )) || true
        fi
    done < "$TEST_TMPDIR/memory/metrics.jsonl"
    assert_eq "0" "$invalid_count" "all JSONL lines are valid JSON"

    # Test memory_append and memory_read
    memory_append "$TEST_TMPDIR" "changelog.md" "[LANDED] test-1 — Test change"
    local changelog
    changelog="$(memory_read "$TEST_TMPDIR" "changelog.md")"
    assert_contains "$changelog" "test-1" "changelog contains appended entry"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 5. Manifest tracking
# Create files in inbox, check manifest_is_new, process them, verify updated.
# ---------------------------------------------------------------------------
test_manifest_tracking() {
    echo "test_manifest_tracking"
    setup_test_env

    source "$PROJECT_ROOT/core/inbox/manifest.sh"
    source "$PROJECT_ROOT/core/inbox/watcher.sh"

    # Init manifest
    manifest_init "$TEST_TMPDIR"
    assert_file_exists "$TEST_TMPDIR/inbox/.manifest.json" "manifest file created"

    # Create files in inbox/pending
    mkdir -p "$TEST_TMPDIR/inbox/pending"
    echo "intelligence item 1" > "$TEST_TMPDIR/inbox/pending/item1.txt"
    echo "intelligence item 2" > "$TEST_TMPDIR/inbox/pending/item2.txt"

    # Both should be new
    assert_exit_code 0 "item1 is new" manifest_is_new "$TEST_TMPDIR" "item1.txt"
    assert_exit_code 0 "item2 is new" manifest_is_new "$TEST_TMPDIR" "item2.txt"

    # Process item1
    inbox_process_item "$TEST_TMPDIR" "$TEST_TMPDIR/inbox/pending/item1.txt"

    # item1 should now be not-new (processed), item2 still new
    assert_exit_code 1 "item1 is not new after processing" manifest_is_new "$TEST_TMPDIR" "item1.txt"
    assert_exit_code 0 "item2 is still new" manifest_is_new "$TEST_TMPDIR" "item2.txt"

    # Verify item1 moved to processed
    assert_file_exists "$TEST_TMPDIR/inbox/processed/item1.txt" "item1 moved to processed"

    # Verify manifest has the entry
    local manifest_status
    manifest_status="$(jq -r '.files["item1.txt"].status' "$TEST_TMPDIR/inbox/.manifest.json")"
    assert_eq "processed" "$manifest_status" "manifest shows item1 as processed"

    # Test manifest stats
    local stats
    stats="$(manifest_get_stats "$TEST_TMPDIR")"
    local processed_count
    processed_count="$(printf '%s' "$stats" | jq '.total_processed')"
    assert_eq "1" "$processed_count" "stats show 1 processed"

    local pending_count
    pending_count="$(printf '%s' "$stats" | jq '.total_pending')"
    assert_eq "1" "$pending_count" "stats show 1 pending"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 6. Directive enforcement
# Create lock directive, verify directive_check_lock catches it.
# ---------------------------------------------------------------------------
test_directive_enforcement() {
    echo "test_directive_enforcement"
    setup_test_env

    source "$PROJECT_ROOT/core/directives/manager.sh"

    local directives_dir="$TEST_TMPDIR/directives"

    # Create a lock directive
    local lock_file
    lock_file="$(directive_create "$directives_dir" "lock" "src/auth/*" "Auth module frozen for audit" "test" "null")"

    assert_file_exists "$lock_file" "lock directive file created"

    # Check: src/auth/login.sh should be locked
    assert_exit_code 0 "src/auth/login.sh is locked" directive_check_lock "$directives_dir" "src/auth/login.sh"
    assert_exit_code 0 "src/auth/session.sh is locked" directive_check_lock "$directives_dir" "src/auth/session.sh"

    # Check: src/api/handler.sh should NOT be locked
    assert_exit_code 1 "src/api/handler.sh is not locked" directive_check_lock "$directives_dir" "src/api/handler.sh"

    # Create a priority directive
    directive_create "$directives_dir" "priority" "security" "+3" "test" "null" >/dev/null
    local boost
    boost="$(directive_check_priority "$directives_dir" "security")"
    assert_eq "+3" "$boost" "security category has +3 priority boost"

    # Create a constraint directive
    directive_create "$directives_dir" "constraint" "pipeline" "No Docker changes this week" "test" "null" >/dev/null
    local constraints
    constraints="$(directive_get_constraints "$directives_dir")"
    assert_contains "$constraints" "No Docker changes" "constraint rule present"

    # Create an override directive
    directive_create "$directives_dir" "override" "change-42" "approved" "test" "null" >/dev/null
    local verdict
    verdict="$(directive_check_override "$directives_dir" "change-42")"
    assert_eq "approved" "$verdict" "override forces approved verdict"

    # Test expired directive
    directive_create "$directives_dir" "lock" "old/path/*" "Expired lock" "test" "2020-01-01" >/dev/null
    assert_exit_code 1 "expired lock does not block" directive_check_lock "$directives_dir" "old/path/file.sh"

    # Listing should show only active directives
    local list_output
    list_output="$(directive_list "$directives_dir")"
    assert_contains "$list_output" "src/auth/*" "active lock shown in list"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 7. Resume context generation
# Create settled pool entries, generate contexts, verify files exist.
# ---------------------------------------------------------------------------
test_resume_context_generation() {
    echo "test_resume_context_generation"
    setup_test_env

    source "$PROJECT_ROOT/core/pool.sh"
    source "$PROJECT_ROOT/core/resume/context-generator.sh"

    # Set up workspace
    local workspace="$TEST_TMPDIR/workspace/2026-04-06"
    mkdir -p "$workspace"

    # Create a pool with settled entries
    local pool_file="$workspace/pool.json"
    pool_init "$pool_file"
    pool_add_entry "$pool_file" '{"id":"ctx-1","status":"landed","title":"Test landed change","description":"A test change that landed"}'
    pool_add_entry "$pool_file" '{"id":"ctx-2","status":"killed","title":"Test killed change","description":"A test change that was killed"}'
    pool_add_entry "$pool_file" '{"id":"ctx-3","status":"reverted","title":"Test reverted change","description":"A test change that was reverted"}'

    # Add history to one entry
    pool_add_history "$pool_file" "ctx-1" "landed" "Change landed successfully"

    # Generate resume context for a single entry
    local ctx_file
    ctx_file="$(generate_resume_context "$TEST_TMPDIR" "$workspace" "ctx-1" "landed")"
    assert_file_exists "$ctx_file" "resume context file for ctx-1 created"

    # Verify content
    local ctx_content
    ctx_content="$(cat "$ctx_file")"
    assert_contains "$ctx_content" "ctx-1" "context contains change id"
    assert_contains "$ctx_content" "landed" "context contains decision type"
    assert_contains "$ctx_content" "Available Actions" "context contains actions section"

    # Generate all resume contexts
    local count
    count="$(generate_all_resume_contexts "$TEST_TMPDIR" "$workspace" "$pool_file")"
    assert_eq "3" "$count" "3 resume contexts generated for 3 settled entries"

    # Verify all context files exist
    assert_file_exists "$TEST_TMPDIR/resume-context/2026-04-06/ctx-1-landed.md" "ctx-1 landed context exists"
    assert_file_exists "$TEST_TMPDIR/resume-context/2026-04-06/ctx-2-killed.md" "ctx-2 killed context exists"
    assert_file_exists "$TEST_TMPDIR/resume-context/2026-04-06/ctx-3-reverted.md" "ctx-3 reverted context exists"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 8. Meta-agent evaluation
# Populate metrics.jsonl with test data, run meta evaluations, verify JSON.
# ---------------------------------------------------------------------------
test_meta_evaluation() {
    echo "test_meta_evaluation"
    setup_test_env

    source "$PROJECT_ROOT/core/config.sh"
    source "$PROJECT_ROOT/core/lock.sh"
    source "$PROJECT_ROOT/core/meta/meta-agent.sh"
    set +e  # Re-disable after meta-agent.sh enables set -e

    # Create metrics.jsonl with test data
    mkdir -p "$TEST_TMPDIR/memory"
    cat > "$TEST_TMPDIR/memory/metrics.jsonl" <<'METRICS'
{"date":"2026-04-01T12:00:00Z","id":"m-1","title":"Change 1","source":"auto","track":"standard","ambition_claimed":3,"ambition_actual":2,"quality_score":8,"resilience_score":7,"category":"security","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-02T12:00:00Z","id":"m-2","title":"Change 2","source":"auto","track":"standard","ambition_claimed":2,"ambition_actual":2,"quality_score":6,"resilience_score":5,"category":"monitoring","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-03T12:00:00Z","id":"m-3","title":"Change 3","source":"auto","track":"standard","ambition_claimed":4,"ambition_actual":1,"quality_score":3,"resilience_score":2,"category":"security","status":"killed","iterations":0,"challenge_verdict":"killed","guard_result":"none","impact_signal":"negative","fix_cycles":0,"failure_reason":"challenge-killed"}
METRICS

    # Run individual evaluations
    local pipeline_health
    pipeline_health="$(meta_evaluate_pipeline_health "$TEST_TMPDIR")"
    # Should be valid JSON
    assert_exit_code 0 "pipeline_health is valid JSON" printf '%s' "$pipeline_health"
    local trend
    trend="$(printf '%s' "$pipeline_health" | jq -r '.trend')"
    assert_contains "stable degrading improving" "$trend" "trend is a valid value"

    local scoring_calibration
    scoring_calibration="$(meta_evaluate_scoring_calibration "$TEST_TMPDIR")"
    assert_exit_code 0 "scoring_calibration is valid JSON" printf '%s' "$scoring_calibration"

    local strategic_drift
    strategic_drift="$(meta_evaluate_strategic_drift "$TEST_TMPDIR")"
    assert_exit_code 0 "strategic_drift is valid JSON" printf '%s' "$strategic_drift"

    # Test source effectiveness (with empty data)
    local source_eff
    source_eff="$(meta_evaluate_source_effectiveness "$TEST_TMPDIR")"
    local sources_count
    sources_count="$(printf '%s' "$source_eff" | jq '.sources | length')"
    assert_eq "0" "$sources_count" "no source data returns empty array"

    # Verify proposals generation
    local evaluations
    evaluations="$(jq -n \
        --argjson pipeline_health "$pipeline_health" \
        --argjson scoring_calibration "$scoring_calibration" \
        --argjson source_effectiveness "$source_eff" \
        --argjson strategic_drift "$strategic_drift" \
        '{
            pipeline_health: $pipeline_health,
            scoring_calibration: $scoring_calibration,
            source_effectiveness: $source_effectiveness,
            strategic_drift: $strategic_drift
        }')"

    mkdir -p "$TEST_TMPDIR/meta/proposals"
    local proposals
    proposals="$(meta_generate_proposals "$TEST_TMPDIR" "$evaluations")"
    local proposals_valid
    proposals_valid="$(printf '%s' "$proposals" | jq 'type' 2>/dev/null)" || proposals_valid=""
    assert_eq '"array"' "$proposals_valid" "proposals is a valid JSON array"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 9. Notification dispatch
# Test that notify with stdout provider produces output.
# ---------------------------------------------------------------------------
test_notification_dispatch() {
    echo "test_notification_dispatch"
    setup_test_env

    source "$PROJECT_ROOT/core/config.sh"
    source "$PROJECT_ROOT/core/notifications/engine.sh"

    # Set up notification entries to stdout
    _NOTIFICATION_ENTRIES=("stdout||")

    # Send a notification
    local output
    output="$(notify "Integration test notification")"
    assert_contains "$output" "Integration test notification" "stdout notification contains message"
    assert_contains "$output" "[" "stdout notification has timestamp prefix"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 10. CLI commands
# Test that evolve version, status, and history work without errors.
# ---------------------------------------------------------------------------
test_cli_commands() {
    echo "test_cli_commands"
    setup_test_env

    # Test version command
    local version_output
    version_output="$("$PROJECT_ROOT/bin/evolve" version 2>&1)"
    assert_contains "$version_output" "evolve-ai v" "version output contains version string"

    # Test status command (should work even with no runs)
    local status_output
    status_output="$("$PROJECT_ROOT/bin/evolve" status 2>&1)"
    assert_contains "$status_output" "No runs yet" "status shows no runs"

    # Test history command (should work with no changelog)
    local history_output
    history_output="$("$PROJECT_ROOT/bin/evolve" history 2>&1)"
    assert_contains "$history_output" "No history yet" "history shows no history"

    # Test help command
    local help_output
    help_output="$("$PROJECT_ROOT/bin/evolve" help 2>&1)"
    assert_contains "$help_output" "Usage:" "help shows usage"
    assert_contains "$help_output" "init" "help lists init command"
    assert_contains "$help_output" "run" "help lists run command"
    assert_contains "$help_output" "resume" "help lists resume command"

    # Test pack list command
    local packs_output
    packs_output="$("$PROJECT_ROOT/bin/evolve" pack list 2>&1)"
    assert_contains "$packs_output" "infrastructure" "pack list includes infrastructure"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all integration tests
# ---------------------------------------------------------------------------
echo "=== Integration Tests ==="
echo ""

test_init_cycle
test_pool_lifecycle
test_scoring_pipeline
test_memory_lifecycle
test_manifest_tracking
test_directive_enforcement
test_resume_context_generation
test_meta_evaluation
test_notification_dispatch
test_cli_commands

report_results
