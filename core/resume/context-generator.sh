#!/usr/bin/env bash
# core/resume/context-generator.sh — generates resume-context files for human review

_CONTEXT_GEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_CONTEXT_GEN_DIR/../pool.sh"

# ---------------------------------------------------------------------------
# generate_resume_context <evolve_root> <workspace> <change_id> <decision_type>
#
# Generates a resume-context markdown file for a specific decision.
# decision_type: landed | reverted | killed | dropped
# Creates: $evolve_root/resume-context/$run_date/${change_id}-${decision_type}.md
# ---------------------------------------------------------------------------
generate_resume_context() {
    local evolve_root="$1"
    local workspace="$2"
    local change_id="$3"
    local decision_type="$4"

    local run_date
    run_date="$(basename "$workspace")"

    local pool_file="$workspace/pool.json"
    if [[ ! -f "$pool_file" ]]; then
        echo "generate_resume_context: pool.json not found at $pool_file" >&2
        return 1
    fi

    # Extract pool entry
    local entry
    entry="$(pool_get_entry "$pool_file" "$change_id")"
    if [[ -z "$entry" ]]; then
        echo "generate_resume_context: no pool entry found for id '$change_id'" >&2
        return 1
    fi

    # Extract title from entry (fall back to id if no title field)
    local title
    title="$(echo "$entry" | jq -r '.title // .description // .id')"

    # Extract decision summary from history (last event detail) or description
    local decision_summary
    decision_summary="$(echo "$entry" | jq -r '
        if .history and (.history | length) > 0 then
            .history[-1].detail
        elif .description then
            .description
        else
            "No decision summary available."
        end
    ')"

    # Format the full JSON nicely
    local entry_pretty
    entry_pretty="$(echo "$entry" | jq '.')"

    # List workspace artifacts related to this change
    local artifacts=""
    local artifact_patterns=("challenge.md" "validation-*.md" "decision-*.md" "implement-*.md" "${change_id}*.md" "${change_id}*.json")
    for pattern in "${artifact_patterns[@]}"; do
        local found
        found="$(find "$workspace" -maxdepth 2 -name "$pattern" 2>/dev/null || true)"
        if [[ -n "$found" ]]; then
            while IFS= read -r f; do
                artifacts="${artifacts}- $(basename "$f")"$'\n'
            done <<< "$found"
        fi
    done
    if [[ -z "$artifacts" ]]; then
        artifacts="- No workspace artifacts found for this change"$'\n'
    fi

    # Create output directory and file
    local context_dir="$evolve_root/resume-context/$run_date"
    mkdir -p "$context_dir"

    local context_file="$context_dir/${change_id}-${decision_type}.md"

    cat > "$context_file" <<CTXEOF
# Resume Context: ${change_id} — ${decision_type}

**Decision:** ${title} was ${decision_type}
**Date:** ${run_date}
**Context ID:** ${change_id}-${decision_type}

## Decision Summary
${decision_summary}

## Pool Entry Snapshot
\`\`\`json
${entry_pretty}
\`\`\`

## Artifacts
${artifacts}
## Available Actions
- **Override:** "implement this anyway, here's my reasoning..."
- **Redirect:** "this isn't about X, it's about..."
- **Expand:** "research this deeper, specifically..."
- **Modify:** "reduce scope to only affect..."
- **Directive:** Create a persistent rule for future runs
- **Nothing:** Review complete, no action needed
CTXEOF

    printf '%s' "$context_file"
}

# ---------------------------------------------------------------------------
# generate_all_resume_contexts <evolve_root> <workspace> <pool_file>
#
# Iterates all settled entries in pool.json and generates a context for each.
# Maps status to decision_type:
#   landed / landed-pending-kpi → "landed"
#   reverted → "reverted"
#   killed → "killed"
# ---------------------------------------------------------------------------
generate_all_resume_contexts() {
    local evolve_root="$1"
    local workspace="$2"
    local pool_file="$3"

    if [[ ! -f "$pool_file" ]]; then
        echo "generate_all_resume_contexts: pool.json not found at $pool_file" >&2
        return 1
    fi

    local count=0

    # Process landed entries
    local landed_ids
    landed_ids="$(pool_get_ids_by_status "$pool_file" "landed")"
    local landed_kpi_ids
    landed_kpi_ids="$(pool_get_ids_by_status "$pool_file" "landed-pending-kpi")"

    local id
    for id in $landed_ids $landed_kpi_ids; do
        [[ -z "$id" ]] && continue
        generate_resume_context "$evolve_root" "$workspace" "$id" "landed" >/dev/null
        (( count++ )) || true
    done

    # Process reverted entries
    local reverted_ids
    reverted_ids="$(pool_get_ids_by_status "$pool_file" "reverted")"
    for id in $reverted_ids; do
        [[ -z "$id" ]] && continue
        generate_resume_context "$evolve_root" "$workspace" "$id" "reverted" >/dev/null
        (( count++ )) || true
    done

    # Process killed entries
    local killed_ids
    killed_ids="$(pool_get_ids_by_status "$pool_file" "killed")"
    for id in $killed_ids; do
        [[ -z "$id" ]] && continue
        generate_resume_context "$evolve_root" "$workspace" "$id" "killed" >/dev/null
        (( count++ )) || true
    done

    echo "$count"
}

# ---------------------------------------------------------------------------
# generate_circuit_breaker_context <evolve_root> <workspace>
#
# Special context file for circuit breaker trips.
# Includes last 7 days of negative impacts, diagnostic report.
# ---------------------------------------------------------------------------
generate_circuit_breaker_context() {
    local evolve_root="$1"
    local workspace="$2"

    local run_date
    run_date="$(basename "$workspace")"

    local context_dir="$evolve_root/resume-context/$run_date"
    mkdir -p "$context_dir"
    local context_file="$context_dir/circuit-breaker.md"

    # Collect negative impacts from recent workspaces (last 7 days)
    local negative_report=""
    local workspace_base="$evolve_root/workspace"
    if [[ -d "$workspace_base" ]]; then
        local cutoff_date
        cutoff_date="$(date -d '7 days ago' +%Y-%m-%d 2>/dev/null || date -v-7d +%Y-%m-%d 2>/dev/null || echo "0000-00-00")"

        local ws_dir
        for ws_dir in "$workspace_base"/*/; do
            [[ ! -d "$ws_dir" ]] && continue
            local ws_date
            ws_date="$(basename "$ws_dir")"
            # Only include recent workspaces (basic string comparison works for YYYY-MM-DD)
            if [[ "$ws_date" > "$cutoff_date" || "$ws_date" == "$cutoff_date" ]]; then
                local pf="$ws_dir/pool.json"
                if [[ -f "$pf" ]]; then
                    # Find reverted and killed entries
                    local neg_entries
                    neg_entries="$(jq -r '.[] | select(.status == "reverted" or .status == "killed") | "- [\(.id)] \(.title // .description // "untitled") — \(.status)"' "$pf" 2>/dev/null || true)"
                    if [[ -n "$neg_entries" ]]; then
                        negative_report="${negative_report}### ${ws_date}
${neg_entries}

"
                    fi
                fi
            fi
        done
    fi

    if [[ -z "$negative_report" ]]; then
        negative_report="No negative impact entries found in the last 7 days."
    fi

    # Check for circuit breaker trip marker
    local trip_marker="$evolve_root/circuit-breaker.trip"
    local trip_info="No trip marker found."
    if [[ -f "$trip_marker" ]]; then
        trip_info="$(cat "$trip_marker")"
    fi

    cat > "$context_file" <<CBEOF
# Resume Context: Circuit Breaker Trip

**Date:** ${run_date}
**Context ID:** circuit-breaker

## Trip Information
${trip_info}

## Negative Impacts (Last 7 Days)
${negative_report}
## Diagnostic Report
Review the negative-impact changes above to identify patterns.
Consider whether the pipeline's scoring or challenge phases need adjustment.

## Available Actions
- **Reset:** Clear the circuit breaker and allow the pipeline to resume
- **Directive:** Create constraints to prevent recurrence
- **Review:** Examine each negative-impact change individually
- **Nothing:** Keep the circuit breaker tripped
CBEOF

    printf '%s' "$context_file"
}
