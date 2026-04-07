#!/usr/bin/env bash
# tests/test_notifications.sh — tests for core/notifications/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
# shellcheck source=core/notifications/engine.sh
source "$PROJECT_ROOT/core/notifications/engine.sh"

# ---------------------------------------------------------------------------
# test_notify_stdout_outputs_with_timestamp
# ---------------------------------------------------------------------------
test_notify_stdout_outputs_with_timestamp() {
    echo "test_notify_stdout_outputs_with_timestamp"
    setup_test_env

    local output
    output="$(notify_stdout "hello world")"

    # Should contain the message
    assert_contains "$output" "hello world" "stdout contains message"

    # Should have a timestamp in [YYYY-MM-DD HH:MM:SS] format
    assert_contains "$output" "[20" "stdout has timestamp prefix"
    assert_contains "$output" "]" "stdout has closing bracket"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_notify_routes_to_stdout
# ---------------------------------------------------------------------------
test_notify_routes_to_stdout() {
    echo "test_notify_routes_to_stdout"
    setup_test_env

    # Create a minimal config with stdout notification
    local yaml="$TEST_TMPDIR/evolve.yaml"
    cat > "$yaml" <<'YAML'
version: "1.0.0"

notifications:
  - type: "stdout"

provider:
  type: "claude-max"
YAML

    load_notification_config "$yaml"

    local output
    output="$(notify "test routing message")"

    assert_contains "$output" "test routing message" "notify routes to stdout"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_notify_default_stdout_when_no_config
# ---------------------------------------------------------------------------
test_notify_default_stdout_when_no_config() {
    echo "test_notify_default_stdout_when_no_config"
    setup_test_env

    # Reset notification entries by loading a nonexistent file
    load_notification_config "/nonexistent/evolve.yaml"

    local output
    output="$(notify "fallback message")"

    assert_contains "$output" "fallback message" "notify defaults to stdout without config"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_notify_no_crash_on_empty_entries
# ---------------------------------------------------------------------------
test_notify_no_crash_on_empty_entries() {
    echo "test_notify_no_crash_on_empty_entries"
    setup_test_env

    # Clear entries and call notify directly — should not crash
    _NOTIFICATION_ENTRIES=()
    local output
    output="$(notify "should not crash")"

    assert_contains "$output" "should not crash" "notify handles empty entries gracefully"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_load_notification_config_multiple_providers
# ---------------------------------------------------------------------------
test_load_notification_config_multiple_providers() {
    echo "test_load_notification_config_multiple_providers"
    setup_test_env

    local yaml="$TEST_TMPDIR/evolve.yaml"
    cat > "$yaml" <<'YAML'
version: "1.0.0"

notifications:
  - type: "stdout"
  - type: "telegram"
    bot_token: "123:ABC"
    chat_id: "456"
  - type: "slack"
    webhook_url: "https://hooks.slack.com/test"

provider:
  type: "claude-max"
YAML

    load_notification_config "$yaml"

    assert_eq 3 "${#_NOTIFICATION_ENTRIES[@]}" "parsed 3 notification entries"
    assert_eq "stdout||" "${_NOTIFICATION_ENTRIES[0]}" "first entry is stdout"
    assert_eq "telegram|123:ABC|456" "${_NOTIFICATION_ENTRIES[1]}" "second entry is telegram with params"
    assert_eq "slack|https://hooks.slack.com/test|" "${_NOTIFICATION_ENTRIES[2]}" "third entry is slack with webhook"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_load_notification_config_notifications_at_end_of_file
# ---------------------------------------------------------------------------
test_load_notification_config_notifications_at_end_of_file() {
    echo "test_load_notification_config_notifications_at_end_of_file"
    setup_test_env

    local yaml="$TEST_TMPDIR/evolve.yaml"
    cat > "$yaml" <<'YAML'
version: "1.0.0"

provider:
  type: "claude-max"

notifications:
  - type: "discord"
    webhook_url: "https://discord.com/api/webhooks/test"
YAML

    load_notification_config "$yaml"

    assert_eq 1 "${#_NOTIFICATION_ENTRIES[@]}" "parsed 1 notification entry at end of file"
    assert_eq "discord|https://discord.com/api/webhooks/test|" "${_NOTIFICATION_ENTRIES[0]}" "discord entry with webhook"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_load_notification_config_env_vars
# ---------------------------------------------------------------------------
test_load_notification_config_env_vars() {
    echo "test_load_notification_config_env_vars"
    setup_test_env

    local yaml="$TEST_TMPDIR/evolve.yaml"
    cat > "$yaml" <<'YAML'
version: "1.0.0"

notifications:
  - type: "telegram"
    bot_token_env: "TEST_BOT_TOKEN"
    chat_id_env: "TEST_CHAT_ID"
  - type: "slack"
    webhook_url_env: "TEST_SLACK_WEBHOOK"

provider:
  type: "claude-max"
YAML

    export TEST_BOT_TOKEN="my-secret-token"
    export TEST_CHAT_ID="12345"
    export TEST_SLACK_WEBHOOK="https://hooks.slack.com/secret"

    load_notification_config "$yaml"

    assert_eq 2 "${#_NOTIFICATION_ENTRIES[@]}" "parsed 2 notification entries"
    assert_eq "telegram|my-secret-token|12345" "${_NOTIFICATION_ENTRIES[0]}" "telegram env vars resolved"
    assert_eq "slack|https://hooks.slack.com/secret|" "${_NOTIFICATION_ENTRIES[1]}" "slack env var resolved"

    unset TEST_BOT_TOKEN TEST_CHAT_ID TEST_SLACK_WEBHOOK
    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_notification_config_init_format_roundtrip
# ---------------------------------------------------------------------------
test_notification_config_init_format_roundtrip() {
    echo "test_notification_config_init_format_roundtrip"
    setup_test_env

    # This is exactly what evolve init generates for Telegram
    local yaml="$TEST_TMPDIR/evolve.yaml"
    cat > "$yaml" <<'YAML'
version: "1.0.0"

notifications:
  - type: "telegram"
    bot_token_env: "EVOLVE_TG_BOT_TOKEN"
    chat_id_env: "EVOLVE_TG_CHAT_ID"
  - type: "slack"
    webhook_url_env: "EVOLVE_SLACK_WEBHOOK"
  - type: "discord"
    webhook_url_env: "EVOLVE_DISCORD_WEBHOOK"
YAML

    export EVOLVE_TG_BOT_TOKEN="tg-token-123"
    export EVOLVE_TG_CHAT_ID="tg-chat-456"
    export EVOLVE_SLACK_WEBHOOK="https://hooks.slack.com/services/xxx"
    export EVOLVE_DISCORD_WEBHOOK="https://discord.com/api/webhooks/yyy"

    load_notification_config "$yaml"

    assert_eq 3 "${#_NOTIFICATION_ENTRIES[@]}" "parsed 3 init-format entries"
    assert_eq "telegram|tg-token-123|tg-chat-456" "${_NOTIFICATION_ENTRIES[0]}" "telegram init format roundtrip"
    assert_eq "slack|https://hooks.slack.com/services/xxx|" "${_NOTIFICATION_ENTRIES[1]}" "slack init format roundtrip"
    assert_eq "discord|https://discord.com/api/webhooks/yyy|" "${_NOTIFICATION_ENTRIES[2]}" "discord init format roundtrip"

    unset EVOLVE_TG_BOT_TOKEN EVOLVE_TG_CHAT_ID EVOLVE_SLACK_WEBHOOK EVOLVE_DISCORD_WEBHOOK
    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_notification_config_missing_env_var
# ---------------------------------------------------------------------------
test_notification_config_missing_env_var() {
    echo "test_notification_config_missing_env_var"
    setup_test_env

    local yaml="$TEST_TMPDIR/evolve.yaml"
    cat > "$yaml" <<'YAML'
version: "1.0.0"

notifications:
  - type: "telegram"
    bot_token_env: "NONEXISTENT_VAR"
    chat_id_env: "ALSO_NONEXISTENT"
YAML

    unset NONEXISTENT_VAR 2>/dev/null || true
    unset ALSO_NONEXISTENT 2>/dev/null || true

    load_notification_config "$yaml"

    # Should parse the entry but with empty resolved values
    assert_eq 1 "${#_NOTIFICATION_ENTRIES[@]}" "parsed 1 entry with missing env vars"
    assert_eq "telegram||" "${_NOTIFICATION_ENTRIES[0]}" "missing env vars resolve to empty"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_notify_stdout_outputs_with_timestamp
test_notify_routes_to_stdout
test_notify_default_stdout_when_no_config
test_notify_no_crash_on_empty_entries
test_load_notification_config_multiple_providers
test_load_notification_config_notifications_at_end_of_file
test_load_notification_config_env_vars
test_notification_config_init_format_roundtrip
test_notification_config_missing_env_var

report_results
