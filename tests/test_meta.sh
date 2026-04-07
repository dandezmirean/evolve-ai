#!/usr/bin/env bash
# tests/test_meta.sh — tests for core/meta/meta-agent.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=core/meta/meta-agent.sh
source "$PROJECT_ROOT/core/meta/meta-agent.sh"

# ---------------------------------------------------------------------------
# test_meta_evaluate_pipeline_health_valid_json
# meta_evaluate_pipeline_health returns valid JSON with required fields
# ---------------------------------------------------------------------------
test_meta_evaluate_pipeline_health_valid_json() {
    echo "test_meta_evaluate_pipeline_health_valid_json"
    setup_test_env

    mkdir -p "$TEST_TMPDIR/memory"
    # Create some metrics data
    cat > "$TEST_TMPDIR/memory/metrics.jsonl" << 'JSONL'
{"date":"2026-04-01T12:00:00Z","id":"chg-1","title":"test1","source":"rss","track":"standard","ambition_claimed":2,"ambition_actual":2,"quality_score":8,"resilience_score":7,"category":"performance","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-02T12:00:00Z","id":"chg-2","title":"test2","source":"rss","track":"standard","ambition_claimed":3,"ambition_actual":1,"quality_score":5,"resilience_score":4,"category":"security","status":"killed","iterations":2,"challenge_verdict":"rejected","guard_result":"none","impact_signal":"unmeasured","fix_cycles":1,"failure_reason":"challenge_rejected"}
{"date":"2026-04-03T12:00:00Z","id":"chg-3","title":"test3","source":"manual","track":"standard","ambition_claimed":1,"ambition_actual":1,"quality_score":7,"resilience_score":6,"category":"performance","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
JSONL

    local result
    result="$(meta_evaluate_pipeline_health "$TEST_TMPDIR")"

    # Verify it's valid JSON
    local is_valid
    is_valid="$(printf '%s' "$result" | jq 'type' 2>/dev/null)" || is_valid="invalid"
    assert_eq '"object"' "$is_valid" "pipeline health returns valid JSON object"

    # Check required fields exist
    local has_kill_rate has_land_rate has_guard_fail has_fix_cycles has_trend
    has_kill_rate="$(printf '%s' "$result" | jq 'has("kill_rate")')"
    has_land_rate="$(printf '%s' "$result" | jq 'has("land_rate")')"
    has_guard_fail="$(printf '%s' "$result" | jq 'has("guard_fail_rate")')"
    has_fix_cycles="$(printf '%s' "$result" | jq 'has("avg_fix_cycles")')"
    has_trend="$(printf '%s' "$result" | jq 'has("trend")')"

    assert_eq "true" "$has_kill_rate" "has kill_rate field"
    assert_eq "true" "$has_land_rate" "has land_rate field"
    assert_eq "true" "$has_guard_fail" "has guard_fail_rate field"
    assert_eq "true" "$has_fix_cycles" "has avg_fix_cycles field"
    assert_eq "true" "$has_trend" "has trend field"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_meta_evaluate_pipeline_health_correct_kill_rate
# meta_evaluate_pipeline_health computes correct kill_rate from metrics data
# ---------------------------------------------------------------------------
test_meta_evaluate_pipeline_health_correct_kill_rate() {
    echo "test_meta_evaluate_pipeline_health_correct_kill_rate"
    setup_test_env

    mkdir -p "$TEST_TMPDIR/memory"
    # 4 entries: 1 killed, 3 landed -> kill rate = 1/4 = 0.25
    cat > "$TEST_TMPDIR/memory/metrics.jsonl" << 'JSONL'
{"date":"2026-04-01T12:00:00Z","id":"chg-1","title":"t1","source":"rss","track":"standard","ambition_claimed":2,"ambition_actual":2,"quality_score":8,"resilience_score":7,"category":"perf","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-02T12:00:00Z","id":"chg-2","title":"t2","source":"rss","track":"standard","ambition_claimed":3,"ambition_actual":1,"quality_score":5,"resilience_score":4,"category":"sec","status":"killed","iterations":2,"challenge_verdict":"rejected","guard_result":"none","impact_signal":"unmeasured","fix_cycles":1,"failure_reason":"rejected"}
{"date":"2026-04-03T12:00:00Z","id":"chg-3","title":"t3","source":"manual","track":"standard","ambition_claimed":1,"ambition_actual":1,"quality_score":7,"resilience_score":6,"category":"perf","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-04T12:00:00Z","id":"chg-4","title":"t4","source":"manual","track":"standard","ambition_claimed":2,"ambition_actual":2,"quality_score":6,"resilience_score":5,"category":"perf","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
JSONL

    local result
    result="$(meta_evaluate_pipeline_health "$TEST_TMPDIR")"

    local kill_rate
    kill_rate="$(printf '%s' "$result" | jq -r '.kill_rate')"

    # kill_rate = 1/4 = 0.25
    assert_eq "0.25" "$kill_rate" "kill_rate is 0.25 (1 killed out of 4)"

    local land_rate
    land_rate="$(printf '%s' "$result" | jq -r '.land_rate')"

    # land_rate = 3/4 = 0.75
    assert_eq "0.75" "$land_rate" "land_rate is 0.75 (3 landed out of 4)"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_meta_evaluate_scoring_calibration_detects_inflation
# meta_evaluate_scoring_calibration detects ambition inflation
# ---------------------------------------------------------------------------
test_meta_evaluate_scoring_calibration_detects_inflation() {
    echo "test_meta_evaluate_scoring_calibration_detects_inflation"
    setup_test_env

    mkdir -p "$TEST_TMPDIR/memory"
    # All entries have ambition_claimed >> ambition_actual (inflation)
    cat > "$TEST_TMPDIR/memory/metrics.jsonl" << 'JSONL'
{"date":"2026-04-01T12:00:00Z","id":"chg-1","title":"t1","source":"rss","track":"standard","ambition_claimed":5,"ambition_actual":2,"quality_score":8,"resilience_score":7,"category":"perf","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-02T12:00:00Z","id":"chg-2","title":"t2","source":"rss","track":"standard","ambition_claimed":4,"ambition_actual":1,"quality_score":7,"resilience_score":6,"category":"perf","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-03T12:00:00Z","id":"chg-3","title":"t3","source":"manual","track":"standard","ambition_claimed":5,"ambition_actual":2,"quality_score":9,"resilience_score":8,"category":"sec","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
JSONL

    local result
    result="$(meta_evaluate_scoring_calibration "$TEST_TMPDIR")"

    local inflation
    inflation="$(printf '%s' "$result" | jq -r '.ambition_inflation')"

    # avg inflation = ((5-2) + (4-1) + (5-2)) / 3 = (3+3+3)/3 = 3
    assert_eq "3" "$inflation" "ambition inflation is 3 (claimed >> actual)"

    local aligned
    aligned="$(printf '%s' "$result" | jq -r '.scoring_aligned')"
    assert_eq "false" "$aligned" "scoring_aligned is false due to high inflation"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_meta_evaluate_source_effectiveness_identifies_low_hit_rate
# meta_evaluate_source_effectiveness identifies low hit-rate sources
# ---------------------------------------------------------------------------
test_meta_evaluate_source_effectiveness_identifies_low_hit_rate() {
    echo "test_meta_evaluate_source_effectiveness_identifies_low_hit_rate"
    setup_test_env

    mkdir -p "$TEST_TMPDIR/memory"
    # Source "good-feed" has high hit rate, "bad-feed" has zero
    cat > "$TEST_TMPDIR/memory/source-credibility.jsonl" << 'JSONL'
{"date":"2026-04-01T12:00:00Z","source_name":"good-feed","total_topics":5,"passed":true}
{"date":"2026-04-01T12:00:00Z","source_name":"good-feed","total_topics":3,"passed":true}
{"date":"2026-04-01T12:00:00Z","source_name":"good-feed","total_topics":2,"passed":true}
{"date":"2026-04-02T12:00:00Z","source_name":"bad-feed","total_topics":4,"passed":false}
{"date":"2026-04-02T12:00:00Z","source_name":"bad-feed","total_topics":3,"passed":false}
{"date":"2026-04-02T12:00:00Z","source_name":"bad-feed","total_topics":2,"passed":false}
JSONL

    local result
    result="$(meta_evaluate_source_effectiveness "$TEST_TMPDIR")"

    # Check good-feed has "keep" recommendation
    local good_rec
    good_rec="$(printf '%s' "$result" | jq -r '.sources[] | select(.name == "good-feed") | .recommendation')"
    assert_eq "keep" "$good_rec" "good-feed recommendation is keep"

    # Check bad-feed has "remove" recommendation
    local bad_rec
    bad_rec="$(printf '%s' "$result" | jq -r '.sources[] | select(.name == "bad-feed") | .recommendation')"
    assert_eq "remove" "$bad_rec" "bad-feed recommendation is remove"

    # Check good-feed hit rate is 1.0
    local good_hit
    good_hit="$(printf '%s' "$result" | jq -r '.sources[] | select(.name == "good-feed") | .hit_rate')"
    assert_eq "1" "$good_hit" "good-feed hit_rate is 1.0"

    # Check bad-feed hit rate is 0
    local bad_hit
    bad_hit="$(printf '%s' "$result" | jq -r '.sources[] | select(.name == "bad-feed") | .hit_rate')"
    assert_eq "0" "$bad_hit" "bad-feed hit_rate is 0"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_meta_evaluate_strategic_drift_detects_category_imbalance
# meta_evaluate_strategic_drift detects category imbalance
# ---------------------------------------------------------------------------
test_meta_evaluate_strategic_drift_detects_category_imbalance() {
    echo "test_meta_evaluate_strategic_drift_detects_category_imbalance"
    setup_test_env

    mkdir -p "$TEST_TMPDIR/memory"
    # 10 entries, 8 in "performance", 1 in "security", 1 in "docs"
    # performance > 60% of total -> imbalanced
    cat > "$TEST_TMPDIR/memory/metrics.jsonl" << 'JSONL'
{"date":"2026-04-01T12:00:00Z","id":"c1","title":"t","source":"rss","track":"standard","ambition_claimed":2,"ambition_actual":2,"quality_score":7,"resilience_score":6,"category":"performance","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-01T12:00:00Z","id":"c2","title":"t","source":"rss","track":"standard","ambition_claimed":2,"ambition_actual":2,"quality_score":7,"resilience_score":6,"category":"performance","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-01T12:00:00Z","id":"c3","title":"t","source":"rss","track":"standard","ambition_claimed":2,"ambition_actual":2,"quality_score":7,"resilience_score":6,"category":"performance","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-01T12:00:00Z","id":"c4","title":"t","source":"rss","track":"standard","ambition_claimed":2,"ambition_actual":2,"quality_score":7,"resilience_score":6,"category":"performance","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-01T12:00:00Z","id":"c5","title":"t","source":"rss","track":"standard","ambition_claimed":2,"ambition_actual":2,"quality_score":7,"resilience_score":6,"category":"performance","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-01T12:00:00Z","id":"c6","title":"t","source":"rss","track":"standard","ambition_claimed":2,"ambition_actual":2,"quality_score":7,"resilience_score":6,"category":"performance","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-01T12:00:00Z","id":"c7","title":"t","source":"rss","track":"standard","ambition_claimed":2,"ambition_actual":2,"quality_score":7,"resilience_score":6,"category":"performance","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-01T12:00:00Z","id":"c8","title":"t","source":"rss","track":"standard","ambition_claimed":2,"ambition_actual":2,"quality_score":7,"resilience_score":6,"category":"performance","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-01T12:00:00Z","id":"c9","title":"t","source":"rss","track":"standard","ambition_claimed":1,"ambition_actual":1,"quality_score":6,"resilience_score":5,"category":"security","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"positive","fix_cycles":0,"failure_reason":"none"}
{"date":"2026-04-01T12:00:00Z","id":"c10","title":"t","source":"rss","track":"standard","ambition_claimed":1,"ambition_actual":1,"quality_score":5,"resilience_score":4,"category":"docs","status":"landed","iterations":1,"challenge_verdict":"approved","guard_result":"pass","impact_signal":"neutral","fix_cycles":0,"failure_reason":"none"}
JSONL

    local result
    result="$(meta_evaluate_strategic_drift "$TEST_TMPDIR")"

    # performance should have 8 entries
    local perf_count
    perf_count="$(printf '%s' "$result" | jq -r '.category_distribution.performance')"
    assert_eq "8" "$perf_count" "performance category has 8 entries"

    # Verify category_distribution has multiple categories
    local cat_count
    cat_count="$(printf '%s' "$result" | jq '.category_distribution | keys | length')"
    assert_eq "3" "$cat_count" "3 categories present in distribution"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_meta_generate_proposals_respects_cannot_modify
# meta_generate_proposals never proposes changes to safety rules,
# pack identity, circuit breaker config, or its own prompt
# ---------------------------------------------------------------------------
test_meta_generate_proposals_respects_cannot_modify() {
    echo "test_meta_generate_proposals_respects_cannot_modify"
    setup_test_env

    mkdir -p "$TEST_TMPDIR/meta/proposals"

    # Create evaluations with a degrading pipeline to trigger proposals
    local evaluations
    evaluations='{"pipeline_health":{"kill_rate":0.8,"land_rate":0.1,"guard_fail_rate":0.6,"avg_fix_cycles":5,"trend":"degrading"},"scoring_calibration":{"quality_land_correlation":0.2,"ambition_inflation":2.5,"scoring_aligned":false},"source_effectiveness":{"sources":[{"name":"bad-source","hit_rate":0.05,"recommendation":"remove"}]},"strategic_drift":{"category_distribution":{"perf":10},"ambition_trend":"declining","risk_aversion":true}}'

    local proposals
    proposals="$(meta_generate_proposals "$TEST_TMPDIR" "$evaluations")"

    # Check that no proposal targets safety rules
    local safety_proposals
    safety_proposals="$(printf '%s' "$proposals" | jq '[.[] | select(.target == "safety_rules" or .target == "circuit_breaker" or .target == "pack_identity" or .target == "meta_prompt")] | length')"
    assert_eq "0" "$safety_proposals" "no proposals target safety rules, circuit breaker, pack identity, or meta prompt"

    # Check that proposals were generated (since the system is degrading)
    local proposal_count
    proposal_count="$(printf '%s' "$proposals" | jq 'length')"
    local has_proposals
    has_proposals="$(awk -v c="$proposal_count" 'BEGIN { print (c > 0) ? "yes" : "no" }')"
    assert_eq "yes" "$has_proposals" "proposals were generated for degrading system (count: $proposal_count)"

    # Verify only allowed targets
    local all_targets
    all_targets="$(printf '%s' "$proposals" | jq -r '.[].target' | sort -u)"
    local has_forbidden="no"
    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        case "$target" in
            safety_rules|circuit_breaker|pack_identity|meta_prompt)
                has_forbidden="yes"
                ;;
        esac
    done <<< "$all_targets"
    assert_eq "no" "$has_forbidden" "no forbidden targets in proposals"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_meta_generate_report_produces_markdown
# meta_generate_report produces markdown report
# ---------------------------------------------------------------------------
test_meta_generate_report_produces_markdown() {
    echo "test_meta_generate_report_produces_markdown"
    setup_test_env

    local evaluations
    evaluations='{"pipeline_health":{"kill_rate":0.25,"land_rate":0.75,"guard_fail_rate":0.1,"avg_fix_cycles":1,"trend":"stable"},"scoring_calibration":{"quality_land_correlation":0.8,"ambition_inflation":0.5,"scoring_aligned":true},"source_effectiveness":{"sources":[{"name":"rss-feed","hit_rate":0.7,"recommendation":"keep"}]},"strategic_drift":{"category_distribution":{"performance":5,"security":3},"ambition_trend":"stable","risk_aversion":false}}'

    local proposals='[]'

    local report
    report="$(meta_generate_report "$TEST_TMPDIR" "$evaluations" "$proposals")"

    # Check report contains expected sections
    assert_contains "$report" "# Meta-Agent Evaluation Report" "report has title"
    assert_contains "$report" "## Pipeline Health" "report has pipeline health section"
    assert_contains "$report" "## Scoring Calibration" "report has scoring calibration section"
    assert_contains "$report" "## Source Effectiveness" "report has source effectiveness section"
    assert_contains "$report" "## Strategic Drift" "report has strategic drift section"
    assert_contains "$report" "## Proposals" "report has proposals section"

    # Check actual values appear in report
    assert_contains "$report" "Kill rate: 0.25" "report contains kill rate"
    assert_contains "$report" "Land rate: 0.75" "report contains land rate"
    assert_contains "$report" "Trend: **stable**" "report contains trend"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_meta_status_no_evaluations
# meta_status shows "no evaluations yet" when meta hasn't run
# ---------------------------------------------------------------------------
test_meta_status_no_evaluations() {
    echo "test_meta_status_no_evaluations"
    setup_test_env

    local output
    output="$(meta_status "$TEST_TMPDIR")"

    assert_contains "$output" "No meta evaluations yet" "shows no evaluations message"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_meta_evaluate_pipeline_health_empty_metrics
# Pipeline health returns defaults for empty/missing metrics
# ---------------------------------------------------------------------------
test_meta_evaluate_pipeline_health_empty_metrics() {
    echo "test_meta_evaluate_pipeline_health_empty_metrics"
    setup_test_env

    # No metrics file at all
    local result
    result="$(meta_evaluate_pipeline_health "$TEST_TMPDIR")"

    local kill_rate trend
    kill_rate="$(printf '%s' "$result" | jq -r '.kill_rate')"
    trend="$(printf '%s' "$result" | jq -r '.trend')"

    assert_eq "0" "$kill_rate" "kill_rate is 0 for empty metrics"
    assert_eq "stable" "$trend" "trend is stable for empty metrics"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_meta_evaluate_pipeline_health_valid_json
test_meta_evaluate_pipeline_health_correct_kill_rate
test_meta_evaluate_scoring_calibration_detects_inflation
test_meta_evaluate_source_effectiveness_identifies_low_hit_rate
test_meta_evaluate_strategic_drift_detects_category_imbalance
test_meta_generate_proposals_respects_cannot_modify
test_meta_generate_report_produces_markdown
test_meta_status_no_evaluations
test_meta_evaluate_pipeline_health_empty_metrics

report_results
