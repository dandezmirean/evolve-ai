#!/usr/bin/env bash
# core/inbox/watcher.sh — Inbox watcher for evolve-ai (lens-aware)
# Polls per-concern inbox directories for new files and triggers directed runs.

SCRIPT_DIR_WATCHER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source manifest tracker
source "$SCRIPT_DIR_WATCHER/manifest.sh"

# ---------------------------------------------------------------------------
# inbox_watch <evolve_root> <poll_interval_seconds>
# Main polling loop. Runs forever (intended for background/cron):
#   1. Check all per-concern inbox dirs for new files
#   2. Skip dotfiles
#   3. For each new file, check manifest to see if it's been processed
#   4. If new files found: trigger a directed run
#   5. Sleep for poll_interval_seconds
#   6. Repeat
# ---------------------------------------------------------------------------
inbox_watch() {
    local evolve_root="$1"
    local poll_interval="${2:-300}"

    manifest_init "$evolve_root"
    mkdir -p "$evolve_root/inbox" "$evolve_root/inbox/sources"

    echo "[inbox] Watching $evolve_root/inbox/ (poll interval: ${poll_interval}s)"

    while true; do
        local new_count=0
        local new_items=""

        new_items="$(inbox_list_pending "$evolve_root")"
        if [[ -n "$new_items" ]]; then
            # Check each item against manifest
            while IFS= read -r item; do
                local basename
                basename="$(basename "$item")"
                # Build manifest key: concern_name/filename
                local concern_dir
                concern_dir="$(dirname "$item")"
                concern_dir="$(dirname "$concern_dir")"
                local concern_name
                concern_name="$(basename "$concern_dir")"
                local manifest_key="${concern_name}/${basename}"
                if manifest_is_new "$evolve_root" "$manifest_key"; then
                    (( new_count++ )) || true
                fi
            done <<< "$new_items"
        fi

        if (( new_count > 0 )); then
            echo "[inbox] Found $new_count new item(s) — triggering directed run"
            # Trigger directed run via orchestrator if available
            if declare -f run_pipeline >/dev/null 2>&1; then
                run_pipeline "$evolve_root" "directed"
            else
                echo "[inbox] STUB: run_pipeline not available — would trigger directed run for $new_count item(s)" >&2
            fi
        fi

        sleep "$poll_interval"
    done
}

# ---------------------------------------------------------------------------
# inbox_check <evolve_root>
# One-shot check. Returns 0 if new items in any concern inbox, 1 if none.
# Outputs count and filenames.
# ---------------------------------------------------------------------------
inbox_check() {
    local evolve_root="$1"

    manifest_init "$evolve_root"
    mkdir -p "$evolve_root/inbox"

    local new_count=0
    local new_files=""

    local pending
    pending="$(inbox_list_pending "$evolve_root")"

    if [[ -n "$pending" ]]; then
        while IFS= read -r item; do
            local basename
            basename="$(basename "$item")"
            # Build manifest key: concern_name/filename
            local concern_dir
            concern_dir="$(dirname "$item")"
            concern_dir="$(dirname "$concern_dir")"
            local concern_name
            concern_name="$(basename "$concern_dir")"
            local manifest_key="${concern_name}/${basename}"
            if manifest_is_new "$evolve_root" "$manifest_key"; then
                (( new_count++ )) || true
                new_files="${new_files:+$new_files
}$manifest_key"
            fi
        done <<< "$pending"
    fi

    echo "$new_count"
    if [[ -n "$new_files" ]]; then
        echo "$new_files"
    fi

    if (( new_count > 0 )); then
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# inbox_process_item <evolve_root> <item_path>
# Moves an inbox item from concern/pending/ to concern/processed/ and
# updates the manifest with a concern-namespaced key.
# ---------------------------------------------------------------------------
inbox_process_item() {
    local evolve_root="$1"
    local item_path="$2"

    local basename
    basename="$(basename "$item_path")"

    # Determine concern name from the path structure: inbox/{concern}/pending/{file}
    local pending_dir
    pending_dir="$(dirname "$item_path")"
    local concern_dir
    concern_dir="$(dirname "$pending_dir")"
    local concern_name
    concern_name="$(basename "$concern_dir")"

    local processed_dir="$concern_dir/processed"
    mkdir -p "$processed_dir"

    # Compute md5 before moving
    local md5
    md5="$(manifest_compute_md5 "$item_path")"

    # Move to processed
    mv "$item_path" "$processed_dir/$basename"

    # Update manifest with concern-namespaced key
    local manifest_key="${concern_name}/${basename}"
    manifest_update "$evolve_root" "$manifest_key" "$md5"

    echo "[inbox] Processed: $manifest_key"
}

# ---------------------------------------------------------------------------
# inbox_list_pending <evolve_root>
# Lists all pending inbox items across all concern directories
# (excluding dotfiles), one per line. Returns full paths.
# ---------------------------------------------------------------------------
inbox_list_pending() {
    local evolve_root="$1"
    local inbox_dir="$evolve_root/inbox"

    if [[ ! -d "$inbox_dir" ]]; then
        return 0
    fi

    for concern_dir in "$inbox_dir"/*/; do
        local pending_dir="$concern_dir/pending"
        if [[ ! -d "$pending_dir" ]]; then
            continue
        fi

        # Skip the special 'sources' directory (schedule tracking)
        local dirname
        dirname="$(basename "$concern_dir")"
        if [[ "$dirname" == "sources" ]]; then
            continue
        fi

        for f in "$pending_dir"/*; do
            if [[ -f "$f" ]]; then
                local basename
                basename="$(basename "$f")"
                # Skip dotfiles
                if [[ "$basename" == .* ]]; then
                    continue
                fi
                echo "$f"
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# inbox_list_processed <evolve_root>
# Lists all processed inbox items across all concerns, one per line.
# ---------------------------------------------------------------------------
inbox_list_processed() {
    local evolve_root="$1"
    local inbox_dir="$evolve_root/inbox"

    if [[ ! -d "$inbox_dir" ]]; then
        return 0
    fi

    for concern_dir in "$inbox_dir"/*/; do
        local processed_dir="$concern_dir/processed"
        if [[ ! -d "$processed_dir" ]]; then
            continue
        fi

        local dirname
        dirname="$(basename "$concern_dir")"
        if [[ "$dirname" == "sources" ]]; then
            continue
        fi

        for f in "$processed_dir"/*; do
            if [[ -f "$f" ]]; then
                echo "$f"
            fi
        done
    done
}
