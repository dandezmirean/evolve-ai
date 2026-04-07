#!/usr/bin/env bash
# core/meta/meta-agent.sh — Meta-agent evaluator for evolve-ai
# Outer loop that evaluates and tunes the pipeline itself.
# Runs weekly/monthly, completely separate from the daily pipeline.
set -euo pipefail

_META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_META_CORE_DIR="$(cd "$_META_DIR/.." && pwd)"

# Source dependencies if not already loaded
if ! declare -f load_config >/dev/null 2>&1; then
    source "$_META_CORE_DIR/config.sh"
fi
if ! declare -f acquire_lock >/dev/null 2>&1; then
    source "$_META_CORE_DIR/lock.sh"
fi

EVOLVE_META_LOCK="${EVOLVE_ROOT:-.}/.evolve-meta-lock"

# ---------------------------------------------------------------------------
# meta_run <evolve_root>
# Main entry point for the meta-agent. Flow:
#   1. Check meta_agent.enabled in config
#   2. Acquire meta lock
#   3. Load all data sources
#   4. Run all 4 evaluation dimensions
#   5. Compile findings into proposals
#   6. Generate "state of the system" report
#   7. Send notification
#   8. Release lock
# ---------------------------------------------------------------------------
meta_run() {
    local evolve_root="$1"

    # 1. Load config and check enabled
    local config_file="$evolve_root/config/evolve.yaml"
    if [[ -f "$config_file" ]]; then
        load_config "$config_file"
    fi

    local enabled
    enabled="$(config_get_default "meta_agent.enabled" "false")"
    if [[ "$enabled" != "true" ]]; then
        echo "[meta-agent] Meta-agent is disabled in config. Set meta_agent.enabled: true to enable."
        return 0
    fi

    # 2. Acquire lock
    if ! acquire_lock "$EVOLVE_META_LOCK"; then
        echo "[meta-agent] Another meta evaluation is running (lock held). Exiting." >&2
        return 1
    fi

    # Ensure lock is released on exit
    trap 'release_lock "$EVOLVE_META_LOCK"' EXIT

    echo "[meta-agent] Starting meta evaluation..."

    # 3. Ensure data directories exist
    mkdir -p "$evolve_root/meta/proposals"

    # 4. Run all 4 evaluation dimensions
    local pipeline_health scoring_calibration source_effectiveness strategic_drift

    pipeline_health="$(meta_evaluate_pipeline_health "$evolve_root")"
    echo "[meta-agent] Pipeline health evaluation complete."

    scoring_calibration="$(meta_evaluate_scoring_calibration "$evolve_root")"
    echo "[meta-agent] Scoring calibration evaluation complete."

    source_effectiveness="$(meta_evaluate_source_effectiveness "$evolve_root")"
    echo "[meta-agent] Source effectiveness evaluation complete."

    strategic_drift="$(meta_evaluate_strategic_drift "$evolve_root")"
    echo "[meta-agent] Strategic drift evaluation complete."

    # 5. Compile findings into proposals
    local evaluations
    evaluations="$(jq -n \
        --argjson pipeline_health "$pipeline_health" \
        --argjson scoring_calibration "$scoring_calibration" \
        --argjson source_effectiveness "$source_effectiveness" \
        --argjson strategic_drift "$strategic_drift" \
        '{
            pipeline_health: $pipeline_health,
            scoring_calibration: $scoring_calibration,
            source_effectiveness: $source_effectiveness,
            strategic_drift: $strategic_drift
        }')"

    local proposals
    proposals="$(meta_generate_proposals "$evolve_root" "$evaluations")"
    echo "[meta-agent] Proposals generated."

    # 6. Generate report
    local report
    report="$(meta_generate_report "$evolve_root" "$evaluations" "$proposals")"

    # Save report
    printf '%s\n' "$report" > "$evolve_root/meta/last-report.md"
    echo "[meta-agent] Report saved to meta/last-report.md"

    # 7. Send notification (if notification engine is available)
    if declare -f notify >/dev/null 2>&1; then
        local summary
        summary="$(printf '%s' "$pipeline_health" | jq -r '"Meta-Agent: trend=\(.trend), kill_rate=\(.kill_rate), land_rate=\(.land_rate)"')"
        notify "[evolve-ai] Meta Evaluation Complete: $summary"
    else
        echo "[meta-agent] $report"
    fi

    # 8. Release lock (handled by trap)
    echo "[meta-agent] Meta evaluation complete."
    return 0
}

# ---------------------------------------------------------------------------
# meta_evaluate_pipeline_health <evolve_root>
# Evaluates pipeline efficiency:
#   - Challenge kill rate vs land rate of survivors
#   - Validation guard fail rate
#   - Fix cycle trends
#   - Phase turn spending (from usage.log)
# Outputs JSON to stdout.
# ---------------------------------------------------------------------------
meta_evaluate_pipeline_health() {
    local evolve_root="$1"
    local metrics_file="$evolve_root/memory/metrics.jsonl"

    if [[ ! -f "$metrics_file" ]] || [[ ! -s "$metrics_file" ]]; then
        jq -n '{
            "kill_rate": 0,
            "land_rate": 0,
            "guard_fail_rate": 0,
            "avg_fix_cycles": 0,
            "trend": "stable"
        }'
        return 0
    fi

    # Compute pipeline health metrics from metrics.jsonl
    jq -s '
        # Filter out session markers
        [.[] | select(.id != "SESSION")] as $entries |

        # Total settled entries
        ($entries | length) as $total |

        # Kill rate: killed / total
        ([.[] | select(.id != "SESSION" and .status == "killed")] | length) as $killed |
        (if $total > 0 then ($killed / $total * 100 | round / 100) else 0 end) as $kill_rate |

        # Land rate: landed / total
        ([.[] | select(.id != "SESSION" and (.status == "landed" or .status == "landed-pending-kpi"))] | length) as $landed |
        (if $total > 0 then ($landed / $total * 100 | round / 100) else 0 end) as $land_rate |

        # Guard fail rate: guard_result != "none" and guard_result != "pass" / total
        ([.[] | select(.id != "SESSION" and .guard_result != "none" and .guard_result != "pass")] | length) as $guard_fails |
        (if $total > 0 then ($guard_fails / $total * 100 | round / 100) else 0 end) as $guard_fail_rate |

        # Average fix cycles
        ($entries | if length > 0 then
            (map(.fix_cycles // 0) | add / length * 100 | round / 100)
        else 0 end) as $avg_fix_cycles |

        # Trend: compare first half vs second half fix cycles
        (($entries | length / 2 | floor) as $mid |
         if $mid > 0 then
            ([$entries[:$mid][]] | map(.fix_cycles // 0) | if length > 0 then add / length else 0 end) as $first_half |
            ([$entries[$mid:][]] | map(.fix_cycles // 0) | if length > 0 then add / length else 0 end) as $second_half |
            if ($second_half - $first_half) > 0.5 then "degrading"
            elif ($first_half - $second_half) > 0.5 then "improving"
            else "stable"
            end
         else "stable"
         end
        ) as $trend |

        {
            "kill_rate": $kill_rate,
            "land_rate": $land_rate,
            "guard_fail_rate": $guard_fail_rate,
            "avg_fix_cycles": $avg_fix_cycles,
            "trend": $trend
        }
    ' "$metrics_file"
}

# ---------------------------------------------------------------------------
# meta_evaluate_scoring_calibration <evolve_root>
# Evaluates scoring accuracy:
#   - Do high-quality-scored changes actually land?
#   - Does impact_signal match quality expectations?
#   - Ambition inflation trends
# Outputs JSON to stdout.
# ---------------------------------------------------------------------------
meta_evaluate_scoring_calibration() {
    local evolve_root="$1"
    local metrics_file="$evolve_root/memory/metrics.jsonl"

    if [[ ! -f "$metrics_file" ]] || [[ ! -s "$metrics_file" ]]; then
        jq -n '{
            "quality_land_correlation": 0,
            "ambition_inflation": 0,
            "scoring_aligned": true
        }'
        return 0
    fi

    jq -s '
        # Filter out session markers
        [.[] | select(.id != "SESSION")] as $entries |

        # Quality-land correlation:
        # Of entries with quality_score >= 7, what fraction landed?
        ([.[] | select(.id != "SESSION" and (.quality_score // 0) >= 7)] | length) as $high_quality_total |
        ([.[] | select(.id != "SESSION" and (.quality_score // 0) >= 7 and (.status == "landed" or .status == "landed-pending-kpi"))] | length) as $high_quality_landed |
        (if $high_quality_total > 0 then
            ($high_quality_landed / $high_quality_total * 100 | round / 100)
        else 0 end) as $quality_land_correlation |

        # Ambition inflation: avg(claimed - actual)
        ($entries | if length > 0 then
            (map((.ambition_claimed // 0) - (.ambition_actual // 0)) | add / length * 100 | round / 100)
        else 0 end) as $ambition_inflation |

        # Scoring aligned: true if quality_land_correlation >= 0.5 and ambition_inflation < 1.5
        (if $quality_land_correlation >= 0.5 or $high_quality_total == 0 then
            (if $ambition_inflation < 1.5 then true else false end)
        else false end) as $scoring_aligned |

        {
            "quality_land_correlation": $quality_land_correlation,
            "ambition_inflation": $ambition_inflation,
            "scoring_aligned": $scoring_aligned
        }
    ' "$metrics_file"
}

# ---------------------------------------------------------------------------
# meta_evaluate_source_effectiveness <evolve_root>
# Evaluates source credibility trends:
#   - Which sources have high/low hit rates
#   - Recommendations: keep/reduce/remove
# Outputs JSON to stdout.
# ---------------------------------------------------------------------------
meta_evaluate_source_effectiveness() {
    local evolve_root="$1"
    local cred_file="$evolve_root/memory/source-credibility.jsonl"

    if [[ ! -f "$cred_file" ]] || [[ ! -s "$cred_file" ]]; then
        jq -n '{"sources": []}'
        return 0
    fi

    jq -s '
        # Group by source_name
        group_by(.source_name) |
        map(
            (.[0].source_name) as $name |
            (length) as $total |
            ([.[] | select(.passed == true)] | length) as $passed |
            (if $total > 0 then ($passed / $total * 100 | round / 100) else 0 end) as $hit_rate |
            # Recommendation logic
            (if $hit_rate >= 0.5 then "keep"
             elif $hit_rate >= 0.2 then "reduce"
             else "remove"
             end) as $recommendation |
            {
                "name": $name,
                "hit_rate": $hit_rate,
                "total_topics": $total,
                "passed": $passed,
                "recommendation": $recommendation
            }
        ) |
        {"sources": .}
    ' "$cred_file"
}

# ---------------------------------------------------------------------------
# meta_evaluate_strategic_drift <evolve_root>
# Evaluates strategic focus:
#   - Category distribution (is the system stuck in one domain?)
#   - Big bet frequency and ambition trends
#   - Are we avoiding hard problems?
# Outputs JSON to stdout.
# ---------------------------------------------------------------------------
meta_evaluate_strategic_drift() {
    local evolve_root="$1"
    local metrics_file="$evolve_root/memory/metrics.jsonl"

    if [[ ! -f "$metrics_file" ]] || [[ ! -s "$metrics_file" ]]; then
        jq -n '{
            "category_distribution": {},
            "ambition_trend": "stable",
            "risk_aversion": false
        }'
        return 0
    fi

    jq -s '
        # Filter out session markers
        [.[] | select(.id != "SESSION")] as $entries |

        # Category distribution
        ($entries | group_by(.category // "uncategorized") |
         map({
            key: (.[0].category // "uncategorized"),
            value: length
         }) | from_entries
        ) as $category_distribution |

        # Check for category imbalance: if any category has > 60% of entries
        ($entries | length) as $total |
        ($category_distribution | to_entries |
         if length > 0 then
            (map(select(.value > ($total * 0.6))) | length > 0)
         else false end
        ) as $category_imbalanced |

        # Ambition trend: compare first half vs second half avg ambition_claimed
        (($entries | length / 2 | floor) as $mid |
         if $mid > 0 then
            ([$entries[:$mid][]] | map(.ambition_claimed // 0) | if length > 0 then add / length else 0 end) as $first_half |
            ([$entries[$mid:][]] | map(.ambition_claimed // 0) | if length > 0 then add / length else 0 end) as $second_half |
            if ($second_half - $first_half) > 0.3 then "increasing"
            elif ($first_half - $second_half) > 0.3 then "declining"
            else "stable"
            end
         else "stable"
         end
        ) as $ambition_trend |

        # Risk aversion: true if ambition is declining AND no big bets (ambition >= 3)
        ([.[] | select(.id != "SESSION" and (.ambition_claimed // 0) >= 3)] | length) as $big_bets |
        (if $ambition_trend == "declining" and $big_bets == 0 then true
         else false end) as $risk_aversion |

        {
            "category_distribution": $category_distribution,
            "ambition_trend": $ambition_trend,
            "risk_aversion": $risk_aversion
        }
    ' "$metrics_file"
}

# ---------------------------------------------------------------------------
# meta_generate_proposals <evolve_root> <evaluations_json>
# Based on evaluation findings, generates concrete proposals.
#
# The meta-agent CAN change:
#   - Phase turn budgets (in evolve.yaml)
#   - Scoring weights (in genome config)
#   - Source schedules and priorities
#   - Challenge approval floor percentage
#   - Validation tier thresholds
#   - Proposal quality thresholds
#
# The meta-agent CANNOT change:
#   - Safety rules
#   - Genome identity (scan commands, gap framework)
#   - Circuit breaker configuration
#   - Its own evaluation prompt
#
# Proposals are written to $evolve_root/meta/proposals/
# Outputs JSON array of proposals to stdout.
# ---------------------------------------------------------------------------
meta_generate_proposals() {
    local evolve_root="$1"
    local evaluations="$2"

    local proposals_dir="$evolve_root/meta/proposals"
    mkdir -p "$proposals_dir"

    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    local proposals="[]"

    # Extract evaluation results
    local trend kill_rate land_rate guard_fail_rate avg_fix_cycles
    trend="$(printf '%s' "$evaluations" | jq -r '.pipeline_health.trend')"
    kill_rate="$(printf '%s' "$evaluations" | jq -r '.pipeline_health.kill_rate')"
    land_rate="$(printf '%s' "$evaluations" | jq -r '.pipeline_health.land_rate')"
    guard_fail_rate="$(printf '%s' "$evaluations" | jq -r '.pipeline_health.guard_fail_rate')"
    avg_fix_cycles="$(printf '%s' "$evaluations" | jq -r '.pipeline_health.avg_fix_cycles')"

    local scoring_aligned ambition_inflation
    scoring_aligned="$(printf '%s' "$evaluations" | jq -r '.scoring_calibration.scoring_aligned')"
    ambition_inflation="$(printf '%s' "$evaluations" | jq -r '.scoring_calibration.ambition_inflation')"

    local ambition_trend risk_aversion
    ambition_trend="$(printf '%s' "$evaluations" | jq -r '.strategic_drift.ambition_trend')"
    risk_aversion="$(printf '%s' "$evaluations" | jq -r '.strategic_drift.risk_aversion')"

    # Generate proposals based on findings

    # 1. If pipeline is degrading, propose reducing turn budgets
    if [[ "$trend" == "degrading" ]]; then
        local proposal
        proposal="$(jq -n \
            --arg ts "$ts" \
            '{
                "id": "reduce-turn-budget",
                "timestamp": $ts,
                "type": "config_change",
                "target": "pipeline.max_turns",
                "reason": "Pipeline trend is degrading — fix cycles increasing. Reducing turn budget to force simpler changes.",
                "action": "Reduce pipeline.max_turns by 10%",
                "category": "pipeline_tuning"
            }')"
        proposals="$(printf '%s' "$proposals" | jq --argjson p "$proposal" '. + [$p]')"
        printf '%s\n' "$proposal" > "$proposals_dir/reduce-turn-budget-${ts}.json"
    fi

    # 2. If kill rate is very high (> 0.7), challenge may be too strict
    local kill_high
    kill_high="$(awk -v k="$kill_rate" 'BEGIN { print (k > 0.7) ? "yes" : "no" }')"
    if [[ "$kill_high" == "yes" ]]; then
        local proposal
        proposal="$(jq -n \
            --arg ts "$ts" \
            --arg kill_rate "$kill_rate" \
            '{
                "id": "lower-challenge-floor",
                "timestamp": $ts,
                "type": "config_change",
                "target": "challenge.approval_floor_pct",
                "reason": ("Kill rate is \($kill_rate) — challenge phase may be too strict. Lowering approval floor."),
                "action": "Reduce challenge.approval_floor_pct by 10",
                "category": "challenge_tuning"
            }')"
        proposals="$(printf '%s' "$proposals" | jq --argjson p "$proposal" '. + [$p]')"
        printf '%s\n' "$proposal" > "$proposals_dir/lower-challenge-floor-${ts}.json"
    fi

    # 3. If guard fail rate is high (> 0.5), validation may need adjustment
    local guard_high
    guard_high="$(awk -v g="$guard_fail_rate" 'BEGIN { print (g > 0.5) ? "yes" : "no" }')"
    if [[ "$guard_high" == "yes" ]]; then
        local proposal
        proposal="$(jq -n \
            --arg ts "$ts" \
            --arg guard_fail_rate "$guard_fail_rate" \
            '{
                "id": "adjust-validation-thresholds",
                "timestamp": $ts,
                "type": "config_change",
                "target": "validation.tier3_min_free_ram_mb",
                "reason": ("Guard fail rate is \($guard_fail_rate) — validation guards may be too strict."),
                "action": "Review and potentially lower validation tier thresholds",
                "category": "validation_tuning"
            }')"
        proposals="$(printf '%s' "$proposals" | jq --argjson p "$proposal" '. + [$p]')"
        printf '%s\n' "$proposal" > "$proposals_dir/adjust-validation-${ts}.json"
    fi

    # 4. If scoring is not aligned, propose weight adjustment
    if [[ "$scoring_aligned" == "false" ]]; then
        local proposal
        proposal="$(jq -n \
            --arg ts "$ts" \
            --arg ambition_inflation "$ambition_inflation" \
            '{
                "id": "recalibrate-scoring",
                "timestamp": $ts,
                "type": "config_change",
                "target": "scoring_weights",
                "reason": ("Scoring misaligned — ambition inflation is \($ambition_inflation). Quality scores not predicting landing."),
                "action": "Adjust scoring weights to better reflect actual outcomes",
                "category": "scoring_tuning"
            }')"
        proposals="$(printf '%s' "$proposals" | jq --argjson p "$proposal" '. + [$p]')"
        printf '%s\n' "$proposal" > "$proposals_dir/recalibrate-scoring-${ts}.json"
    fi

    # 5. If risk aversion detected, propose encouraging bigger bets
    if [[ "$risk_aversion" == "true" ]]; then
        local proposal
        proposal="$(jq -n \
            --arg ts "$ts" \
            '{
                "id": "encourage-ambition",
                "timestamp": $ts,
                "type": "config_change",
                "target": "source_schedules",
                "reason": "Risk aversion detected — ambition declining with no big bets. System may be stuck in safe territory.",
                "action": "Increase priority of sources that produce ambitious proposals",
                "category": "strategic_tuning"
            }')"
        proposals="$(printf '%s' "$proposals" | jq --argjson p "$proposal" '. + [$p]')"
        printf '%s\n' "$proposal" > "$proposals_dir/encourage-ambition-${ts}.json"
    fi

    # 6. Source-specific proposals
    local low_sources
    low_sources="$(printf '%s' "$evaluations" | jq -r '.source_effectiveness.sources[] | select(.recommendation == "remove") | .name' 2>/dev/null)" || true
    if [[ -n "$low_sources" ]]; then
        while IFS= read -r source_name; do
            [[ -z "$source_name" ]] && continue
            local proposal
            proposal="$(jq -n \
                --arg ts "$ts" \
                --arg source "$source_name" \
                '{
                    "id": ("remove-source-" + $source),
                    "timestamp": $ts,
                    "type": "config_change",
                    "target": "source_schedules",
                    "reason": ("Source \($source) has very low hit rate — recommend removal."),
                    "action": ("Remove or deprioritize source: " + $source),
                    "category": "source_tuning"
                }')"
            proposals="$(printf '%s' "$proposals" | jq --argjson p "$proposal" '. + [$p]')"
            printf '%s\n' "$proposal" > "$proposals_dir/remove-source-${source_name}-${ts}.json"
        done <<< "$low_sources"
    fi

    printf '%s\n' "$proposals"
}

# ---------------------------------------------------------------------------
# meta_generate_report <evolve_root> <evaluations_json> <proposals_json>
# Generates the "state of the system" report as markdown.
# Includes all evaluation results, proposals, and recommendations.
# ---------------------------------------------------------------------------
meta_generate_report() {
    local evolve_root="$1"
    local evaluations="$2"
    local proposals="$3"

    local report_date
    report_date="$(date -u +"%Y-%m-%d %H:%M UTC")"

    local report=""
    report+="# Meta-Agent Evaluation Report"$'\n'
    report+="Generated: ${report_date}"$'\n'
    report+=""$'\n'

    # Pipeline Health
    local trend kill_rate land_rate guard_fail_rate avg_fix_cycles
    trend="$(printf '%s' "$evaluations" | jq -r '.pipeline_health.trend')"
    kill_rate="$(printf '%s' "$evaluations" | jq -r '.pipeline_health.kill_rate')"
    land_rate="$(printf '%s' "$evaluations" | jq -r '.pipeline_health.land_rate')"
    guard_fail_rate="$(printf '%s' "$evaluations" | jq -r '.pipeline_health.guard_fail_rate')"
    avg_fix_cycles="$(printf '%s' "$evaluations" | jq -r '.pipeline_health.avg_fix_cycles')"

    report+="## Pipeline Health"$'\n'
    report+="- Trend: **${trend}**"$'\n'
    report+="- Kill rate: ${kill_rate}"$'\n'
    report+="- Land rate: ${land_rate}"$'\n'
    report+="- Guard fail rate: ${guard_fail_rate}"$'\n'
    report+="- Avg fix cycles: ${avg_fix_cycles}"$'\n'
    report+=""$'\n'

    # Scoring Calibration
    local quality_land_corr ambition_inflation scoring_aligned
    quality_land_corr="$(printf '%s' "$evaluations" | jq -r '.scoring_calibration.quality_land_correlation')"
    ambition_inflation="$(printf '%s' "$evaluations" | jq -r '.scoring_calibration.ambition_inflation')"
    scoring_aligned="$(printf '%s' "$evaluations" | jq -r '.scoring_calibration.scoring_aligned')"

    report+="## Scoring Calibration"$'\n'
    report+="- Quality-land correlation: ${quality_land_corr}"$'\n'
    report+="- Ambition inflation: ${ambition_inflation}"$'\n'
    report+="- Scoring aligned: **${scoring_aligned}**"$'\n'
    report+=""$'\n'

    # Source Effectiveness
    report+="## Source Effectiveness"$'\n'
    local source_count
    source_count="$(printf '%s' "$evaluations" | jq '.source_effectiveness.sources | length')"
    if [[ "$source_count" -gt 0 ]]; then
        local i=0
        while (( i < source_count )); do
            local sname shit_rate srec
            sname="$(printf '%s' "$evaluations" | jq -r ".source_effectiveness.sources[$i].name")"
            shit_rate="$(printf '%s' "$evaluations" | jq -r ".source_effectiveness.sources[$i].hit_rate")"
            srec="$(printf '%s' "$evaluations" | jq -r ".source_effectiveness.sources[$i].recommendation")"
            report+="- ${sname}: hit_rate=${shit_rate}, recommendation=**${srec}**"$'\n'
            (( i++ )) || true
        done
    else
        report+="- No source data available."$'\n'
    fi
    report+=""$'\n'

    # Strategic Drift
    local ambition_trend risk_aversion
    ambition_trend="$(printf '%s' "$evaluations" | jq -r '.strategic_drift.ambition_trend')"
    risk_aversion="$(printf '%s' "$evaluations" | jq -r '.strategic_drift.risk_aversion')"

    report+="## Strategic Drift"$'\n'
    report+="- Ambition trend: **${ambition_trend}**"$'\n'
    report+="- Risk aversion: **${risk_aversion}**"$'\n'

    # Category distribution
    local cat_dist
    cat_dist="$(printf '%s' "$evaluations" | jq -r '.strategic_drift.category_distribution | to_entries | map("  - \(.key): \(.value)") | join("\n")')"
    if [[ -n "$cat_dist" ]]; then
        report+="- Category distribution:"$'\n'
        report+="${cat_dist}"$'\n'
    fi
    report+=""$'\n'

    # Proposals
    report+="## Proposals"$'\n'
    local proposal_count
    proposal_count="$(printf '%s' "$proposals" | jq 'length')"
    if [[ "$proposal_count" -gt 0 ]]; then
        local i=0
        while (( i < proposal_count )); do
            local pid preason paction
            pid="$(printf '%s' "$proposals" | jq -r ".[$i].id")"
            preason="$(printf '%s' "$proposals" | jq -r ".[$i].reason")"
            paction="$(printf '%s' "$proposals" | jq -r ".[$i].action")"
            report+="### ${pid}"$'\n'
            report+="- Reason: ${preason}"$'\n'
            report+="- Action: ${paction}"$'\n'
            report+=""$'\n'
            (( i++ )) || true
        done
    else
        report+="No proposals generated — system is healthy."$'\n'
    fi

    printf '%s\n' "$report"
}

# ---------------------------------------------------------------------------
# meta_status <evolve_root>
# Shows the last meta evaluation summary.
# Reads from $evolve_root/meta/last-report.md.
# ---------------------------------------------------------------------------
meta_status() {
    local evolve_root="$1"
    local report_file="$evolve_root/meta/last-report.md"

    if [[ ! -f "$report_file" ]]; then
        echo "No meta evaluations yet. Run 'evolve meta run' to generate one."
        return 0
    fi

    cat "$report_file"
}
