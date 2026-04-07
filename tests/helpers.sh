#!/usr/bin/env bash
# tests/helpers.sh — minimal bash test framework for evolve-ai

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Creates a temp dir and sets EVOLVE_ROOT to it
setup_test_env() {
    TEST_TMPDIR="$(mktemp -d)"
    export EVOLVE_ROOT="$TEST_TMPDIR"
}

# Removes the temp dir created by setup_test_env
teardown_test_env() {
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset EVOLVE_ROOT
    unset TEST_TMPDIR
}

# assert_eq expected actual msg
assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-assert_eq}"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: $msg"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: $msg"
        echo "        expected: $(printf '%q' "$expected")"
        echo "        actual:   $(printf '%q' "$actual")"
    fi
}

# assert_contains haystack needle msg
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-assert_contains}"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ "$haystack" == *"$needle"* ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: $msg"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: $msg"
        echo "        needle not found: $(printf '%q' "$needle")"
        echo "        in haystack:      $(printf '%q' "$haystack")"
    fi
}

# assert_file_exists path msg
assert_file_exists() {
    local path="$1"
    local msg="${2:-assert_file_exists}"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ -f "$path" ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: $msg"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: $msg"
        echo "        file not found: $path"
    fi
}

# assert_exit_code expected msg command...
assert_exit_code() {
    local expected="$1"
    local msg="$2"
    shift 2
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    "$@" >/dev/null 2>&1
    local actual=$?
    if [[ "$expected" -eq "$actual" ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: $msg"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: $msg"
        echo "        expected exit code: $expected"
        echo "        actual exit code:   $actual"
        echo "        command: $*"
    fi
}

# Prints pass/fail summary; returns 0 if all tests passed, 1 otherwise
report_results() {
    echo ""
    echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
    if [[ "$TESTS_FAILED" -eq 0 ]]; then
        echo "All tests passed."
        return 0
    else
        echo "Some tests FAILED."
        return 1
    fi
}
