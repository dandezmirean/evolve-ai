#!/usr/bin/env bash
# tests/test_inbox.sh — tests for inbox watcher, manifest, and source adapters

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=core/inbox/manifest.sh
source "$PROJECT_ROOT/core/inbox/manifest.sh"
# shellcheck source=core/inbox/watcher.sh
source "$PROJECT_ROOT/core/inbox/watcher.sh"
# shellcheck source=core/inbox/sources/command.sh
source "$PROJECT_ROOT/core/inbox/sources/command.sh"
# shellcheck source=core/inbox/sources/manual.sh
source "$PROJECT_ROOT/core/inbox/sources/manual.sh"
# shellcheck source=core/inbox/source-runner.sh
source "$PROJECT_ROOT/core/inbox/source-runner.sh"

# ---------------------------------------------------------------------------
# 1. manifest_init creates valid empty manifest
# ---------------------------------------------------------------------------
test_manifest_init() {
    echo "test_manifest_init"
    setup_test_env

    manifest_init "$EVOLVE_ROOT"

    local manifest_file="$EVOLVE_ROOT/inbox/.manifest.json"
    assert_file_exists "$manifest_file" "manifest file created"

    local files_count
    files_count="$(jq '.files | length' "$manifest_file")"
    assert_eq "0" "$files_count" "manifest starts with empty files object"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 2. manifest_update adds entry with md5 and timestamp
# ---------------------------------------------------------------------------
test_manifest_update() {
    echo "test_manifest_update"
    setup_test_env

    manifest_init "$EVOLVE_ROOT"
    manifest_update "$EVOLVE_ROOT" "test-file.md" "abc123def456"

    local manifest_file="$EVOLVE_ROOT/inbox/.manifest.json"
    local status
    status="$(jq -r '.files["test-file.md"].status' "$manifest_file")"
    assert_eq "processed" "$status" "manifest entry has status=processed"

    local md5
    md5="$(jq -r '.files["test-file.md"].md5' "$manifest_file")"
    assert_eq "abc123def456" "$md5" "manifest entry has correct md5"

    local ts
    ts="$(jq -r '.files["test-file.md"].processed_at' "$manifest_file")"
    assert_contains "$ts" "T" "manifest entry has ISO timestamp"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 3. manifest_is_new returns 0 for unknown file
# ---------------------------------------------------------------------------
test_manifest_is_new_unknown() {
    echo "test_manifest_is_new_unknown"
    setup_test_env

    manifest_init "$EVOLVE_ROOT"

    assert_exit_code 0 "unknown file is new" manifest_is_new "$EVOLVE_ROOT" "never-seen.md"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 4. manifest_is_new returns 1 for processed file
# ---------------------------------------------------------------------------
test_manifest_is_new_processed() {
    echo "test_manifest_is_new_processed"
    setup_test_env

    mkdir -p "$EVOLVE_ROOT/inbox/pending"
    echo "hello world" > "$EVOLVE_ROOT/inbox/pending/known.md"

    local md5
    md5="$(manifest_compute_md5 "$EVOLVE_ROOT/inbox/pending/known.md")"

    manifest_init "$EVOLVE_ROOT"
    manifest_update "$EVOLVE_ROOT" "known.md" "$md5"

    assert_exit_code 1 "processed file is not new" manifest_is_new "$EVOLVE_ROOT" "known.md"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 5. manifest_is_new returns 0 when file md5 has changed
# ---------------------------------------------------------------------------
test_manifest_is_new_md5_changed() {
    echo "test_manifest_is_new_md5_changed"
    setup_test_env

    mkdir -p "$EVOLVE_ROOT/inbox/pending"
    echo "original content" > "$EVOLVE_ROOT/inbox/pending/changed.md"

    manifest_init "$EVOLVE_ROOT"
    manifest_update "$EVOLVE_ROOT" "changed.md" "old_md5_value"

    # File has different content now, so md5 won't match "old_md5_value"
    assert_exit_code 0 "file with changed md5 is new" manifest_is_new "$EVOLVE_ROOT" "changed.md"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 6. manifest_check_deleted detects removed files
# ---------------------------------------------------------------------------
test_manifest_check_deleted() {
    echo "test_manifest_check_deleted"
    setup_test_env

    mkdir -p "$EVOLVE_ROOT/inbox/pending" "$EVOLVE_ROOT/inbox/processed"

    manifest_init "$EVOLVE_ROOT"
    manifest_update "$EVOLVE_ROOT" "still-here.md" "abc"
    manifest_update "$EVOLVE_ROOT" "gone.md" "def"

    # Create "still-here.md" but not "gone.md"
    echo "still here" > "$EVOLVE_ROOT/inbox/processed/still-here.md"

    local deleted_count
    deleted_count="$(manifest_check_deleted "$EVOLVE_ROOT")"
    assert_eq "1" "$deleted_count" "detected 1 deleted file"

    local status
    status="$(jq -r '.files["gone.md"].status' "$EVOLVE_ROOT/inbox/.manifest.json")"
    assert_eq "deleted" "$status" "gone.md marked as deleted"

    local still_status
    still_status="$(jq -r '.files["still-here.md"].status' "$EVOLVE_ROOT/inbox/.manifest.json")"
    assert_eq "processed" "$still_status" "still-here.md remains processed"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 7. manifest_compute_md5 returns correct hash
# ---------------------------------------------------------------------------
test_manifest_compute_md5() {
    echo "test_manifest_compute_md5"
    setup_test_env

    local test_file="$TEST_TMPDIR/test-hash.txt"
    echo "test content for hashing" > "$test_file"

    local expected
    expected="$(md5sum "$test_file" | awk '{print $1}')"

    local actual
    actual="$(manifest_compute_md5 "$test_file")"

    assert_eq "$expected" "$actual" "md5 hash matches expected"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 8. inbox_check returns 1 when inbox is empty
# ---------------------------------------------------------------------------
test_inbox_check_empty() {
    echo "test_inbox_check_empty"
    setup_test_env

    mkdir -p "$EVOLVE_ROOT/inbox/pending"

    assert_exit_code 1 "empty inbox returns 1" inbox_check "$EVOLVE_ROOT"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 9. inbox_check returns 0 when items present
# ---------------------------------------------------------------------------
test_inbox_check_with_items() {
    echo "test_inbox_check_with_items"
    setup_test_env

    mkdir -p "$EVOLVE_ROOT/inbox/pending"
    echo "new signal" > "$EVOLVE_ROOT/inbox/pending/signal-2026-04-06.md"

    assert_exit_code 0 "inbox with items returns 0" inbox_check "$EVOLVE_ROOT"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 10. inbox_list_pending excludes dotfiles
# ---------------------------------------------------------------------------
test_inbox_list_pending_excludes_dotfiles() {
    echo "test_inbox_list_pending_excludes_dotfiles"
    setup_test_env

    mkdir -p "$EVOLVE_ROOT/inbox/pending"
    echo "visible" > "$EVOLVE_ROOT/inbox/pending/visible.md"
    echo "hidden" > "$EVOLVE_ROOT/inbox/pending/.hidden.md"
    echo "also visible" > "$EVOLVE_ROOT/inbox/pending/also-visible.md"

    local listing
    listing="$(inbox_list_pending "$EVOLVE_ROOT")"

    local count
    count="$(echo "$listing" | wc -l)"
    assert_eq "2" "$count" "two files listed (dotfile excluded)"

    assert_contains "$listing" "visible.md" "visible.md is listed"
    assert_contains "$listing" "also-visible.md" "also-visible.md is listed"

    # Ensure dotfile is not in listing
    if echo "$listing" | grep -q '\.hidden'; then
        TESTS_RUN=$(( TESTS_RUN + 1 ))
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: dotfile should not appear in listing"
    else
        TESTS_RUN=$(( TESTS_RUN + 1 ))
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: dotfile excluded from listing"
    fi

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 11. inbox_process_item moves file and updates manifest
# ---------------------------------------------------------------------------
test_inbox_process_item() {
    echo "test_inbox_process_item"
    setup_test_env

    mkdir -p "$EVOLVE_ROOT/inbox/pending" "$EVOLVE_ROOT/inbox/processed"
    echo "item content" > "$EVOLVE_ROOT/inbox/pending/to-process.md"

    manifest_init "$EVOLVE_ROOT"
    inbox_process_item "$EVOLVE_ROOT" "$EVOLVE_ROOT/inbox/pending/to-process.md"

    # File should be moved
    if [[ -f "$EVOLVE_ROOT/inbox/pending/to-process.md" ]]; then
        TESTS_RUN=$(( TESTS_RUN + 1 ))
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: file still in pending"
    else
        TESTS_RUN=$(( TESTS_RUN + 1 ))
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: file removed from pending"
    fi

    assert_file_exists "$EVOLVE_ROOT/inbox/processed/to-process.md" "file moved to processed"

    local status
    status="$(jq -r '.files["to-process.md"].status' "$EVOLVE_ROOT/inbox/.manifest.json")"
    assert_eq "processed" "$status" "manifest updated with processed status"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 12. source_command_run creates file from command output
# ---------------------------------------------------------------------------
test_source_command_run_creates_file() {
    echo "test_source_command_run_creates_file"
    setup_test_env

    local output_dir="$TEST_TMPDIR/inbox/pending"
    mkdir -p "$output_dir"

    source_command_run "test-cmd" "echo 'hello from command'" "$output_dir"

    local today
    today="$(date +%Y-%m-%d)"
    local expected_file="$output_dir/test-cmd-${today}.md"

    assert_file_exists "$expected_file" "command output file created"

    local content
    content="$(cat "$expected_file")"
    assert_contains "$content" "hello from command" "file contains command output"
    assert_contains "$content" "Source: test-cmd (command)" "file contains source header"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 13. source_command_run skips when command produces no output
# ---------------------------------------------------------------------------
test_source_command_run_skips_empty() {
    echo "test_source_command_run_skips_empty"
    setup_test_env

    local output_dir="$TEST_TMPDIR/inbox/pending"
    mkdir -p "$output_dir"

    source_command_run "empty-cmd" "true" "$output_dir"

    local today
    today="$(date +%Y-%m-%d)"
    local expected_file="$output_dir/empty-cmd-${today}.md"

    if [[ -f "$expected_file" ]]; then
        TESTS_RUN=$(( TESTS_RUN + 1 ))
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: file should not be created for empty output"
    else
        TESTS_RUN=$(( TESTS_RUN + 1 ))
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: no file created for empty command output"
    fi

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 14. source_manual_scan copies new files to inbox
# ---------------------------------------------------------------------------
test_source_manual_scan() {
    echo "test_source_manual_scan"
    setup_test_env

    local watch_dir="$TEST_TMPDIR/watch"
    local output_dir="$TEST_TMPDIR/inbox/pending"
    mkdir -p "$watch_dir" "$output_dir"

    echo "file one" > "$watch_dir/one.md"
    echo "file two" > "$watch_dir/two.md"
    echo "hidden" > "$watch_dir/.hidden"

    source_manual_scan "$watch_dir" "$output_dir"

    assert_file_exists "$output_dir/one.md" "one.md copied to inbox"
    assert_file_exists "$output_dir/two.md" "two.md copied to inbox"

    if [[ -f "$output_dir/.hidden" ]]; then
        TESTS_RUN=$(( TESTS_RUN + 1 ))
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: dotfile should not be copied"
    else
        TESTS_RUN=$(( TESTS_RUN + 1 ))
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: dotfile not copied"
    fi

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 15. source_should_run returns 0 when source hasn't run before
# ---------------------------------------------------------------------------
test_source_should_run_never_run() {
    echo "test_source_should_run_never_run"
    setup_test_env

    mkdir -p "$EVOLVE_ROOT/inbox/sources"

    assert_exit_code 0 "source that never ran should run" \
        source_should_run "$EVOLVE_ROOT" "test-source" "daily"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# 16. source_should_run returns 1 when source ran recently
# ---------------------------------------------------------------------------
test_source_should_run_recently() {
    echo "test_source_should_run_recently"
    setup_test_env

    mkdir -p "$EVOLVE_ROOT/inbox/sources"

    # Mark source as having just run
    source_mark_run "$EVOLVE_ROOT" "test-source"

    assert_exit_code 1 "recently-run source should not run" \
        source_should_run "$EVOLVE_ROOT" "test-source" "daily"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_manifest_init
test_manifest_update
test_manifest_is_new_unknown
test_manifest_is_new_processed
test_manifest_is_new_md5_changed
test_manifest_check_deleted
test_manifest_compute_md5
test_inbox_check_empty
test_inbox_check_with_items
test_inbox_list_pending_excludes_dotfiles
test_inbox_process_item
test_source_command_run_creates_file
test_source_command_run_skips_empty
test_source_manual_scan
test_source_should_run_never_run
test_source_should_run_recently

report_results
