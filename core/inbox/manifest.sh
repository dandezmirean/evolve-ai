#!/usr/bin/env bash
# core/inbox/manifest.sh — Manifest tracker for inbox items
# Tracks processed files using md5sum. Stores state in inbox/.manifest.json.
# Keys are concern-namespaced: "{concern_name}/{filename}" for per-concern items.

SCRIPT_DIR_MANIFEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# manifest_init <evolve_root>
# Creates empty manifest if it doesn't exist.
# Format: {"files": {}} where each key is a filename and value is
# {"md5": "...", "processed_at": "...", "status": "processed|deleted"}
# ---------------------------------------------------------------------------
manifest_init() {
    local evolve_root="$1"
    local manifest_file="$evolve_root/inbox/.manifest.json"

    mkdir -p "$evolve_root/inbox"

    if [[ ! -f "$manifest_file" ]]; then
        echo '{"files": {}}' | jq . > "$manifest_file"
    fi
}

# ---------------------------------------------------------------------------
# manifest_update <evolve_root> <filename> <md5>
# Marks a file as processed with its md5 hash and current timestamp.
# filename can be a concern-namespaced key: "concern-name/file.md"
# ---------------------------------------------------------------------------
manifest_update() {
    local evolve_root="$1"
    local filename="$2"
    local md5="$3"
    local manifest_file="$evolve_root/inbox/.manifest.json"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    manifest_init "$evolve_root"

    local tmp_file
    tmp_file="$(mktemp)"
    jq --arg fn "$filename" \
       --arg md5 "$md5" \
       --arg ts "$timestamp" \
       '.files[$fn] = {"md5": $md5, "processed_at": $ts, "status": "processed"}' \
       "$manifest_file" > "$tmp_file" && mv "$tmp_file" "$manifest_file"
}

# ---------------------------------------------------------------------------
# manifest_is_new <evolve_root> <filename>
# Returns 0 if the file is new (not in manifest or md5 changed).
# Returns 1 if already processed with same md5.
# filename can be concern-namespaced: "concern-name/file.md"
# ---------------------------------------------------------------------------
manifest_is_new() {
    local evolve_root="$1"
    local filename="$2"
    local manifest_file="$evolve_root/inbox/.manifest.json"

    manifest_init "$evolve_root"

    # Check if file exists in manifest
    local entry_status
    entry_status="$(jq -r --arg fn "$filename" '.files[$fn].status // "missing"' "$manifest_file")"

    if [[ "$entry_status" == "missing" ]]; then
        return 0
    fi

    # File exists in manifest — check if md5 has changed
    local stored_md5
    stored_md5="$(jq -r --arg fn "$filename" '.files[$fn].md5 // ""' "$manifest_file")"

    # Compute current md5 — resolve file path from the key
    # Key format: "concern-name/file.md" -> inbox/concern-name/pending/file.md
    #          or plain "file.md" -> inbox/pending/file.md (legacy)
    local current_md5=""
    local file_path=""

    if [[ "$filename" == */* ]]; then
        # Concern-namespaced key
        local concern_name="${filename%%/*}"
        local base_name="${filename#*/}"
        file_path="$evolve_root/inbox/$concern_name/pending/$base_name"
        if [[ -f "$file_path" ]]; then
            current_md5="$(manifest_compute_md5 "$file_path")"
        else
            file_path="$evolve_root/inbox/$concern_name/processed/$base_name"
            if [[ -f "$file_path" ]]; then
                current_md5="$(manifest_compute_md5 "$file_path")"
            fi
        fi
    else
        # Legacy flat key
        file_path="$evolve_root/inbox/pending/$filename"
        if [[ -f "$file_path" ]]; then
            current_md5="$(manifest_compute_md5 "$file_path")"
        else
            file_path="$evolve_root/inbox/processed/$filename"
            if [[ -f "$file_path" ]]; then
                current_md5="$(manifest_compute_md5 "$file_path")"
            fi
        fi
    fi

    if [[ -n "$current_md5" && "$current_md5" != "$stored_md5" ]]; then
        # md5 changed — treat as new
        return 0
    fi

    # Same md5 or file not found on disk — already processed
    return 1
}

# ---------------------------------------------------------------------------
# manifest_check_deleted <evolve_root>
# Scans manifest for files that no longer exist in inbox directories.
# Marks them as "deleted" in manifest.
# Outputs the count of newly-detected deletions.
# ---------------------------------------------------------------------------
manifest_check_deleted() {
    local evolve_root="$1"
    local manifest_file="$evolve_root/inbox/.manifest.json"

    manifest_init "$evolve_root"

    local deleted_count=0

    # Get all filenames from manifest that are not already marked deleted
    local filenames
    filenames="$(jq -r '.files | to_entries[] | select(.value.status != "deleted") | .key' "$manifest_file")"

    if [[ -z "$filenames" ]]; then
        echo "0"
        return 0
    fi

    while IFS= read -r filename; do
        local found=0

        if [[ "$filename" == */* ]]; then
            # Concern-namespaced key
            local concern_name="${filename%%/*}"
            local base_name="${filename#*/}"
            if [[ -f "$evolve_root/inbox/$concern_name/pending/$base_name" ]] || \
               [[ -f "$evolve_root/inbox/$concern_name/processed/$base_name" ]]; then
                found=1
            fi
        else
            # Legacy flat key
            if [[ -f "$evolve_root/inbox/pending/$filename" ]] || \
               [[ -f "$evolve_root/inbox/processed/$filename" ]]; then
                found=1
            fi
        fi

        if [[ "$found" -eq 0 ]]; then
            # File is gone — mark as deleted
            local tmp_file
            tmp_file="$(mktemp)"
            local timestamp
            timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            jq --arg fn "$filename" \
               --arg ts "$timestamp" \
               '.files[$fn].status = "deleted" | .files[$fn].deleted_at = $ts' \
               "$manifest_file" > "$tmp_file" && mv "$tmp_file" "$manifest_file"
            (( deleted_count++ )) || true
        fi
    done <<< "$filenames"

    echo "$deleted_count"
}

# ---------------------------------------------------------------------------
# manifest_get_stats <evolve_root>
# Outputs JSON with: total_processed, total_deleted, total_pending
# ---------------------------------------------------------------------------
manifest_get_stats() {
    local evolve_root="$1"
    local manifest_file="$evolve_root/inbox/.manifest.json"

    manifest_init "$evolve_root"

    local total_processed
    total_processed="$(jq '[.files | to_entries[] | select(.value.status == "processed")] | length' "$manifest_file")"

    local total_deleted
    total_deleted="$(jq '[.files | to_entries[] | select(.value.status == "deleted")] | length' "$manifest_file")"

    # Count files in per-concern pending/ dirs that are not in manifest as processed
    local total_pending=0

    # Scan all concern directories
    if [[ -d "$evolve_root/inbox" ]]; then
        for concern_dir in "$evolve_root/inbox"/*/; do
            local pending_dir="$concern_dir/pending"
            if [[ ! -d "$pending_dir" ]]; then
                continue
            fi

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
                    local manifest_key="${dirname}/${basename}"
                    if manifest_is_new "$evolve_root" "$manifest_key"; then
                        (( total_pending++ )) || true
                    fi
                fi
            done
        done
    fi

    jq -n --argjson processed "$total_processed" \
          --argjson deleted "$total_deleted" \
          --argjson pending "$total_pending" \
          '{"total_processed": $processed, "total_deleted": $deleted, "total_pending": $pending}'
}

# ---------------------------------------------------------------------------
# manifest_compute_md5 <file_path>
# Outputs md5sum of a file (just the hash, not the filename).
# ---------------------------------------------------------------------------
manifest_compute_md5() {
    local file_path="$1"
    md5sum "$file_path" | awk '{print $1}'
}
