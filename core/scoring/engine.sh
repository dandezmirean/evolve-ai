#!/usr/bin/env bash
# core/scoring/engine.sh — Four-layer scoring aggregation engine for evolve-ai
set -euo pipefail

_SCORING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SCORING_CORE_DIR="$(cd "$_SCORING_DIR/.." && pwd)"

# Source config parser if not already loaded
if ! declare -f load_config >/dev/null 2>&1; then
    source "$_SCORING_CORE_DIR/config.sh"
fi

# ---------------------------------------------------------------------------
# scoring_run_heuristic <genome_yaml> <workspace> <change_id> <before_or_after>
# Runs all heuristic scorers defined in the genome and records results.
# Saves to $workspace/scores/$change_id-heuristic-{before,after}.json
# ---------------------------------------------------------------------------
scoring_run_heuristic() {
    local genome_yaml="$1"
    local workspace="$2"
    local change_id="$3"
    local before_or_after="$4"

    mkdir -p "$workspace/scores"
    local out_file="$workspace/scores/${change_id}-heuristic-${before_or_after}.json"

    # Extract heuristic scorers from genome YAML
    # Format: scorers.heuristic[] entries with name, command, weight, direction
    local scorers_json="[]"

    if [[ -f "$genome_yaml" ]]; then
        # Parse heuristic scorer blocks from YAML
        # Each scorer is a block under scorers.heuristic with name, command, weight, direction
        scorers_json="$(_parse_scorer_list "$genome_yaml" "heuristic")"
    fi

    local count
    count="$(printf '%s' "$scorers_json" | jq 'length')"

    if [[ "$count" -eq 0 ]]; then
        echo "[]" > "$out_file"
        return 0
    fi

    local results="[]"
    local i=0
    while (( i < count )); do
        local name command weight direction
        name="$(printf '%s' "$scorers_json" | jq -r ".[$i].name")"
        command="$(printf '%s' "$scorers_json" | jq -r ".[$i].command")"
        weight="$(printf '%s' "$scorers_json" | jq -r ".[$i].weight // 1")"
        direction="$(printf '%s' "$scorers_json" | jq -r ".[$i].direction // \"higher_is_better\"")"

        # Run the command and capture numeric output
        local value="0"
        if [[ -n "$command" && "$command" != "null" ]]; then
            value="$(eval "$command" 2>/dev/null || echo "0")"
            # Ensure value is numeric
            if ! printf '%s' "$value" | grep -qE '^-?[0-9]+\.?[0-9]*$'; then
                value="0"
            fi
        fi

        results="$(printf '%s' "$results" | jq \
            --arg name "$name" \
            --argjson value "$value" \
            --argjson weight "$weight" \
            --arg direction "$direction" \
            '. + [{"name": $name, "value": $value, "weight": $weight, "direction": $direction}]')"

        (( i++ )) || true
    done

    printf '%s\n' "$results" > "$out_file"
    return 0
}

# ---------------------------------------------------------------------------
# scoring_run_llm_judge <genome_yaml> <workspace> <change_id> <diff_file>
# Invokes provider with judge prompt + diff. Saves LLM judge result.
# Defaults to 0.5 (neutral) if provider unavailable.
# ---------------------------------------------------------------------------
scoring_run_llm_judge() {
    local genome_yaml="$1"
    local workspace="$2"
    local change_id="$3"
    local diff_file="$4"

    mkdir -p "$workspace/scores"
    local out_file="$workspace/scores/${change_id}-llm-judge.json"

    # Check if llm_judge is enabled in genome
    local llm_enabled="false"
    if [[ -f "$genome_yaml" ]]; then
        local saved_cache="$_CONFIG_CACHE"
        load_config "$genome_yaml"
        llm_enabled="$(config_get_default "llm_judge.enabled" "false")"
        _CONFIG_CACHE="$saved_cache"
    fi

    if [[ "$llm_enabled" != "true" ]]; then
        printf '{"score": 0.5, "reasoning": "LLM judge not enabled"}\n' > "$out_file"
        return 0
    fi

    # Check if provider_invoke is available
    if ! declare -f provider_invoke >/dev/null 2>&1; then
        printf '{"score": 0.5, "reasoning": "provider_invoke not available"}\n' > "$out_file"
        return 0
    fi

    # Build judge prompt
    local prompt_file
    prompt_file="$(mktemp)"
    local judge_prompt
    judge_prompt="$(config_get_default "llm_judge.prompt" "Rate this change from 0.0 to 1.0 based on quality and impact.")"

    {
        echo "$judge_prompt"
        echo ""
        echo "## Diff"
        echo '```'
        if [[ -f "$diff_file" ]]; then
            cat "$diff_file"
        else
            echo "(no diff available)"
        fi
        echo '```'
        echo ""
        echo "Respond with ONLY a JSON object: {\"score\": <0.0-1.0>, \"reasoning\": \"<brief>\"}"
    } > "$prompt_file"

    # Invoke provider
    local response
    response="$(provider_invoke "$prompt_file" 1 "$workspace" "llm-judge" 2>/dev/null)" || {
        printf '{"score": 0.5, "reasoning": "provider_invoke failed"}\n' > "$out_file"
        rm -f "$prompt_file"
        return 0
    }
    rm -f "$prompt_file"

    # Try to extract JSON from response
    local score reasoning
    score="$(printf '%s' "$response" | jq -r '.score // 0.5' 2>/dev/null)" || score="0.5"
    reasoning="$(printf '%s' "$response" | jq -r '.reasoning // "no reasoning"' 2>/dev/null)" || reasoning="no reasoning"

    # Clamp score to 0.0-1.0
    score="$(printf '%s' "$score" | awk '{if ($1 < 0) print 0; else if ($1 > 1) print 1; else print $1}')"

    jq -n --argjson score "$score" --arg reasoning "$reasoning" \
        '{"score": $score, "reasoning": $reasoning}' > "$out_file"

    return 0
}

# ---------------------------------------------------------------------------
# scoring_run_kpi <workspace> <change_id> <pool_file>
# Checks pool entry's kpi_checks array. Compares against baseline+threshold.
# Saves to $workspace/scores/$change_id-kpi.json
# ---------------------------------------------------------------------------
scoring_run_kpi() {
    local workspace="$1"
    local change_id="$2"
    local pool_file="$3"

    mkdir -p "$workspace/scores"
    local out_file="$workspace/scores/${change_id}-kpi.json"

    # Get kpi_checks from pool entry
    local kpi_checks="[]"
    if [[ -f "$pool_file" ]]; then
        kpi_checks="$(jq -r --arg id "$change_id" \
            '(.[] | select(.id == $id) | .kpi_checks) // []' "$pool_file" 2>/dev/null)" || kpi_checks="[]"
    fi

    if [[ "$kpi_checks" == "null" || "$kpi_checks" == "[]" ]]; then
        printf '{"result": "no_kpi", "checks": []}\n' > "$out_file"
        return 0
    fi

    local count
    count="$(printf '%s' "$kpi_checks" | jq 'length')"

    local results="[]"
    local overall_result="pass"
    local i=0
    while (( i < count )); do
        local name command baseline threshold
        name="$(printf '%s' "$kpi_checks" | jq -r ".[$i].name // \"kpi_$i\"")"
        command="$(printf '%s' "$kpi_checks" | jq -r ".[$i].command")"
        baseline="$(printf '%s' "$kpi_checks" | jq -r ".[$i].baseline // 0")"
        threshold="$(printf '%s' "$kpi_checks" | jq -r ".[$i].threshold // 0")"

        local actual="0"
        if [[ -n "$command" && "$command" != "null" ]]; then
            actual="$(eval "$command" 2>/dev/null || echo "0")"
            if ! printf '%s' "$actual" | grep -qE '^-?[0-9]+\.?[0-9]*$'; then
                actual="0"
            fi
        fi

        # Check if KPI regressed: actual < baseline - threshold
        local check_result="pass"
        local regressed
        regressed="$(awk -v a="$actual" -v b="$baseline" -v t="$threshold" \
            'BEGIN { if (a < b - t) print "yes"; else print "no" }')"

        if [[ "$regressed" == "yes" ]]; then
            check_result="regress"
            overall_result="regress"
        fi

        results="$(printf '%s' "$results" | jq \
            --arg name "$name" \
            --argjson actual "$actual" \
            --argjson baseline "$baseline" \
            --argjson threshold "$threshold" \
            --arg result "$check_result" \
            '. + [{"name": $name, "actual": $actual, "baseline": $baseline, "threshold": $threshold, "result": $result}]')"

        (( i++ )) || true
    done

    jq -n --arg result "$overall_result" --argjson checks "$results" \
        '{"result": $result, "checks": $checks}' > "$out_file"

    return 0
}

# ---------------------------------------------------------------------------
# scoring_run_user_defined <genome_yaml> <workspace> <change_id> <before_or_after>
# Same pattern as heuristic but reads from scorers.user_defined[].
# Saves to $workspace/scores/$change_id-user-{before,after}.json
# ---------------------------------------------------------------------------
scoring_run_user_defined() {
    local genome_yaml="$1"
    local workspace="$2"
    local change_id="$3"
    local before_or_after="$4"

    mkdir -p "$workspace/scores"
    local out_file="$workspace/scores/${change_id}-user-${before_or_after}.json"

    local scorers_json="[]"

    if [[ -f "$genome_yaml" ]]; then
        scorers_json="$(_parse_scorer_list "$genome_yaml" "user_defined")"
    fi

    local count
    count="$(printf '%s' "$scorers_json" | jq 'length')"

    if [[ "$count" -eq 0 ]]; then
        echo "[]" > "$out_file"
        return 0
    fi

    local results="[]"
    local i=0
    while (( i < count )); do
        local name command weight direction
        name="$(printf '%s' "$scorers_json" | jq -r ".[$i].name")"
        command="$(printf '%s' "$scorers_json" | jq -r ".[$i].command")"
        weight="$(printf '%s' "$scorers_json" | jq -r ".[$i].weight // 1")"
        direction="$(printf '%s' "$scorers_json" | jq -r ".[$i].direction // \"higher_is_better\"")"

        local value="0"
        if [[ -n "$command" && "$command" != "null" ]]; then
            value="$(eval "$command" 2>/dev/null || echo "0")"
            if ! printf '%s' "$value" | grep -qE '^-?[0-9]+\.?[0-9]*$'; then
                value="0"
            fi
        fi

        results="$(printf '%s' "$results" | jq \
            --arg name "$name" \
            --argjson value "$value" \
            --argjson weight "$weight" \
            --arg direction "$direction" \
            '. + [{"name": $name, "value": $value, "weight": $weight, "direction": $direction}]')"

        (( i++ )) || true
    done

    printf '%s\n' "$results" > "$out_file"
    return 0
}

# ---------------------------------------------------------------------------
# scoring_compute_weighted_delta <before_file> <after_file>
# Computes weighted average delta across heuristic scorers.
# Accounts for direction (lower_is_better has delta negated).
# Outputs a single number to stdout.
# ---------------------------------------------------------------------------
scoring_compute_weighted_delta() {
    local before_file="$1"
    local after_file="$2"

    if [[ ! -f "$before_file" || ! -f "$after_file" ]]; then
        echo "0"
        return 0
    fi

    # Merge before and after by name, compute weighted delta
    jq -n \
        --slurpfile before "$before_file" \
        --slurpfile after "$after_file" \
        '
        ($before[0] // []) as $b |
        ($after[0] // []) as $a |
        if ($b | length) == 0 or ($a | length) == 0 then 0
        else
            # Build lookup from before by name
            ($b | map({(.name): .value}) | add // {}) as $before_map |
            # Compute weighted deltas
            ($a | map(
                (.name) as $name |
                (.value) as $after_val |
                (.weight // 1) as $w |
                (.direction // "higher_is_better") as $dir |
                ($before_map[$name] // 0) as $before_val |
                ($after_val - $before_val) as $raw_delta |
                # Negate delta for lower_is_better (improvement = lower after)
                (if $dir == "lower_is_better" then (-$raw_delta) else $raw_delta end) as $delta |
                {"delta": $delta, "weight": $w}
            )) as $deltas |
            ($deltas | map(.weight) | add) as $total_weight |
            if $total_weight == 0 then 0
            else
                ($deltas | map(.delta * .weight) | add) / $total_weight
            end
        end
        '
}

# ---------------------------------------------------------------------------
# scoring_aggregate <workspace> <change_id>
# Reads all score files and produces final impact_signal.
# Saves to $workspace/scores/$change_id-aggregate.json
# ---------------------------------------------------------------------------
scoring_aggregate() {
    local workspace="$1"
    local change_id="$2"

    local scores_dir="$workspace/scores"
    mkdir -p "$scores_dir"
    local out_file="$scores_dir/${change_id}-aggregate.json"

    local heuristic_before="$scores_dir/${change_id}-heuristic-before.json"
    local heuristic_after="$scores_dir/${change_id}-heuristic-after.json"
    local llm_judge_file="$scores_dir/${change_id}-llm-judge.json"
    local kpi_file="$scores_dir/${change_id}-kpi.json"

    # Determine what data is available
    local has_heuristic="false"
    local has_llm="false"
    local has_kpi="false"

    local heuristic_delta="0"
    local llm_score="0.5"
    local kpi_result="no_kpi"

    # Check heuristic scores
    if [[ -f "$heuristic_before" && -f "$heuristic_after" ]]; then
        local before_len after_len
        before_len="$(jq 'length' "$heuristic_before" 2>/dev/null)" || before_len="0"
        after_len="$(jq 'length' "$heuristic_after" 2>/dev/null)" || after_len="0"
        if [[ "$before_len" -gt 0 && "$after_len" -gt 0 ]]; then
            has_heuristic="true"
            heuristic_delta="$(scoring_compute_weighted_delta "$heuristic_before" "$heuristic_after")"
        fi
    fi

    # Check LLM judge score
    if [[ -f "$llm_judge_file" ]]; then
        local judge_score
        judge_score="$(jq -r '.score // 0.5' "$llm_judge_file" 2>/dev/null)" || judge_score="0.5"
        if [[ "$judge_score" != "0.5" ]] || grep -q '"reasoning"' "$llm_judge_file" 2>/dev/null; then
            # LLM judge ran (even if score is 0.5, if it has reasoning it ran)
            local reasoning
            reasoning="$(jq -r '.reasoning // ""' "$llm_judge_file" 2>/dev/null)" || reasoning=""
            if [[ "$reasoning" != "LLM judge not enabled" && "$reasoning" != "provider_invoke not available" ]]; then
                has_llm="true"
            fi
        fi
        llm_score="$judge_score"
    fi

    # Check KPI result
    if [[ -f "$kpi_file" ]]; then
        kpi_result="$(jq -r '.result // "no_kpi"' "$kpi_file" 2>/dev/null)" || kpi_result="no_kpi"
        if [[ "$kpi_result" != "no_kpi" ]]; then
            has_kpi="true"
        fi
    fi

    # Determine impact signal
    local impact_signal="unmeasured"

    if [[ "$has_heuristic" == "false" && "$has_llm" == "false" && "$has_kpi" == "false" ]]; then
        impact_signal="unmeasured"
    elif [[ "$kpi_result" == "regress" ]]; then
        # KPI is hard gate
        impact_signal="negative"
    else
        # Determine from heuristic delta and LLM score
        local h_positive h_negative l_positive l_negative
        h_positive="$(awk -v d="$heuristic_delta" 'BEGIN { print (d > 0) ? "true" : "false" }')"
        h_negative="$(awk -v d="$heuristic_delta" 'BEGIN { print (d < 0) ? "true" : "false" }')"
        l_positive="$(awk -v s="$llm_score" 'BEGIN { print (s >= 0.5) ? "true" : "false" }')"
        l_negative="$(awk -v s="$llm_score" 'BEGIN { print (s < 0.5) ? "true" : "false" }')"

        if [[ "$has_heuristic" == "true" && "$has_llm" == "true" ]]; then
            if [[ "$h_positive" == "true" && "$l_positive" == "true" ]]; then
                impact_signal="positive"
            elif [[ "$h_negative" == "true" && "$l_negative" == "true" ]]; then
                impact_signal="negative"
            else
                impact_signal="neutral"
            fi
        elif [[ "$has_heuristic" == "true" ]]; then
            if [[ "$h_positive" == "true" ]]; then
                impact_signal="positive"
            elif [[ "$h_negative" == "true" ]]; then
                impact_signal="negative"
            else
                impact_signal="neutral"
            fi
        elif [[ "$has_llm" == "true" ]]; then
            if [[ "$l_positive" == "true" ]]; then
                impact_signal="positive"
            else
                impact_signal="negative"
            fi
        elif [[ "$has_kpi" == "true" ]]; then
            # KPI passed (not regressed) and no other signals
            impact_signal="positive"
        fi
    fi

    jq -n \
        --arg impact_signal "$impact_signal" \
        --argjson heuristic_delta "$heuristic_delta" \
        --argjson llm_score "$llm_score" \
        --arg kpi_result "$kpi_result" \
        --argjson has_heuristic "$has_heuristic" \
        --argjson has_llm "$has_llm" \
        --argjson has_kpi "$has_kpi" \
        '{
            "impact_signal": $impact_signal,
            "heuristic_delta": $heuristic_delta,
            "llm_score": $llm_score,
            "kpi_result": $kpi_result,
            "details": {
                "has_heuristic": $has_heuristic,
                "has_llm": $has_llm,
                "has_kpi": $has_kpi
            }
        }' > "$out_file"

    return 0
}

# ---------------------------------------------------------------------------
# _parse_scorer_list <genome_yaml> <scorer_type>
# Parses a YAML file to extract scorer definitions from scorers.<type>[].
# Outputs a JSON array of {name, command, weight, direction}.
# This is a simplified YAML list parser for our specific format.
# ---------------------------------------------------------------------------
_parse_scorer_list() {
    local genome_yaml="$1"
    local scorer_type="$2"

    # Parse YAML scorer blocks manually
    # Expected format:
    # scorers:
    #   heuristic:
    #     - name: "scorer_name"
    #       command: "some command"
    #       weight: 1
    #       direction: "higher_is_better"
    awk -v type="$scorer_type" '
    function flush_item() {
        if (in_item && name != "") {
            if (!first) printf ","
            gsub(/"/, "\\\"", command)
            gsub(/"/, "\\\"", name)
            printf "{\"name\":\"%s\",\"command\":\"%s\",\"weight\":%s,\"direction\":\"%s\"}", name, command, weight, direction
            first = 0
        }
    }
    function parse_kv(line,    colon, k, v) {
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+#.*$/, "", line)
        colon = index(line, ":")
        if (colon > 0) {
            k = substr(line, 1, colon - 1)
            v = substr(line, colon + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            gsub(/^["'"'"']|["'"'"']$/, "", v)
            if (k == "name") name = v
            else if (k == "command") command = v
            else if (k == "weight") weight = v
            else if (k == "direction") direction = v
        }
    }
    BEGIN {
        in_scorers = 0; in_type = 0; in_item = 0
        name = ""; command = ""; weight = "1"; direction = "higher_is_better"
        first = 1
        printf "["
    }

    /^scorers:/ { in_scorers = 1; next }
    /^[^ ]/ && !/^scorers:/ { in_scorers = 0; in_type = 0 }

    in_scorers && $0 ~ "^  " type ":" { in_type = 1; next }
    in_scorers && /^  [^ ]/ && !($0 ~ "^  " type ":") { in_type = 0 }

    in_type && /^    - / {
        flush_item()
        in_item = 1
        name = ""; command = ""; weight = "1"; direction = "higher_is_better"
        # Extract key:value from "    - key: value" line
        line = $0
        sub(/^    - /, "", line)
        parse_kv(line)
        next
    }

    in_type && in_item && /^      [^ -]/ {
        parse_kv($0)
    }

    END {
        flush_item()
        printf "]"
    }
    ' "$genome_yaml"
}
