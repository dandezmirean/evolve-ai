#!/usr/bin/env bash
# core/scoring/metrics.sh — Metrics recording and aggregation for evolve-ai
set -euo pipefail

_METRICS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_METRICS_CORE_DIR="$(cd "$_METRICS_DIR/.." && pwd)"

# Source dependencies if not already loaded
if ! declare -f memory_append_metric >/dev/null 2>&1; then
    source "$_METRICS_CORE_DIR/memory/manager.sh"
fi
if ! declare -f pool_get_entry >/dev/null 2>&1; then
    source "$_METRICS_CORE_DIR/pool.sh"
fi

# ---------------------------------------------------------------------------
# metrics_record <pool_file> <evolve_root>
# Reads all settled entries from pool.json and records them to metrics.jsonl.
# Each record has 17 fields.
# ---------------------------------------------------------------------------
metrics_record() {
    local pool_file="$1"
    local evolve_root="$2"

    if [[ ! -f "$pool_file" ]]; then
        echo "metrics_record: pool file not found: $pool_file" >&2
        return 1
    fi

    # Get all settled entries (terminal states)
    local entries
    entries="$(jq -c '.[] | select(
        .status == "landed" or
        .status == "landed-pending-kpi" or
        .status == "reverted" or
        .status == "killed"
    )' "$pool_file")" || return 0

    if [[ -z "$entries" ]]; then
        return 0
    fi

    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue

        local metric
        metric="$(printf '%s' "$entry" | jq -c \
            --arg date "$ts" \
            '{
                date: $date,
                id: (.id // "unknown"),
                title: (.title // .description // "untitled"),
                source: (.source // "unknown"),
                track: (.track // "standard"),
                ambition_claimed: (.ambition_claimed // 0),
                ambition_actual: (.ambition_actual // 0),
                quality_score: (.quality_score // 0),
                resilience_score: (.resilience_score // 0),
                category: (.category // "uncategorized"),
                status: .status,
                iterations: (.iterations // 0),
                challenge_verdict: (.challenge_verdict // "none"),
                guard_result: (.guard_result // "none"),
                impact_signal: (.impact_signal // "unmeasured"),
                fix_cycles: (.fix_cycles // 0),
                failure_reason: (.failure_reason // "none")
            }')"

        memory_append_metric "$evolve_root" "$metric"
    done <<< "$entries"

    return 0
}

# ---------------------------------------------------------------------------
# metrics_record_source_credibility <evolve_root> <workspace>
# Reads digest-summary.md (if present) and records source credibility data.
# ---------------------------------------------------------------------------
metrics_record_source_credibility() {
    local evolve_root="$1"
    local workspace="$2"
    local digest_summary="$workspace/digest-summary.md"

    if [[ ! -f "$digest_summary" ]]; then
        return 0
    fi

    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    # Parse source names and their topic counts from the digest summary
    # Expected format: lines with "Source: <name>" and "Topics: N" or similar
    # This is best-effort parsing
    local source_name=""
    while IFS= read -r line; do
        # Look for source entries — format: "- **source_name**: N topics, M passed"
        if printf '%s' "$line" | grep -qiE '^\s*-\s+\*?\*?([^*:]+)\*?\*?\s*:\s*[0-9]+\s+topics?'; then
            source_name="$(printf '%s' "$line" | sed -E 's/^\s*-\s+\*?\*?([^*:]+)\*?\*?\s*:.*/\1/' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            local topics passed
            topics="$(printf '%s' "$line" | grep -oP '[0-9]+(?=\s+topics?)' | head -1)" || topics="0"
            passed="$(printf '%s' "$line" | grep -oP '[0-9]+(?=\s+passed)' | head -1)" || passed="0"

            if [[ -n "$source_name" && "$topics" -gt 0 ]]; then
                local cred_json
                cred_json="$(jq -n \
                    --arg date "$ts" \
                    --arg source_name "$source_name" \
                    --argjson total_topics "$topics" \
                    --argjson passed "$passed" \
                    --argjson is_passed "$([ "$passed" -gt 0 ] && echo "true" || echo "false")" \
                    '{
                        date: $date,
                        source_name: $source_name,
                        total_topics: $total_topics,
                        passed: $is_passed
                    }')"
                memory_append_source_credibility "$evolve_root" "$cred_json"
            fi
        fi
    done < "$digest_summary"

    return 0
}

# ---------------------------------------------------------------------------
# metrics_record_session_marker <evolve_root>
# Writes a session marker for nothing-today sessions.
# ---------------------------------------------------------------------------
metrics_record_session_marker() {
    local evolve_root="$1"
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    local marker
    marker="$(jq -n --arg date "$ts" '{
        date: $date,
        id: "SESSION",
        title: "No proposals",
        source: "system",
        track: "none",
        ambition_claimed: 0,
        ambition_actual: 0,
        quality_score: 0,
        resilience_score: 0,
        category: "session",
        status: "empty",
        iterations: 0,
        challenge_verdict: "none",
        guard_result: "none",
        impact_signal: "unmeasured",
        fix_cycles: 0,
        failure_reason: "none"
    }')"

    # Session markers use date as uniqueness — append without dedup
    local metrics_file="$evolve_root/memory/metrics.jsonl"
    mkdir -p "$evolve_root/memory"
    printf '%s\n' "$marker" >> "$metrics_file"

    return 0
}

# ---------------------------------------------------------------------------
# metrics_weekly_digest <evolve_root>
# Generates 7-day aggregate report. Outputs report as string.
# ---------------------------------------------------------------------------
metrics_weekly_digest() {
    local evolve_root="$1"
    local metrics_file="$evolve_root/memory/metrics.jsonl"

    if [[ ! -f "$metrics_file" ]]; then
        echo "No metrics data available."
        return 0
    fi

    local cutoff_date
    cutoff_date="$(date -u -d "-7 days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)" || cutoff_date="1970-01-01T00:00:00Z"

    local prev_cutoff_date
    prev_cutoff_date="$(date -u -d "-14 days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)" || prev_cutoff_date="1970-01-01T00:00:00Z"

    # Generate the digest using jq
    jq -s -r --arg cutoff "$cutoff_date" --arg prev_cutoff "$prev_cutoff_date" '
        # Current week entries (excluding session markers)
        [.[] | select(.date >= $cutoff and .id != "SESSION")] as $current |
        # Previous week entries
        [.[] | select(.date >= $prev_cutoff and .date < $cutoff and .id != "SESSION")] as $previous |

        # Throughput
        ($current | length) as $total |
        ([.[] | select(.date >= $cutoff and .status == "landed")] | length) as $landed |
        ([.[] | select(.date >= $cutoff and .status == "reverted")] | length) as $reverted |
        ([.[] | select(.date >= $cutoff and .status == "killed")] | length) as $killed |

        # Previous week throughput
        ($previous | length) as $prev_total |

        # Category stats
        ($current | group_by(.category) | map({
            category: .[0].category,
            total: length,
            landed: [.[] | select(.status == "landed")] | length
        })) as $categories |

        # Ambition
        ($current | if length > 0 then
            (map(.ambition_claimed // 0) | add / length) as $avg_claimed |
            (map(.ambition_actual // 0) | add / length) as $avg_actual |
            {"avg_claimed": ($avg_claimed * 100 | round / 100), "avg_actual": ($avg_actual * 100 | round / 100), "inflation": (($avg_claimed - $avg_actual) * 100 | round / 100)}
        else
            {"avg_claimed": 0, "avg_actual": 0, "inflation": 0}
        end) as $ambition |

        # Big bets (ambition_claimed >= 3)
        ([.[] | select(.date >= $cutoff and (.ambition_claimed // 0) >= 3)] | {
            count: length,
            landed: [.[] | select(.status == "landed")] | length
        }) as $big_bets |

        # Impact signals
        ([.[] | select(.date >= $cutoff and .impact_signal == "positive")] | length) as $positive |
        ([.[] | select(.date >= $cutoff and .impact_signal == "negative")] | length) as $negative |
        ([.[] | select(.date >= $cutoff and .impact_signal == "neutral")] | length) as $neutral |

        # Trend
        (if $prev_total > 0 then
            (($total - $prev_total) / $prev_total * 100 | . * 10 | round / 10)
        else 0 end) as $throughput_trend |

        "# Weekly Digest\n\n" +
        "## Throughput\n" +
        "- Total: \($total) | Landed: \($landed) | Reverted: \($reverted) | Killed: \($killed)\n" +
        "- Land rate: \(if $total > 0 then ($landed / $total * 100 | . * 10 | round / 10) else 0 end)%\n" +
        "- Trend vs previous week: \($throughput_trend)%\n\n" +
        "## Impact Signals\n" +
        "- Positive: \($positive) | Negative: \($negative) | Neutral: \($neutral)\n\n" +
        "## Ambition\n" +
        "- Avg claimed: \($ambition.avg_claimed) | Avg actual: \($ambition.avg_actual)\n" +
        "- Inflation: \($ambition.inflation)\n\n" +
        "## Big Bets\n" +
        "- Count: \($big_bets.count) | Landed: \($big_bets.landed)\n\n" +
        "## By Category\n" +
        ($categories | map("- \(.category): \(.total) total, \(.landed) landed (\(if .total > 0 then (.landed / .total * 100 | . * 10 | round / 10) else 0 end)%)") | join("\n")) +
        "\n"
    ' "$metrics_file"
}

# ---------------------------------------------------------------------------
# metrics_compute_category_stats <evolve_root> <category> <days>
# Computes: land_rate, avg_fix_cycles, total_count for category in last N days.
# Outputs JSON.
# ---------------------------------------------------------------------------
metrics_compute_category_stats() {
    local evolve_root="$1"
    local category="$2"
    local days="$3"
    local metrics_file="$evolve_root/memory/metrics.jsonl"

    if [[ ! -f "$metrics_file" ]]; then
        jq -n --arg cat "$category" \
            '{"category": $cat, "land_rate": 0, "avg_fix_cycles": 0, "total_count": 0}'
        return 0
    fi

    local cutoff_date
    cutoff_date="$(date -u -d "-${days} days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)" || cutoff_date="1970-01-01T00:00:00Z"

    jq -s -r --arg cat "$category" --arg cutoff "$cutoff_date" '
        [.[] | select(.category == $cat and .date >= $cutoff and .id != "SESSION")] as $entries |
        ($entries | length) as $total |
        ([.[] | select(.category == $cat and .date >= $cutoff and .status == "landed")] | length) as $landed |
        ($entries | if length > 0 then (map(.fix_cycles // 0) | add / length * 100 | round / 100) else 0 end) as $avg_fix |
        {
            "category": $cat,
            "land_rate": (if $total > 0 then ($landed / $total * 100 | . * 100 | round / 100) else 0 end),
            "avg_fix_cycles": $avg_fix,
            "total_count": $total
        }
    ' "$metrics_file"
}

# ---------------------------------------------------------------------------
# metrics_compute_ambition_accuracy <evolve_root> <days>
# Computes avg(ambition_claimed - ambition_actual) over last N days.
# Outputs JSON.
# ---------------------------------------------------------------------------
metrics_compute_ambition_accuracy() {
    local evolve_root="$1"
    local days="$2"
    local metrics_file="$evolve_root/memory/metrics.jsonl"

    if [[ ! -f "$metrics_file" ]]; then
        jq -n '{"avg_inflation": 0, "total_entries": 0}'
        return 0
    fi

    local cutoff_date
    cutoff_date="$(date -u -d "-${days} days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)" || cutoff_date="1970-01-01T00:00:00Z"

    jq -s -r --arg cutoff "$cutoff_date" '
        [.[] | select(.date >= $cutoff and .id != "SESSION")] as $entries |
        ($entries | length) as $total |
        ($entries | if length > 0 then
            (map((.ambition_claimed // 0) - (.ambition_actual // 0)) | add / length * 100 | round / 100)
        else 0 end) as $avg_inflation |
        {
            "avg_inflation": $avg_inflation,
            "total_entries": $total
        }
    ' "$metrics_file"
}
