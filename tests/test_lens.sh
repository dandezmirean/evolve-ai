#!/usr/bin/env bash
# tests/test_lens.sh — tests for core/lens/engine.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=core/lens/engine.sh
source "$PROJECT_ROOT/core/lens/engine.sh"

# Helper to create a test genome.yaml with lens concerns
_create_test_genome() {
    local genome_yaml="$1"
    cat > "$genome_yaml" <<'EOF'
name: "test-genome"
description: "Test genome for lens"

lens:
  concerns:
    - name: "security-posture"
      description: "Vulnerabilities, advisories, CVEs"
      feeds:
        - type: "command"
          command: "echo 'security check output'"
          schedule: "daily"
          description: "Security check"
      accepts_inbox: true
      accepts_agents: true
      research_on_arrival: true

    - name: "resource-drift"
      description: "Disk growth, memory trends"
      feeds:
        - type: "command"
          command: "echo 'resource check output'"
          schedule: "daily"
          description: "Resource check"
      accepts_inbox: false
      accepts_agents: true
      research_on_arrival: false

scan_commands:
  - "echo ok"

health_checks:
  - name: "ok"
    command: "true"
    expect: "exit_code_0"

safety_rules:
  never:
    - "test"

reversibility:
  primary: "git"

commit_categories:
  - "test"

challenge_vectors:
  - "test vector"
EOF
}

# ---------------------------------------------------------------------------
# 1. lens_list_concerns returns all concern names
# ---------------------------------------------------------------------------
test_lens_list_concerns() {
    echo "test_lens_list_concerns"
    setup_test_env

    local genome_yaml="$TEST_TMPDIR/genome.yaml"
    _create_test_genome "$genome_yaml"

    local concerns
    concerns="$(lens_list_concerns "$genome_yaml")"

    assert_contains "$concerns" "security-posture" "lists security-posture concern"
    assert_contains "$concerns" "resource-drift" "lists resource-drift concern"

    local count
    count="$(echo "$concerns" | wc -l)"
    assert_eq "2" "$count" "exactly 2 concerns listed"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 2. lens_list_concerns returns empty for genome without lens
# ---------------------------------------------------------------------------
test_lens_list_concerns_no_lens() {
    echo "test_lens_list_concerns_no_lens"
    setup_test_env

    local genome_yaml="$TEST_TMPDIR/genome.yaml"
    cat > "$genome_yaml" <<'EOF'
name: "no-lens"
description: "No lens section"
EOF

    local concerns
    concerns="$(lens_list_concerns "$genome_yaml")"

    assert_eq "" "$concerns" "no concerns when lens section is missing"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 3. lens_get_concern_config returns correct config
# ---------------------------------------------------------------------------
test_lens_get_concern_config() {
    echo "test_lens_get_concern_config"
    setup_test_env

    local genome_yaml="$TEST_TMPDIR/genome.yaml"
    _create_test_genome "$genome_yaml"

    local config
    config="$(lens_get_concern_config "$genome_yaml" "security-posture")"

    assert_contains "$config" "accepts_inbox=true" "security-posture accepts inbox"
    assert_contains "$config" "accepts_agents=true" "security-posture accepts agents"
    assert_contains "$config" "research_on_arrival=true" "security-posture has research on arrival"

    local config2
    config2="$(lens_get_concern_config "$genome_yaml" "resource-drift")"

    assert_contains "$config2" "accepts_inbox=false" "resource-drift does not accept inbox"
    assert_contains "$config2" "research_on_arrival=false" "resource-drift no research on arrival"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 4. lens_get_concern_config returns error for missing concern
# ---------------------------------------------------------------------------
test_lens_get_concern_config_missing() {
    echo "test_lens_get_concern_config_missing"
    setup_test_env

    local genome_yaml="$TEST_TMPDIR/genome.yaml"
    _create_test_genome "$genome_yaml"

    assert_exit_code 1 "missing concern returns error" \
        lens_get_concern_config "$genome_yaml" "nonexistent"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 5. lens_run creates per-concern directories
# ---------------------------------------------------------------------------
test_lens_run_creates_dirs() {
    echo "test_lens_run_creates_dirs"
    setup_test_env

    local genome_yaml="$TEST_TMPDIR/genome.yaml"
    _create_test_genome "$genome_yaml"

    lens_run "$EVOLVE_ROOT" "$genome_yaml" >/dev/null 2>&1

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ -d "$EVOLVE_ROOT/inbox/security-posture/pending" ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: security-posture/pending created"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: security-posture/pending not created"
    fi

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ -d "$EVOLVE_ROOT/inbox/security-posture/processed" ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: security-posture/processed created"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: security-posture/processed not created"
    fi

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ -d "$EVOLVE_ROOT/inbox/resource-drift/pending" ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: resource-drift/pending created"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: resource-drift/pending not created"
    fi

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 6. lens_run executes feeds and produces output files
# ---------------------------------------------------------------------------
test_lens_run_produces_output() {
    echo "test_lens_run_produces_output"
    setup_test_env

    local genome_yaml="$TEST_TMPDIR/genome.yaml"
    _create_test_genome "$genome_yaml"

    lens_run "$EVOLVE_ROOT" "$genome_yaml" >/dev/null 2>&1

    # The command feeds should have produced files in pending dirs
    local security_files
    security_files="$(ls "$EVOLVE_ROOT/inbox/security-posture/pending/" 2>/dev/null | wc -l)"

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if (( security_files > 0 )); then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: security-posture feed produced output"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: security-posture feed produced no output"
    fi

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 7. lens_check_new_items detects items
# ---------------------------------------------------------------------------
test_lens_check_new_items() {
    echo "test_lens_check_new_items"
    setup_test_env

    local genome_yaml="$TEST_TMPDIR/genome.yaml"
    _create_test_genome "$genome_yaml"

    # Create pending items
    mkdir -p "$EVOLVE_ROOT/inbox/security-posture/pending"
    echo "test item" > "$EVOLVE_ROOT/inbox/security-posture/pending/test-item.md"

    local output
    output="$(lens_check_new_items "$EVOLVE_ROOT" "$genome_yaml")"

    assert_contains "$output" "security-posture" "output mentions the concern"
    assert_contains "$output" "1 new item" "output shows 1 new item"

    assert_exit_code 0 "returns 0 when items exist" \
        lens_check_new_items "$EVOLVE_ROOT" "$genome_yaml"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 8. lens_check_new_items returns 1 when no items
# ---------------------------------------------------------------------------
test_lens_check_new_items_empty() {
    echo "test_lens_check_new_items_empty"
    setup_test_env

    local genome_yaml="$TEST_TMPDIR/genome.yaml"
    _create_test_genome "$genome_yaml"

    mkdir -p "$EVOLVE_ROOT/inbox/security-posture/pending"
    mkdir -p "$EVOLVE_ROOT/inbox/resource-drift/pending"

    assert_exit_code 1 "returns 1 when no items" \
        lens_check_new_items "$EVOLVE_ROOT" "$genome_yaml"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 9. lens_gather_all_pending creates inbox-diff.txt with concern tags
# ---------------------------------------------------------------------------
test_lens_gather_all_pending() {
    echo "test_lens_gather_all_pending"
    setup_test_env

    local genome_yaml="$TEST_TMPDIR/genome.yaml"
    _create_test_genome "$genome_yaml"

    local workspace="$TEST_TMPDIR/workspace"
    mkdir -p "$workspace"

    # Create pending items in two concerns
    mkdir -p "$EVOLVE_ROOT/inbox/security-posture/pending"
    echo "security item content" > "$EVOLVE_ROOT/inbox/security-posture/pending/sec-item.md"

    mkdir -p "$EVOLVE_ROOT/inbox/resource-drift/pending"
    echo "resource item content" > "$EVOLVE_ROOT/inbox/resource-drift/pending/res-item.md"

    lens_gather_all_pending "$EVOLVE_ROOT" "$genome_yaml" "$workspace" >/dev/null 2>&1

    assert_file_exists "$workspace/inbox-diff.txt" "inbox-diff.txt created"

    local content
    content="$(cat "$workspace/inbox-diff.txt")"

    assert_contains "$content" "[concern: security-posture]" "contains security-posture tag"
    assert_contains "$content" "[concern: resource-drift]" "contains resource-drift tag"
    assert_contains "$content" "security item content" "contains security item content"
    assert_contains "$content" "resource item content" "contains resource item content"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 10. lens_gather_all_pending handles empty concerns
# ---------------------------------------------------------------------------
test_lens_gather_all_pending_empty() {
    echo "test_lens_gather_all_pending_empty"
    setup_test_env

    local genome_yaml="$TEST_TMPDIR/genome.yaml"
    _create_test_genome "$genome_yaml"

    local workspace="$TEST_TMPDIR/workspace"
    mkdir -p "$workspace"

    # No pending items
    mkdir -p "$EVOLVE_ROOT/inbox/security-posture/pending"
    mkdir -p "$EVOLVE_ROOT/inbox/resource-drift/pending"

    lens_gather_all_pending "$EVOLVE_ROOT" "$genome_yaml" "$workspace" >/dev/null 2>&1

    assert_file_exists "$workspace/inbox-diff.txt" "inbox-diff.txt created even when empty"

    local content
    content="$(cat "$workspace/inbox-diff.txt")"

    assert_eq "" "$content" "inbox-diff.txt is empty when no pending items"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 11. lens_list_concerns works with real genomes
# ---------------------------------------------------------------------------
test_lens_list_concerns_infrastructure() {
    echo "test_lens_list_concerns_infrastructure"

    local genome_yaml="$PROJECT_ROOT/genomes/infrastructure/genome.yaml"
    local concerns
    concerns="$(lens_list_concerns "$genome_yaml")"

    assert_contains "$concerns" "security-posture" "infrastructure has security-posture"
    assert_contains "$concerns" "resource-drift" "infrastructure has resource-drift"
    assert_contains "$concerns" "service-health" "infrastructure has service-health"

    local count
    count="$(echo "$concerns" | wc -l)"
    assert_eq "3" "$count" "infrastructure has 3 concerns"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_lens_list_concerns
test_lens_list_concerns_no_lens
test_lens_get_concern_config
test_lens_get_concern_config_missing
test_lens_run_creates_dirs
test_lens_run_produces_output
test_lens_check_new_items
test_lens_check_new_items_empty
test_lens_gather_all_pending
test_lens_gather_all_pending_empty
test_lens_list_concerns_infrastructure

report_results
