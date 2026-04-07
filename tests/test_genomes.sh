#!/usr/bin/env bash
# tests/test_genomes.sh — tests for core/genomes/validator.sh and core/init.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVOLVE_ROOT="$PROJECT_ROOT"

source "$SCRIPT_DIR/helpers.sh"
source "$PROJECT_ROOT/core/genomes/validator.sh"
source "$PROJECT_ROOT/core/init.sh"

# Helper: assert exit code without set -e interference
# Runs command in a subshell to isolate the exit code.
_assert_exit() {
    local expected="$1"
    local msg="$2"
    shift 2
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    local actual
    ("$@") >/dev/null 2>&1 && actual=0 || actual=$?
    if [[ "$expected" -eq "$actual" ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: $msg"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: $msg"
        echo "        expected exit code: $expected"
        echo "        actual exit code:   $actual"
    fi
}

# ---------------------------------------------------------------------------
# test_validate_genome_valid
# validate_genome returns 0 for a valid genome (infrastructure)
# ---------------------------------------------------------------------------
test_validate_genome_valid() {
    echo "test_validate_genome_valid"

    _assert_exit 0 "infrastructure genome is valid" \
        validate_genome "$PROJECT_ROOT/genomes/infrastructure"

    _assert_exit 0 "agent-harness genome is valid" \
        validate_genome "$PROJECT_ROOT/genomes/agent-harness"

    _assert_exit 0 "codebase genome is valid" \
        validate_genome "$PROJECT_ROOT/genomes/codebase"
}

# ---------------------------------------------------------------------------
# test_validate_genome_no_yaml
# validate_genome returns 1 for a directory with no genome.yaml
# ---------------------------------------------------------------------------
test_validate_genome_no_yaml() {
    echo "test_validate_genome_no_yaml"
    setup_test_env

    mkdir -p "$TEST_TMPDIR/empty-genome"

    _assert_exit 1 "genome without genome.yaml is invalid" \
        validate_genome "$TEST_TMPDIR/empty-genome"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_validate_genome_missing_fields
# validate_genome returns 1 for a genome.yaml missing required fields
# ---------------------------------------------------------------------------
test_validate_genome_missing_fields() {
    echo "test_validate_genome_missing_fields"
    setup_test_env

    mkdir -p "$TEST_TMPDIR/bad-genome"
    cat > "$TEST_TMPDIR/bad-genome/genome.yaml" <<'EOF'
name: "incomplete"
description: "missing most fields"
EOF

    _assert_exit 1 "genome missing required fields is invalid" \
        validate_genome "$TEST_TMPDIR/bad-genome"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_list_genomes
# list_genomes finds all 3 built-in genomes
# ---------------------------------------------------------------------------
test_list_genomes() {
    echo "test_list_genomes"

    local output
    output="$(list_genomes "$PROJECT_ROOT/genomes")"

    assert_contains "$output" "infrastructure" "list_genomes contains infrastructure"
    assert_contains "$output" "agent-harness" "list_genomes contains agent-harness"
    assert_contains "$output" "codebase" "list_genomes contains codebase"

    local count
    count="$(echo "$output" | wc -l)"
    assert_eq "3" "$count" "list_genomes returns exactly 3 genomes"
}

# ---------------------------------------------------------------------------
# test_load_genome
# load_genome sets GENOME_NAME correctly
# ---------------------------------------------------------------------------
test_load_genome() {
    echo "test_load_genome"

    load_genome "$PROJECT_ROOT/genomes/infrastructure"
    assert_eq "infrastructure" "$GENOME_NAME" "GENOME_NAME is infrastructure"
    assert_contains "$GENOME_DESCRIPTION" "infrastructure" "GENOME_DESCRIPTION contains infrastructure"

    load_genome "$PROJECT_ROOT/genomes/agent-harness"
    assert_eq "agent-harness" "$GENOME_NAME" "GENOME_NAME is agent-harness"

    load_genome "$PROJECT_ROOT/genomes/codebase"
    assert_eq "codebase" "$GENOME_NAME" "GENOME_NAME is codebase"
}

# ---------------------------------------------------------------------------
# test_memory_templates_exist
# All memory template files exist
# ---------------------------------------------------------------------------
test_memory_templates_exist() {
    echo "test_memory_templates_exist"

    local templates_dir="$PROJECT_ROOT/core/memory/templates"

    assert_file_exists "$templates_dir/MEMORY.md"         "MEMORY.md template exists"
    assert_file_exists "$templates_dir/changelog.md"      "changelog.md template exists"
    assert_file_exists "$templates_dir/changelog-archive.md" "changelog-archive.md template exists"
    assert_file_exists "$templates_dir/vision.md"         "vision.md template exists"
    assert_file_exists "$templates_dir/big-bets-log.md"   "big-bets-log.md template exists"
    assert_file_exists "$templates_dir/strategy-history.md" "strategy-history.md template exists"
    assert_file_exists "$templates_dir/impact-log.md"     "impact-log.md template exists"
}

# ---------------------------------------------------------------------------
# test_init_memory
# init_memory copies templates correctly
# ---------------------------------------------------------------------------
test_init_memory() {
    echo "test_init_memory"
    setup_test_env

    # Create the core/memory/templates structure in the temp env
    # init_memory uses _INIT_DIR which points to the real core/ dir
    init_memory "$TEST_TMPDIR"

    assert_file_exists "$TEST_TMPDIR/memory/MEMORY.md"         "MEMORY.md copied"
    assert_file_exists "$TEST_TMPDIR/memory/changelog.md"      "changelog.md copied"
    assert_file_exists "$TEST_TMPDIR/memory/changelog-archive.md" "changelog-archive.md copied"
    assert_file_exists "$TEST_TMPDIR/memory/vision.md"         "vision.md copied"
    assert_file_exists "$TEST_TMPDIR/memory/big-bets-log.md"   "big-bets-log.md copied"
    assert_file_exists "$TEST_TMPDIR/memory/strategy-history.md" "strategy-history.md copied"
    assert_file_exists "$TEST_TMPDIR/memory/impact-log.md"     "impact-log.md copied"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_init_inbox
# init_inbox creates the right directory structure
# ---------------------------------------------------------------------------
test_init_inbox() {
    echo "test_init_inbox"
    setup_test_env

    init_inbox "$TEST_TMPDIR" >/dev/null

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ -d "$TEST_TMPDIR/inbox/pending" ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: inbox/pending directory created"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: inbox/pending directory not created"
    fi

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ -d "$TEST_TMPDIR/inbox/processed" ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: inbox/processed directory created"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: inbox/processed directory not created"
    fi

    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ -d "$TEST_TMPDIR/inbox/sources" ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: inbox/sources directory created"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: inbox/sources directory not created"
    fi

    teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_validate_genome_valid
test_validate_genome_no_yaml
test_validate_genome_missing_fields
test_list_genomes
test_load_genome
test_memory_templates_exist
test_init_memory
test_init_inbox

report_results
