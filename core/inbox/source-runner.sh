#!/usr/bin/env bash
# core/inbox/source-runner.sh — Source runner for evolve-ai
# Reads pack source configuration and runs the appropriate adapters.

SCRIPT_DIR_RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source adapters
source "$SCRIPT_DIR_RUNNER/sources/rss.sh"
source "$SCRIPT_DIR_RUNNER/sources/command.sh"
source "$SCRIPT_DIR_RUNNER/sources/manual.sh"
# webhook is not sourced by default — it runs as a standalone listener

# ---------------------------------------------------------------------------
# source_should_run <evolve_root> <source_name> <schedule>
# Checks if enough time has elapsed since last run for this source.
# Uses a simple timestamp file: inbox/sources/.last-run-{source_name}
# Returns 0 if the source should run, 1 if it ran too recently.
# Schedule values: "hourly", "daily", "weekly"
# ---------------------------------------------------------------------------
source_should_run() {
    local evolve_root="$1"
    local source_name="$2"
    local schedule="${3:-daily}"

    local last_run_file="$evolve_root/inbox/sources/.last-run-${source_name}"

    # If never run before, should run
    if [[ ! -f "$last_run_file" ]]; then
        return 0
    fi

    local last_run_ts
    last_run_ts="$(cat "$last_run_file")"

    if [[ -z "$last_run_ts" ]]; then
        return 0
    fi

    local now_ts
    now_ts="$(date +%s)"

    local elapsed=$(( now_ts - last_run_ts ))

    # Determine required interval in seconds
    local required_interval
    case "$schedule" in
        hourly)  required_interval=3600 ;;
        daily)   required_interval=86400 ;;
        weekly)  required_interval=604800 ;;
        *)       required_interval=86400 ;;
    esac

    if (( elapsed >= required_interval )); then
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# source_mark_run <evolve_root> <source_name>
# Updates the last-run timestamp for a source.
# ---------------------------------------------------------------------------
source_mark_run() {
    local evolve_root="$1"
    local source_name="$2"

    mkdir -p "$evolve_root/inbox/sources"

    local last_run_file="$evolve_root/inbox/sources/.last-run-${source_name}"
    date +%s > "$last_run_file"
}

# ---------------------------------------------------------------------------
# run_sources <evolve_root> <pack_yaml>
# Reads sources from pack.yaml, for each source:
#   1. Determine adapter type (rss, command, webhook, manual)
#   2. Check schedule against last run time
#   3. Call the adapter's fetch/run function with the source config
#   4. Log results
# ---------------------------------------------------------------------------
run_sources() {
    local evolve_root="$1"
    local pack_yaml="$2"

    if [[ ! -f "$pack_yaml" ]]; then
        echo "[source-runner] Pack file not found: $pack_yaml" >&2
        return 1
    fi

    local output_dir="$evolve_root/inbox/pending"
    mkdir -p "$output_dir"

    # Parse sources from pack.yaml using awk
    # We need: name, type, schedule, url (for RSS), command (for command), watch_dir (for manual)
    local in_sources=0
    local in_source=0
    local source_name="" source_type="" source_schedule="" source_url="" source_command="" source_watch_dir=""
    local sources_count=0

    while IFS= read -r line; do
        # Detect sources: section
        if echo "$line" | grep -qE '^sources:'; then
            in_sources=1
            continue
        fi

        # Detect end of sources section (next top-level key)
        if [[ "$in_sources" -eq 1 ]] && echo "$line" | grep -qE '^[a-z]'; then
            # Process last source if any
            if [[ -n "$source_name" ]]; then
                _run_single_source "$evolve_root" "$output_dir" \
                    "$source_name" "$source_type" "$source_schedule" \
                    "$source_url" "$source_command" "$source_watch_dir"
                (( sources_count++ )) || true
            fi
            in_sources=0
            continue
        fi

        if [[ "$in_sources" -eq 0 ]]; then
            continue
        fi

        # Detect new source item (  - name: ...)
        if echo "$line" | grep -qE '^\s*-\s*name:'; then
            # Process previous source
            if [[ -n "$source_name" ]]; then
                _run_single_source "$evolve_root" "$output_dir" \
                    "$source_name" "$source_type" "$source_schedule" \
                    "$source_url" "$source_command" "$source_watch_dir"
                (( sources_count++ )) || true
            fi
            # Start new source
            source_name="$(echo "$line" | sed 's/.*name:[[:space:]]*//' | tr -d '"')"
            source_type=""
            source_schedule="daily"
            source_url=""
            source_command=""
            source_watch_dir=""
            in_source=1
            continue
        fi

        # Parse source properties
        if [[ "$in_source" -eq 1 ]]; then
            if echo "$line" | grep -qE '^\s+type:'; then
                source_type="$(echo "$line" | sed 's/.*type:[[:space:]]*//' | tr -d '"')"
            elif echo "$line" | grep -qE '^\s+schedule:'; then
                source_schedule="$(echo "$line" | sed 's/.*schedule:[[:space:]]*//' | tr -d '"')"
            elif echo "$line" | grep -qE '^\s+url:'; then
                source_url="$(echo "$line" | sed 's/.*url:[[:space:]]*//' | tr -d '"')"
            elif echo "$line" | grep -qE '^\s+command:'; then
                source_command="$(echo "$line" | sed 's/.*command:[[:space:]]*//' | tr -d '"')"
            elif echo "$line" | grep -qE '^\s+watch_dir:'; then
                source_watch_dir="$(echo "$line" | sed 's/.*watch_dir:[[:space:]]*//' | tr -d '"')"
            fi
        fi
    done < "$pack_yaml"

    # Process final source
    if [[ "$in_sources" -eq 1 && -n "$source_name" ]]; then
        _run_single_source "$evolve_root" "$output_dir" \
            "$source_name" "$source_type" "$source_schedule" \
            "$source_url" "$source_command" "$source_watch_dir"
        (( sources_count++ )) || true
    fi

    echo "[source-runner] Processed $sources_count source(s) from $pack_yaml"
}

# ---------------------------------------------------------------------------
# _run_single_source <evolve_root> <output_dir> <name> <type> <schedule>
#                     <url> <command> <watch_dir>
# Internal helper — runs a single source adapter after schedule check.
# ---------------------------------------------------------------------------
_run_single_source() {
    local evolve_root="$1"
    local output_dir="$2"
    local name="$3"
    local type="$4"
    local schedule="$5"
    local url="$6"
    local command="$7"
    local watch_dir="$8"

    # Check schedule
    if ! source_should_run "$evolve_root" "$name" "$schedule"; then
        echo "[source-runner] Skipping '$name' — not yet due (schedule: $schedule)" >&2
        return 0
    fi

    echo "[source-runner] Running source '$name' (type: $type, schedule: $schedule)"

    case "$type" in
        rss)
            source_rss_fetch "$name" "$url" "$output_dir"
            ;;
        command)
            source_command_run "$name" "$command" "$output_dir"
            ;;
        manual)
            source_manual_scan "$watch_dir" "$output_dir"
            ;;
        webhook)
            echo "[source-runner] Webhook source '$name' is a listener — start separately" >&2
            ;;
        *)
            echo "[source-runner] Unknown source type '$type' for '$name'" >&2
            ;;
    esac

    # Mark as run
    source_mark_run "$evolve_root" "$name"
}
