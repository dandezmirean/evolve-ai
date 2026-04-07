#!/usr/bin/env bash
# core/memory/manager.sh — Memory file management for evolve-ai
set -euo pipefail

_MEMORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MEMORY_TEMPLATES_DIR="$_MEMORY_DIR/templates"

# ---------------------------------------------------------------------------
# memory_init <evolve_root>
# Creates memory/ directory and copies templates if not present.
# ---------------------------------------------------------------------------
memory_init() {
    local evolve_root="$1"
    local memory_dir="$evolve_root/memory"

    mkdir -p "$memory_dir"

    # Copy templates if they exist and target files don't
    if [[ -d "$_MEMORY_TEMPLATES_DIR" ]]; then
        for tpl in "$_MEMORY_TEMPLATES_DIR"/*; do
            if [[ -f "$tpl" ]]; then
                local basename
                basename="$(basename "$tpl")"
                if [[ ! -f "$memory_dir/$basename" ]]; then
                    cp "$tpl" "$memory_dir/$basename"
                fi
            fi
        done
    fi

    # Ensure essential files exist (fallback if no templates)
    for file in MEMORY.md changelog.md metrics.jsonl source-credibility.jsonl; do
        if [[ ! -f "$memory_dir/$file" ]]; then
            touch "$memory_dir/$file"
        fi
    done

    return 0
}

# ---------------------------------------------------------------------------
# memory_read <evolve_root> <file_name>
# Reads and outputs a memory file.
# ---------------------------------------------------------------------------
memory_read() {
    local evolve_root="$1"
    local file_name="$2"
    local memory_file="$evolve_root/memory/$file_name"

    if [[ ! -f "$memory_file" ]]; then
        echo "memory_read: file not found: $memory_file" >&2
        return 1
    fi

    cat "$memory_file"
}

# ---------------------------------------------------------------------------
# memory_append <evolve_root> <file_name> <content>
# Appends content to a memory file.
# ---------------------------------------------------------------------------
memory_append() {
    local evolve_root="$1"
    local file_name="$2"
    local content="$3"
    local memory_file="$evolve_root/memory/$file_name"

    mkdir -p "$evolve_root/memory"
    printf '%s\n' "$content" >> "$memory_file"
}

# ---------------------------------------------------------------------------
# memory_write <evolve_root> <file_name> <content>
# Overwrites a memory file.
# ---------------------------------------------------------------------------
memory_write() {
    local evolve_root="$1"
    local file_name="$2"
    local content="$3"
    local memory_file="$evolve_root/memory/$file_name"

    mkdir -p "$evolve_root/memory"
    printf '%s\n' "$content" > "$memory_file"
}

# ---------------------------------------------------------------------------
# memory_prune_changelog <evolve_root> <max_age_days>
# Moves entries older than max_age_days from changelog.md to
# changelog-archive.md. Entries start with [LANDED|REVERTED|KILLED].
# ---------------------------------------------------------------------------
memory_prune_changelog() {
    local evolve_root="$1"
    local max_age_days="$2"
    local changelog="$evolve_root/memory/changelog.md"
    local archive="$evolve_root/memory/changelog-archive.md"

    if [[ ! -f "$changelog" ]]; then
        return 0
    fi

    local cutoff_epoch
    cutoff_epoch="$(date -d "-${max_age_days} days" +%s 2>/dev/null)" || {
        echo "memory_prune_changelog: could not compute cutoff date" >&2
        return 1
    }

    local keep_lines=""
    local archive_lines=""
    local current_entry=""
    local current_date_epoch=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Check if line starts a new entry
        if printf '%s' "$line" | grep -qE '^\[(LANDED|REVERTED|KILLED)\]'; then
            # Flush previous entry
            if [[ -n "$current_entry" ]]; then
                if [[ -n "$current_date_epoch" ]] && (( current_date_epoch < cutoff_epoch )); then
                    archive_lines="${archive_lines}${current_entry}"
                else
                    keep_lines="${keep_lines}${current_entry}"
                fi
            fi

            # Start new entry
            current_entry="${line}"$'\n'

            # Try to extract date from entry (format: YYYY-MM-DD somewhere in the line)
            local extracted_date
            extracted_date="$(printf '%s' "$line" | grep -oP '\d{4}-\d{2}-\d{2}' | head -1)" || true
            if [[ -n "$extracted_date" ]]; then
                current_date_epoch="$(date -d "$extracted_date" +%s 2>/dev/null)" || current_date_epoch=""
            else
                current_date_epoch=""
            fi
        else
            # Continuation line of current entry
            if [[ -n "$current_entry" ]]; then
                current_entry="${current_entry}${line}"$'\n'
            else
                # Lines before any entry — keep them
                keep_lines="${keep_lines}${line}"$'\n'
            fi
        fi
    done < "$changelog"

    # Flush last entry
    if [[ -n "$current_entry" ]]; then
        if [[ -n "$current_date_epoch" ]] && (( current_date_epoch < cutoff_epoch )); then
            archive_lines="${archive_lines}${current_entry}"
        else
            keep_lines="${keep_lines}${current_entry}"
        fi
    fi

    # Write archive (append to existing)
    if [[ -n "$archive_lines" ]]; then
        printf '%s' "$archive_lines" >> "$archive"
    fi

    # Write updated changelog
    printf '%s' "$keep_lines" > "$changelog"

    return 0
}

# ---------------------------------------------------------------------------
# memory_get_metrics <evolve_root>
# Outputs the contents of metrics.jsonl.
# ---------------------------------------------------------------------------
memory_get_metrics() {
    local evolve_root="$1"
    local metrics_file="$evolve_root/memory/metrics.jsonl"

    if [[ ! -f "$metrics_file" ]]; then
        return 0
    fi

    cat "$metrics_file"
}

# ---------------------------------------------------------------------------
# memory_append_metric <evolve_root> <metric_json>
# Appends a single JSON line to metrics.jsonl with dedup by id.
# ---------------------------------------------------------------------------
memory_append_metric() {
    local evolve_root="$1"
    local metric_json="$2"
    local metrics_file="$evolve_root/memory/metrics.jsonl"

    mkdir -p "$evolve_root/memory"

    # Extract id from the metric
    local metric_id
    metric_id="$(printf '%s' "$metric_json" | jq -r '.id // empty')" || {
        # No id — just append
        printf '%s\n' "$metric_json" >> "$metrics_file"
        return 0
    }

    if [[ -z "$metric_id" ]]; then
        printf '%s\n' "$metric_json" >> "$metrics_file"
        return 0
    fi

    # Dedup check: composite key id + run_date
    local run_date
    run_date="$(printf '%s' "$metric_json" | jq -r '.run_date // ""' 2>/dev/null)"

    if [[ -n "$run_date" && -f "$metrics_file" ]]; then
        # Check composite key: both id AND run_date must match
        if grep -F "\"id\":\"${metric_id}\"" "$metrics_file" 2>/dev/null | grep -Fq "\"run_date\":\"${run_date}\"" 2>/dev/null; then
            return 0
        fi
    elif [[ -z "$run_date" && -f "$metrics_file" ]]; then
        # Fallback: if no run_date, dedup by id only
        if grep -Fq "\"id\":\"${metric_id}\"" "$metrics_file" 2>/dev/null; then
            return 0
        fi
    fi

    printf '%s\n' "$metric_json" >> "$metrics_file"
    return 0
}

# ---------------------------------------------------------------------------
# memory_append_source_credibility <evolve_root> <credibility_json>
# Appends to source-credibility.jsonl.
# ---------------------------------------------------------------------------
memory_append_source_credibility() {
    local evolve_root="$1"
    local credibility_json="$2"
    local cred_file="$evolve_root/memory/source-credibility.jsonl"

    mkdir -p "$evolve_root/memory"
    printf '%s\n' "$credibility_json" >> "$cred_file"
    return 0
}

# ---------------------------------------------------------------------------
# memory_get_source_credibility <evolve_root> <source_name> <days>
# Reads source-credibility.jsonl, filters by source_name and last N days,
# computes cumulative hit rate.
# Outputs JSON: {"source_name": "...", "hit_rate_30d": 0.XX, ...}
# ---------------------------------------------------------------------------
memory_get_source_credibility() {
    local evolve_root="$1"
    local source_name="$2"
    local days="$3"
    local cred_file="$evolve_root/memory/source-credibility.jsonl"

    if [[ ! -f "$cred_file" ]]; then
        jq -n --arg name "$source_name" \
            '{"source_name": $name, "hit_rate_30d": 0, "total_topics": 0, "total_passed": 0}'
        return 0
    fi

    local cutoff_date
    cutoff_date="$(date -u -d "-${days} days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)" || cutoff_date="1970-01-01T00:00:00Z"

    # Filter by source_name and date, compute stats
    jq -s -r --arg name "$source_name" --arg cutoff "$cutoff_date" '
        [.[] | select(.source_name == $name and (.date // "1970-01-01T00:00:00Z") >= $cutoff)] as $entries |
        ($entries | length) as $total |
        ([.[] | select(.source_name == $name and (.date // "1970-01-01T00:00:00Z") >= $cutoff and .passed == true)] | length) as $passed |
        {
            "source_name": $name,
            "hit_rate_30d": (if $total > 0 then ($passed / $total * 100 | . * 100 | round / 100) else 0 end),
            "total_topics": $total,
            "total_passed": $passed
        }
    ' "$cred_file"
}
