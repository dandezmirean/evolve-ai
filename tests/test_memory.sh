#!/usr/bin/env bash
# tests/test_memory.sh — tests for core/memory/manager.sh and core/scoring/metrics.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=core/memory/manager.sh
source "$PROJECT_ROOT/core/memory/manager.sh"
# shellcheck source=core/scoring/metrics.sh
source "$PROJECT_ROOT/core/scoring/metrics.sh"
# shellcheck source=core/pool.sh
source "$PROJECT_ROOT/core/pool.sh"

# ---------------------------------------------------------------------------
# test_memory_init
# memory_init creates the directory and template files
# ---------------------------------------------------------------------------
test_memory_init() {
    echo "test_memory_init"
    setup_test_env

    memory_init "$TEST_TMPDIR"

    assert_file_exists "$TEST_TMPDIR/memory/MEMORY.md" "MEMORY.md created"
    assert_file_exists "$TEST_TMPDIR/memory/changelog.md" "changelog.md created"
    assert_file_exists "$TEST_TMPDIR/memory/metrics.jsonl" "metrics.jsonl created"
    assert_file_exists "$TEST_TMPDIR/memory/source-credibility.jsonl" "source-credibility.jsonl created"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_memory_append
# memory_append adds content to a file
# ---------------------------------------------------------------------------
test_memory_append() {
    echo "test_memory_append"
    setup_test_env

    memory_init "$TEST_TMPDIR"
    memory_append "$TEST_TMPDIR" "changelog.md" "[LANDED] 2026-04-01 — Test change"
    memory_append "$TEST_TMPDIR" "changelog.md" "[REVERTED] 2026-04-02 — Another change"

    local content
    content="$(memory_read "$TEST_TMPDIR" "changelog.md")"
    assert_contains "$content" "[LANDED] 2026-04-01" "changelog contains first entry"
    assert_contains "$content" "[REVERTED] 2026-04-02" "changelog contains second entry"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_memory_read
# memory_read returns file content
# ---------------------------------------------------------------------------
test_memory_read() {
    echo "test_memory_read"
    setup_test_env

    memory_init "$TEST_TMPDIR"
    memory_write "$TEST_TMPDIR" "test.md" "hello world"

    local content
    content="$(memory_read "$TEST_TMPDIR" "test.md")"
    assert_contains "$content" "hello world" "memory_read returns written content"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_memory_append_metric
# Writes valid JSONL and deduplicates
# ---------------------------------------------------------------------------
test_memory_append_metric() {
    echo "test_memory_append_metric"
    setup_test_env

    memory_init "$TEST_TMPDIR"

    local metric1='{"id":"m1","date":"2026-04-01","status":"landed"}'
    local metric2='{"id":"m2","date":"2026-04-01","status":"reverted"}'

    memory_append_metric "$TEST_TMPDIR" "$metric1"
    memory_append_metric "$TEST_TMPDIR" "$metric2"

    # Try to append duplicate
    memory_append_metric "$TEST_TMPDIR" "$metric1"

    local line_count
    line_count="$(wc -l < "$TEST_TMPDIR/memory/metrics.jsonl")"
    assert_eq "2" "$line_count" "metrics.jsonl has 2 lines (dedup worked)"

    # Verify valid JSONL
    local valid
    valid="$(jq -c '.id' "$TEST_TMPDIR/memory/metrics.jsonl" 2>/dev/null | wc -l)"
    assert_eq "2" "$valid" "both lines are valid JSON"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_memory_source_credibility
# memory_get_source_credibility computes correct hit rate
# ---------------------------------------------------------------------------
test_memory_source_credibility() {
    echo "test_memory_source_credibility"
    setup_test_env

    memory_init "$TEST_TMPDIR"

    local today
    today="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    # Add 3 entries for source "github-trending": 2 passed, 1 not
    memory_append_source_credibility "$TEST_TMPDIR" \
        "{\"date\":\"$today\",\"source_name\":\"github-trending\",\"passed\":true}"
    memory_append_source_credibility "$TEST_TMPDIR" \
        "{\"date\":\"$today\",\"source_name\":\"github-trending\",\"passed\":true}"
    memory_append_source_credibility "$TEST_TMPDIR" \
        "{\"date\":\"$today\",\"source_name\":\"github-trending\",\"passed\":false}"

    local result
    result="$(memory_get_source_credibility "$TEST_TMPDIR" "github-trending" 30)"

    local hit_rate
    hit_rate="$(printf '%s' "$result" | jq -r '.hit_rate_30d')"
    # 2 out of 3 = 66.67%
    local rate_correct
    rate_correct="$(awk -v r="$hit_rate" 'BEGIN { if (r > 66 && r < 67) print "yes"; else print "no" }')"
    assert_eq "yes" "$rate_correct" "hit rate is approximately 66.67% (got: $hit_rate)"

    local total
    total="$(printf '%s' "$result" | jq -r '.total_topics')"
    assert_eq "3" "$total" "total_topics is 3"

    local passed
    passed="$(printf '%s' "$result" | jq -r '.total_passed')"
    assert_eq "2" "$passed" "total_passed is 2"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_metrics_record
# metrics_record extracts data from pool correctly
# ---------------------------------------------------------------------------
test_metrics_record() {
    echo "test_metrics_record"
    setup_test_env

    memory_init "$TEST_TMPDIR"

    local pool_file="$TEST_TMPDIR/pool.json"
    pool_init "$pool_file"

    # Add settled entries
    pool_add_entry "$pool_file" '{"id":"e1","status":"landed","title":"Add feature X","category":"feature","source":"github","impact_signal":"positive"}'
    pool_add_entry "$pool_file" '{"id":"e2","status":"killed","title":"Remove old code","category":"cleanup","source":"manual","failure_reason":"too risky"}'
    # Add non-settled entry (should be skipped)
    pool_add_entry "$pool_file" '{"id":"e3","status":"pending","title":"WIP"}'

    metrics_record "$pool_file" "$TEST_TMPDIR"

    local line_count
    line_count="$(wc -l < "$TEST_TMPDIR/memory/metrics.jsonl")"
    assert_eq "2" "$line_count" "only 2 settled entries recorded"

    # Verify first entry fields
    local first_id
    first_id="$(head -1 "$TEST_TMPDIR/memory/metrics.jsonl" | jq -r '.id')"
    assert_eq "e1" "$first_id" "first metric has id e1"

    local first_cat
    first_cat="$(head -1 "$TEST_TMPDIR/memory/metrics.jsonl" | jq -r '.category')"
    assert_eq "feature" "$first_cat" "first metric has category feature"

    local second_reason
    second_reason="$(tail -1 "$TEST_TMPDIR/memory/metrics.jsonl" | jq -r '.failure_reason')"
    assert_eq "too risky" "$second_reason" "second metric has correct failure_reason"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_metrics_compute_category_stats
# Returns correct stats for a category
# ---------------------------------------------------------------------------
test_metrics_compute_category_stats() {
    echo "test_metrics_compute_category_stats"
    setup_test_env

    memory_init "$TEST_TMPDIR"

    local today
    today="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    # Add 3 feature entries: 2 landed, 1 killed, fix_cycles: 1, 2, 0
    printf '%s\n' "{\"id\":\"f1\",\"date\":\"$today\",\"category\":\"feature\",\"status\":\"landed\",\"fix_cycles\":1}" >> "$TEST_TMPDIR/memory/metrics.jsonl"
    printf '%s\n' "{\"id\":\"f2\",\"date\":\"$today\",\"category\":\"feature\",\"status\":\"landed\",\"fix_cycles\":2}" >> "$TEST_TMPDIR/memory/metrics.jsonl"
    printf '%s\n' "{\"id\":\"f3\",\"date\":\"$today\",\"category\":\"feature\",\"status\":\"killed\",\"fix_cycles\":0}" >> "$TEST_TMPDIR/memory/metrics.jsonl"
    # Add unrelated entry
    printf '%s\n' "{\"id\":\"b1\",\"date\":\"$today\",\"category\":\"bugfix\",\"status\":\"landed\",\"fix_cycles\":0}" >> "$TEST_TMPDIR/memory/metrics.jsonl"

    local result
    result="$(metrics_compute_category_stats "$TEST_TMPDIR" "feature" 7)"

    local total
    total="$(printf '%s' "$result" | jq -r '.total_count')"
    assert_eq "3" "$total" "total_count is 3 for feature"

    local land_rate
    land_rate="$(printf '%s' "$result" | jq -r '.land_rate')"
    # 2 out of 3 = 66.67%
    local rate_ok
    rate_ok="$(awk -v r="$land_rate" 'BEGIN { if (r > 66 && r < 67) print "yes"; else print "no" }')"
    assert_eq "yes" "$rate_ok" "land_rate is approximately 66.67% (got: $land_rate)"

    local avg_fix
    avg_fix="$(printf '%s' "$result" | jq -r '.avg_fix_cycles')"
    assert_eq "1" "$avg_fix" "avg_fix_cycles is 1"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_memory_init
test_memory_append
test_memory_read
test_memory_append_metric
test_memory_source_credibility
test_metrics_record
test_metrics_compute_category_stats

report_results
