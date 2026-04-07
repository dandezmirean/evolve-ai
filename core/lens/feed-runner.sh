#!/usr/bin/env bash
# core/lens/feed-runner.sh — Feed runner for evolve-ai lens system
# Reads lens.concerns from genome.yaml, runs feeds per concern.
# Replaces the old core/inbox/source-runner.sh with concern-aware dispatch.

SCRIPT_DIR_FEED_RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source adapters
source "$SCRIPT_DIR_FEED_RUNNER/adapters/rss.sh"
source "$SCRIPT_DIR_FEED_RUNNER/adapters/command.sh"
source "$SCRIPT_DIR_FEED_RUNNER/adapters/manual.sh"
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
# run_feeds <evolve_root> <genome_yaml>
# Reads lens.concerns from genome.yaml, for each concern runs its feeds.
# Feed output goes to per-concern inbox directories.
# ---------------------------------------------------------------------------
run_feeds() {
    local evolve_root="$1"
    local genome_yaml="$2"

    if [[ ! -f "$genome_yaml" ]]; then
        echo "[feed-runner] Genome file not found: $genome_yaml" >&2
        return 1
    fi

    # Parse lens.concerns from genome.yaml using awk
    # State machine: track which section we are in
    local in_lens=0
    local in_concerns=0
    local in_concern=0
    local in_feeds=0
    local in_feed=0
    local concern_name=""
    local feed_type="" feed_schedule="" feed_url="" feed_command="" feed_watch_dir=""
    local feeds_count=0
    local concerns_count=0

    while IFS= read -r line; do
        # Detect lens: section (top-level)
        if echo "$line" | grep -qE '^lens:'; then
            in_lens=1
            continue
        fi

        # Detect end of lens section (next top-level key)
        if [[ "$in_lens" -eq 1 ]] && echo "$line" | grep -qE '^[a-z]'; then
            # Process any remaining feed
            if [[ -n "$feed_type" && -n "$concern_name" ]]; then
                local output_dir="$evolve_root/inbox/$concern_name/pending"
                mkdir -p "$output_dir"
                _run_single_feed "$evolve_root" "$output_dir" \
                    "${concern_name}-feed-${feeds_count}" "$feed_type" "$feed_schedule" \
                    "$feed_url" "$feed_command" "$feed_watch_dir"
                feeds_count=$(( feeds_count + 1 ))
            fi
            in_lens=0
            in_concerns=0
            in_concern=0
            in_feeds=0
            in_feed=0
            continue
        fi

        if [[ "$in_lens" -eq 0 ]]; then
            continue
        fi

        # Detect concerns: section
        if echo "$line" | grep -qE '^\s+concerns:'; then
            in_concerns=1
            continue
        fi

        if [[ "$in_concerns" -eq 0 ]]; then
            continue
        fi

        # Detect new concern (  - name: ...)
        if echo "$line" | grep -qE '^\s{4}-\s*name:'; then
            # Process previous feed if any
            if [[ -n "$feed_type" && -n "$concern_name" ]]; then
                local output_dir="$evolve_root/inbox/$concern_name/pending"
                mkdir -p "$output_dir"
                _run_single_feed "$evolve_root" "$output_dir" \
                    "${concern_name}-feed-${feeds_count}" "$feed_type" "$feed_schedule" \
                    "$feed_url" "$feed_command" "$feed_watch_dir"
                feeds_count=$(( feeds_count + 1 ))
            fi

            concern_name="$(echo "$line" | sed 's/.*name:[[:space:]]*//' | tr -d '"')"
            in_concern=1
            in_feeds=0
            in_feed=0
            feed_type=""
            feed_schedule=""
            feed_url=""
            feed_command=""
            feed_watch_dir=""
            feeds_count=0
            (( concerns_count++ )) || true

            # Create per-concern directories
            mkdir -p "$evolve_root/inbox/$concern_name/pending"
            mkdir -p "$evolve_root/inbox/$concern_name/processed"
            continue
        fi

        if [[ "$in_concern" -eq 0 ]]; then
            continue
        fi

        # Detect feeds: section within a concern
        if echo "$line" | grep -qE '^\s{6}feeds:'; then
            in_feeds=1
            continue
        fi

        # Detect end of feeds section (next concern-level key like accepts_inbox)
        if [[ "$in_feeds" -eq 1 ]] && echo "$line" | grep -qE '^\s{6}[a-z]' && ! echo "$line" | grep -qE '^\s{6}feeds:' && ! echo "$line" | grep -qE '^\s{8}-\s'; then
            # Process current feed
            if [[ -n "$feed_type" ]]; then
                local output_dir="$evolve_root/inbox/$concern_name/pending"
                mkdir -p "$output_dir"
                _run_single_feed "$evolve_root" "$output_dir" \
                    "${concern_name}-feed-${feeds_count}" "$feed_type" "$feed_schedule" \
                    "$feed_url" "$feed_command" "$feed_watch_dir"
                feeds_count=$(( feeds_count + 1 ))
                feed_type=""
                feed_schedule=""
                feed_url=""
                feed_command=""
                feed_watch_dir=""
            fi
            in_feeds=0
            in_feed=0
            continue
        fi

        if [[ "$in_feeds" -eq 0 ]]; then
            continue
        fi

        # Detect new feed item (      - type: ...)
        if echo "$line" | grep -qE '^\s{8}-\s*type:'; then
            # Process previous feed
            if [[ -n "$feed_type" ]]; then
                local output_dir="$evolve_root/inbox/$concern_name/pending"
                mkdir -p "$output_dir"
                _run_single_feed "$evolve_root" "$output_dir" \
                    "${concern_name}-feed-${feeds_count}" "$feed_type" "$feed_schedule" \
                    "$feed_url" "$feed_command" "$feed_watch_dir"
                feeds_count=$(( feeds_count + 1 ))
            fi

            feed_type="$(echo "$line" | sed 's/.*type:[[:space:]]*//' | tr -d '"')"
            feed_schedule="daily"
            feed_url=""
            feed_command=""
            feed_watch_dir=""
            in_feed=1
            continue
        fi

        # Parse feed properties
        if [[ "$in_feed" -eq 1 ]]; then
            if echo "$line" | grep -qE '^\s+schedule:'; then
                feed_schedule="$(echo "$line" | sed 's/.*schedule:[[:space:]]*//' | tr -d '"')"
            elif echo "$line" | grep -qE '^\s+url:'; then
                feed_url="$(echo "$line" | sed 's/.*url:[[:space:]]*//' | tr -d '"')"
            elif echo "$line" | grep -qE '^\s+command:'; then
                feed_command="$(echo "$line" | sed 's/.*command:[[:space:]]*//' | tr -d '"')"
            elif echo "$line" | grep -qE '^\s+watch_dir:'; then
                feed_watch_dir="$(echo "$line" | sed 's/.*watch_dir:[[:space:]]*//' | tr -d '"')"
            fi
        fi
    done < "$genome_yaml"

    # Process final feed
    if [[ "$in_lens" -eq 1 && -n "$feed_type" && -n "$concern_name" ]]; then
        local output_dir="$evolve_root/inbox/$concern_name/pending"
        mkdir -p "$output_dir"
        _run_single_feed "$evolve_root" "$output_dir" \
            "${concern_name}-feed-${feeds_count}" "$feed_type" "$feed_schedule" \
            "$feed_url" "$feed_command" "$feed_watch_dir"
        feeds_count=$(( feeds_count + 1 ))
    fi

    echo "[feed-runner] Processed $concerns_count concern(s) from $genome_yaml"
}

# ---------------------------------------------------------------------------
# _run_single_feed <evolve_root> <output_dir> <name> <type> <schedule>
#                   <url> <command> <watch_dir>
# Internal helper — runs a single feed adapter after schedule check.
# ---------------------------------------------------------------------------
_run_single_feed() {
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
        echo "[feed-runner] Skipping '$name' — not yet due (schedule: $schedule)" >&2
        return 0
    fi

    echo "[feed-runner] Running feed '$name' (type: $type, schedule: $schedule)"

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
            echo "[feed-runner] Webhook feed '$name' is a listener — start separately" >&2
            ;;
        *)
            echo "[feed-runner] Unknown feed type '$type' for '$name'" >&2
            ;;
    esac

    # Mark as run
    source_mark_run "$evolve_root" "$name"
}
