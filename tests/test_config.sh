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
# Run all tests
# ---------------------------------------------------------------------------
test_load_config
test_config_missing_key
test_config_default

report_results
