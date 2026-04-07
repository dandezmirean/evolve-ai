#!/usr/bin/env bash
# tests/test_scoring.sh — tests for core/scoring/engine.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=core/scoring/engine.sh
source "$PROJECT_ROOT/core/scoring/engine.sh"

# ---------------------------------------------------------------------------
# test_scoring_run_heuristic
# scoring_run_heuristic captures numeric output from a mock command
# ---------------------------------------------------------------------------
test_scoring_run_heuristic() {
    echo "test_scoring_run_heuristic"
    setup_test_env

    local workspace="$TEST_TMPDIR/workspace"
    mkdir -p "$workspace"

    # Create a genome.yaml with a heuristic scorer that echoes a number
    local genome_yaml="$TEST_TMPDIR/genome.yaml"
    cat > "$genome_yaml" << 'YAML'
name: test-genome
description: test genome
scorers:
  heuristic:
    - name: "line_count"
      command: "echo 42"
      weight: 1
      direction: "higher_is_better"
    - name: "error_count"
      command: "echo 5"
      weight: 2
      direction: "lower_is_better"
YAML

    scoring_run_heuristic "$genome_yaml" "$workspace" "chg1" "before"

    local out_file="$workspace/scores/chg1-heuristic-before.json"
    assert_file_exists "$out_file" "heuristic before file created"

    local count
    count="$(jq 'length' "$out_file")"
    assert_eq "2" "$count" "two scorer results recorded"

    local line_count_val
    line_count_val="$(jq -r '.[] | select(.name == "line_count") | .value' "$out_file")"
    assert_eq "42" "$line_count_val" "line_count captured value 42"

    local error_count_val
    error_count_val="$(jq -r '.[] | select(.name == "error_count") | .value' "$out_file")"
    assert_eq "5" "$error_count_val" "error_count captured value 5"

    local error_dir
    error_dir="$(jq -r '.[] | select(.name == "error_count") | .direction' "$out_file")"
    assert_eq "lower_is_better" "$error_dir" "error_count direction is lower_is_better"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_scoring_compute_weighted_delta
# Computes correct delta with mixed directions
# ---------------------------------------------------------------------------
test_scoring_compute_weighted_delta() {
    echo "test_scoring_compute_weighted_delta"
    setup_test_env

    local before_file="$TEST_TMPDIR/before.json"
    local after_file="$TEST_TMPDIR/after.json"

    # Before: line_count=10, error_count=5
    # After: line_count=20, error_count=3
    # line_count: higher_is_better, weight=1, delta = 20-10 = +10
    # error_count: lower_is_better, weight=2, delta = -(3-5) = +2
    # weighted = (10*1 + 2*2) / (1+2) = 14/3 ≈ 4.666...
    cat > "$before_file" << 'JSON'
[
    {"name": "line_count", "value": 10, "weight": 1, "direction": "higher_is_better"},
    {"name": "error_count", "value": 5, "weight": 2, "direction": "lower_is_better"}
]
JSON

    cat > "$after_file" << 'JSON'
[
    {"name": "line_count", "value": 20, "weight": 1, "direction": "higher_is_better"},
    {"name": "error_count", "value": 3, "weight": 2, "direction": "lower_is_better"}
]
JSON

    local delta
    delta="$(scoring_compute_weighted_delta "$before_file" "$after_file")"

    # Expected: 14/3 = 4.666666...
    # Check it's approximately 4.67 (allow for floating point)
    local is_correct
    is_correct="$(awk -v d="$delta" 'BEGIN { if (d > 4.6 && d < 4.7) print "yes"; else print "no" }')"
    assert_eq "yes" "$is_correct" "weighted delta is approximately 4.67 (got: $delta)"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_scoring_aggregate_unmeasured
# Returns "unmeasured" when no scorers configured
# ---------------------------------------------------------------------------
test_scoring_aggregate_unmeasured() {
    echo "test_scoring_aggregate_unmeasured"
    setup_test_env

    local workspace="$TEST_TMPDIR/workspace"
    mkdir -p "$workspace/scores"

    scoring_aggregate "$workspace" "chg-none"

    local out_file="$workspace/scores/chg-none-aggregate.json"
    assert_file_exists "$out_file" "aggregate file created"

    local impact
    impact="$(jq -r '.impact_signal' "$out_file")"
    assert_eq "unmeasured" "$impact" "impact_signal is unmeasured with no scorers"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_scoring_aggregate_positive
# Returns "positive" when heuristic_delta > 0 and llm_score >= 0.5
# ---------------------------------------------------------------------------
test_scoring_aggregate_positive() {
    echo "test_scoring_aggregate_positive"
    setup_test_env

    local workspace="$TEST_TMPDIR/workspace"
    mkdir -p "$workspace/scores"

    # Create heuristic before/after with positive delta
    echo '[{"name":"quality","value":5,"weight":1,"direction":"higher_is_better"}]' \
        > "$workspace/scores/chg1-heuristic-before.json"
    echo '[{"name":"quality","value":10,"weight":1,"direction":"higher_is_better"}]' \
        > "$workspace/scores/chg1-heuristic-after.json"

    # Create LLM judge with good score
    echo '{"score": 0.8, "reasoning": "Good improvement"}' \
        > "$workspace/scores/chg1-llm-judge.json"

    scoring_aggregate "$workspace" "chg1"

    local out_file="$workspace/scores/chg1-aggregate.json"
    local impact
    impact="$(jq -r '.impact_signal' "$out_file")"
    assert_eq "positive" "$impact" "impact_signal is positive"

    local delta
    delta="$(jq -r '.heuristic_delta' "$out_file")"
    assert_eq "5" "$delta" "heuristic_delta is 5"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_scoring_aggregate_negative_kpi
# Returns "negative" when kpi regresses (hard gate)
# ---------------------------------------------------------------------------
test_scoring_aggregate_negative_kpi() {
    echo "test_scoring_aggregate_negative_kpi"
    setup_test_env

    local workspace="$TEST_TMPDIR/workspace"
    mkdir -p "$workspace/scores"

    # Positive heuristics
    echo '[{"name":"quality","value":5,"weight":1,"direction":"higher_is_better"}]' \
        > "$workspace/scores/chg2-heuristic-before.json"
    echo '[{"name":"quality","value":10,"weight":1,"direction":"higher_is_better"}]' \
        > "$workspace/scores/chg2-heuristic-after.json"

    # Good LLM score
    echo '{"score": 0.9, "reasoning": "Excellent"}' \
        > "$workspace/scores/chg2-llm-judge.json"

    # KPI regression (hard gate)
    echo '{"result": "regress", "checks": [{"name": "latency", "result": "regress"}]}' \
        > "$workspace/scores/chg2-kpi.json"

    scoring_aggregate "$workspace" "chg2"

    local out_file="$workspace/scores/chg2-aggregate.json"
    local impact
    impact="$(jq -r '.impact_signal' "$out_file")"
    assert_eq "negative" "$impact" "impact_signal is negative when KPI regresses (hard gate)"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_scoring_aggregate_neutral
# Returns "neutral" when signals disagree
# ---------------------------------------------------------------------------
test_scoring_aggregate_neutral() {
    echo "test_scoring_aggregate_neutral"
    setup_test_env

    local workspace="$TEST_TMPDIR/workspace"
    mkdir -p "$workspace/scores"

    # Positive heuristic
    echo '[{"name":"quality","value":5,"weight":1,"direction":"higher_is_better"}]' \
        > "$workspace/scores/chg3-heuristic-before.json"
    echo '[{"name":"quality","value":10,"weight":1,"direction":"higher_is_better"}]' \
        > "$workspace/scores/chg3-heuristic-after.json"

    # Negative LLM score (disagrees with heuristic)
    echo '{"score": 0.2, "reasoning": "Poor code quality despite metric improvement"}' \
        > "$workspace/scores/chg3-llm-judge.json"

    scoring_aggregate "$workspace" "chg3"

    local out_file="$workspace/scores/chg3-aggregate.json"
    local impact
    impact="$(jq -r '.impact_signal' "$out_file")"
    assert_eq "neutral" "$impact" "impact_signal is neutral when heuristic positive but LLM negative"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_scoring_run_heuristic
test_scoring_compute_weighted_delta
test_scoring_aggregate_unmeasured
test_scoring_aggregate_positive
test_scoring_aggregate_negative_kpi
test_scoring_aggregate_neutral

report_results
