#!/usr/bin/env bash
# core/inbox/sources/manual.sh — Manual/file drop adapter for evolve-ai
# Scans a watch directory for new files and copies them to inbox/pending/.

# ---------------------------------------------------------------------------
# source_manual_scan <watch_dir> <output_dir>
# Scans a watch directory for new files and copies them to output_dir
# (inbox/pending). This is the simplest adapter — it bridges a user-defined
# directory to the inbox.
# ---------------------------------------------------------------------------
source_manual_scan() {
    local watch_dir="$1"
    local output_dir="$2"

    if [[ ! -d "$watch_dir" ]]; then
        echo "[source:manual] Watch directory does not exist: $watch_dir" >&2
        return 0
    fi

    mkdir -p "$output_dir"

    local copied=0
    for f in "$watch_dir"/*; do
        if [[ -f "$f" ]]; then
            local basename
            basename="$(basename "$f")"

            # Skip dotfiles
            if [[ "$basename" == .* ]]; then
                continue
            fi

            # Only copy if not already in output_dir
            if [[ ! -f "$output_dir/$basename" ]]; then
                cp "$f" "$output_dir/$basename"
                (( copied++ )) || true
            fi
        fi
    done

    echo "[source:manual] Copied $copied new file(s) from $watch_dir"
}
