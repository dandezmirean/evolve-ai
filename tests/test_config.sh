#!/usr/bin/env bash
# tests/test_config.sh — tests for core/config.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=core/config.sh
source "$PROJECT_ROOT/core/config.sh"

# ---------------------------------------------------------------------------
# test_load_config
# ---------------------------------------------------------------------------
test_load_config() {
    echo "test_load_config"
    setup_test_env

    local yaml="$TEST_TMPDIR/evolve.yaml"
    cp "$PROJECT_ROOT/config/evolve.yaml.template" "$yaml"

    load_config "$yaml"

    assert_eq "1.0.0"      "$(config_get version)"                     "version"
    assert_eq "claude-max" "$(config_get provider.type)"               "provider.type"
    assert_eq "1500"       "$(config_get resources.min_free_ram_mb)"   "resources.min_free_ram_mb"
    assert_eq "85"         "$(config_get resources.max_disk_usage_pct)" "resources.max_disk_usage_pct"
    assert_eq "3"          "$(config_get convergence.max_stalls)"      "convergence.max_stalls"
    assert_eq "10"         "$(config_get convergence.max_iterations)"  "convergence.max_iterations"
    assert_eq "50"         "$(config_get challenge.approval_floor_pct)" "challenge.approval_floor_pct"
    assert_eq "14"         "$(config_get retention.workspace_days)"    "retention.workspace_days"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_config_missing_key
# ---------------------------------------------------------------------------
test_config_missing_key() {
    echo "test_config_missing_key"
    setup_test_env

    local yaml="$TEST_TMPDIR/evolve.yaml"
    cp "$PROJECT_ROOT/config/evolve.yaml.template" "$yaml"

    load_config "$yaml"

    assert_eq "" "$(config_get does.not.exist)" "missing key returns empty string"
    assert_eq "" "$(config_get totally_missing)"  "missing top-level key returns empty string"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_config_default
# ---------------------------------------------------------------------------
test_config_default() {
    echo "test_config_default"
    setup_test_env

    local yaml="$TEST_TMPDIR/evolve.yaml"
    cp "$PROJECT_ROOT/config/evolve.yaml.template" "$yaml"

    load_config "$yaml"

    # Missing key should return the provided default
    assert_eq "fallback" "$(config_get_default does.not.exist fallback)" "missing key uses default"

    # Existing key should ignore the default
    assert_eq "claude-max" "$(config_get_default provider.type ignored-default)" "existing key ignores default"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_load_config_list_items
# ---------------------------------------------------------------------------
test_load_config_list_items() {
    echo "test_load_config_list_items"
    setup_test_env

    local yaml="$TEST_TMPDIR/evolve.yaml"
    cp "$PROJECT_ROOT/config/evolve.yaml.template" "$yaml"

    load_config "$yaml"

    assert_eq "infrastructure" "$(config_get targets.0.genome)" "targets.0.genome"
    assert_eq "."              "$(config_get targets.0.root)"   "targets.0.root"
    assert_eq "1"              "$(config_get targets.0.weight)" "targets.0.weight"
    assert_eq "digest"         "$(config_get pipeline.phases.0)" "pipeline.phases.0"
    assert_eq "metrics"        "$(config_get pipeline.phases.7)" "pipeline.phases.7"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_load_config_deep_nesting
# ---------------------------------------------------------------------------
test_load_config_deep_nesting() {
    echo "test_load_config_deep_nesting"
    setup_test_env

    local yaml="$TEST_TMPDIR/genome.yaml"
    cat > "$yaml" <<'YAML'
name: "test-genome"
scorers:
  llm_judge:
    enabled: true
    prompt: "Rate this change"
  heuristic:
    - name: "uptime"
      weight: 2
YAML

    load_config "$yaml"

    assert_eq "test-genome" "$(config_get name)"                        "name"
    assert_eq "true"        "$(config_get scorers.llm_judge.enabled)"   "scorers.llm_judge.enabled"
    assert_eq "Rate this change" "$(config_get scorers.llm_judge.prompt)" "scorers.llm_judge.prompt"
    assert_eq "uptime"      "$(config_get scorers.heuristic.0.name)"    "scorers.heuristic.0.name"
    assert_eq "2"           "$(config_get scorers.heuristic.0.weight)"  "scorers.heuristic.0.weight"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_load_config
test_config_missing_key
test_config_default
test_load_config_list_items
test_load_config_deep_nesting

report_results
