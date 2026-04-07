#!/usr/bin/env bash
# core/resume/resume-runner.sh — interactive resume session for human review

_RESUME_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RESUME_RUNNER_DIR/../pool.sh"
source "$_RESUME_RUNNER_DIR/../directives/manager.sh"
source "$_RESUME_RUNNER_DIR/context-generator.sh"

# ---------------------------------------------------------------------------
# _find_context_file <evolve_root> <context_id>
#
# Searches resume-context/*/ directories for a file matching context_id.
# context_id format: {change_id}-{decision_type} or "circuit-breaker"
# Returns the full path or empty string if not found.
# ---------------------------------------------------------------------------
_find_context_file() {
    local evolve_root="$1"
    local context_id="$2"
    local context_base="$evolve_root/resume-context"

    if [[ ! -d "$context_base" ]]; then
        return 0
    fi

    # Search newest first (reverse sort)
    local date_dir
    for date_dir in $(ls -1d "$context_base"/*/ 2>/dev/null | sort -r); do
        local candidate="$date_dir${context_id}.md"
        if [[ -f "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
}

# ---------------------------------------------------------------------------
# list_resume_contexts <evolve_root>
#
# Lists all available resume contexts, newest first, formatted nicely.
# ---------------------------------------------------------------------------
list_resume_contexts() {
    local evolve_root="$1"
    local context_base="$evolve_root/resume-context"

    if [[ ! -d "$context_base" ]]; then
        echo "No resume contexts available."
        return 0
    fi

    local found=0
    local date_dir
    for date_dir in $(ls -1d "$context_base"/*/ 2>/dev/null | sort -r); do
        local date_name
        date_name="$(basename "$date_dir")"
        local ctx_file
        for ctx_file in "$date_dir"*.md; do
            [[ ! -f "$ctx_file" ]] && continue
            found=1
            local ctx_name
            ctx_name="$(basename "$ctx_file" .md)"
            # Extract the decision line from the file
            local decision_line
            decision_line="$(grep '^[*]*Decision:[*]*' "$ctx_file" 2>/dev/null | head -1 | sed 's/^[*]*Decision:[*]* //' || true)"
            printf "  %-12s  %-40s  %s\n" "$date_name" "$ctx_name" "$decision_line"
        done
    done

    if [[ "$found" -eq 0 ]]; then
        echo "No resume contexts available."
    fi
}

# ---------------------------------------------------------------------------
# resume_session <evolve_root> <context_id>
#
# Loads a resume context and starts an interactive session.
# ---------------------------------------------------------------------------
resume_session() {
    local evolve_root="$1"
    local context_id="$2"

    # Find the context file
    local context_file
    context_file="$(_find_context_file "$evolve_root" "$context_id")"

    if [[ -z "$context_file" ]]; then
        echo "Resume context not found: $context_id" >&2
        echo "Use 'evolve resume' to list available contexts." >&2
        return 1
    fi

    # Display the context
    echo "═══════════════════════════════════════════════════════════════"
    cat "$context_file"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Choose an action:"
    echo "  1) Override  — implement this anyway with your reasoning"
    echo "  2) Redirect  — reframe what this change is about"
    echo "  3) Expand    — research this deeper"
    echo "  4) Modify    — reduce or change scope"
    echo "  5) Directive — create a persistent rule for future runs"
    echo "  6) Nothing   — review complete, no action needed"
    echo ""

    local choice
    printf "Enter choice (1-6): "
    read -r choice

    # Extract the change_id from context_id (remove the -decision_type suffix)
    local change_id
    change_id="$(echo "$context_id" | sed 's/-[^-]*$//')"

    case "$choice" in
        1)
            # Override: create an override directive
            printf "Enter your reasoning: "
            local reasoning
            read -r reasoning
            local directives_dir="$evolve_root/directives"
            mkdir -p "$directives_dir"
            directive_create "$directives_dir" "override" "$change_id" "$reasoning" "human-resume" "null"
            echo ""
            echo "Override directive created for $change_id."
            echo "The pipeline will implement this change on the next run."
            ;;
        2)
            # Redirect: create a pool injection with new framing
            printf "Enter new framing: "
            local new_framing
            read -r new_framing
            local injections_dir="$evolve_root/resume-context/injections"
            mkdir -p "$injections_dir"
            local inject_file="$injections_dir/${change_id}.json"
            jq -n \
                --arg id "${change_id}-redirect" \
                --arg desc "$new_framing" \
                --arg origin "$context_id" \
                --arg created "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                '{
                    id: $id,
                    source: "human",
                    status: "pending",
                    description: $desc,
                    origin_context: $origin,
                    created: $created
                }' > "$inject_file"
            echo ""
            echo "Pool injection created: $inject_file"
            echo "This will be picked up on the next pipeline run."
            ;;
        3)
            # Expand: create a pool injection requesting deeper research
            printf "What should be researched? "
            local research_topic
            read -r research_topic
            local injections_dir="$evolve_root/resume-context/injections"
            mkdir -p "$injections_dir"
            local inject_file="$injections_dir/${change_id}.json"
            jq -n \
                --arg id "${change_id}-expand" \
                --arg desc "Deep research: $research_topic" \
                --arg origin "$context_id" \
                --arg created "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                '{
                    id: $id,
                    source: "human",
                    status: "pending",
                    description: $desc,
                    origin_context: $origin,
                    created: $created
                }' > "$inject_file"
            echo ""
            echo "Research injection created: $inject_file"
            echo "The pipeline will research this on the next run."
            ;;
        4)
            # Modify: create a pool injection with modified scope
            printf "Enter modified scope: "
            local modified_scope
            read -r modified_scope
            local injections_dir="$evolve_root/resume-context/injections"
            mkdir -p "$injections_dir"
            local inject_file="$injections_dir/${change_id}.json"
            jq -n \
                --arg id "${change_id}-modified" \
                --arg desc "$modified_scope" \
                --arg origin "$context_id" \
                --arg created "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                '{
                    id: $id,
                    source: "human",
                    status: "pending",
                    description: $desc,
                    origin_context: $origin,
                    created: $created
                }' > "$inject_file"
            echo ""
            echo "Modified injection created: $inject_file"
            echo "The pipeline will use this modified scope on the next run."
            ;;
        5)
            # Directive: create a persistent rule
            echo "Directive types: lock, priority, constraint, override"
            printf "Directive type: "
            local dtype
            read -r dtype
            printf "Target (file path, category, or change ID): "
            local dtarget
            read -r dtarget
            printf "Rule: "
            local drule
            read -r drule
            printf "Expires (YYYY-MM-DD or 'never'): "
            local dexpires
            read -r dexpires
            [[ "$dexpires" == "never" ]] && dexpires="null"

            local directives_dir="$evolve_root/directives"
            mkdir -p "$directives_dir"
            directive_create "$directives_dir" "$dtype" "$dtarget" "$drule" "human-resume" "$dexpires"
            echo ""
            echo "Directive created: type=$dtype target=$dtarget"
            ;;
        6)
            echo ""
            echo "Review complete. No action taken for $context_id."
            ;;
        *)
            echo "Invalid choice: $choice" >&2
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# resume_circuit_breaker <evolve_root>
#
# Special flow for circuit breaker review.
# ---------------------------------------------------------------------------
resume_circuit_breaker() {
    local evolve_root="$1"

    # Find or generate the circuit breaker context
    local context_file
    context_file="$(_find_context_file "$evolve_root" "circuit-breaker")"

    if [[ -z "$context_file" ]]; then
        # Generate one using the latest workspace
        local workspace_base="$evolve_root/workspace"
        local latest_ws
        latest_ws="$(ls -1d "$workspace_base"/*/ 2>/dev/null | sort | tail -1 || true)"
        latest_ws="${latest_ws%/}"

        if [[ -z "$latest_ws" || ! -d "$latest_ws" ]]; then
            echo "No workspace found to generate circuit breaker context." >&2
            return 1
        fi

        context_file="$(generate_circuit_breaker_context "$evolve_root" "$latest_ws")"
    fi

    # Display the context
    echo "═══════════════════════════════════════════════════════════════"
    cat "$context_file"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Choose an action:"
    echo "  1) Reset    — clear the circuit breaker, allow pipeline to resume"
    echo "  2) Directive — create constraints to prevent recurrence"
    echo "  3) Review   — examine each negative-impact change individually"
    echo "  4) Nothing  — keep the circuit breaker tripped"
    echo ""

    local choice
    printf "Enter choice (1-4): "
    read -r choice

    case "$choice" in
        1)
            local trip_marker="$evolve_root/circuit-breaker.trip"
            if [[ -f "$trip_marker" ]]; then
                rm "$trip_marker"
                echo "Circuit breaker reset. Pipeline can resume on next run."
            else
                echo "No circuit breaker trip marker found (already clear)."
            fi
            ;;
        2)
            echo "Creating constraint directive to prevent recurrence."
            printf "Rule (what should the pipeline avoid?): "
            local rule
            read -r rule
            printf "Expires (YYYY-MM-DD or 'never'): "
            local expires
            read -r expires
            [[ "$expires" == "never" ]] && expires="null"

            local directives_dir="$evolve_root/directives"
            mkdir -p "$directives_dir"
            directive_create "$directives_dir" "constraint" "pipeline" "$rule" "human-circuit-breaker" "$expires"
            echo "Constraint directive created."
            ;;
        3)
            # List negative-impact changes and let user review each
            echo "Listing negative-impact changes for individual review..."
            local context_base="$evolve_root/resume-context"
            if [[ -d "$context_base" ]]; then
                local ctx_file
                for ctx_file in "$context_base"/*/*-reverted.md "$context_base"/*/*-killed.md; do
                    [[ ! -f "$ctx_file" ]] && continue
                    local ctx_name
                    ctx_name="$(basename "$ctx_file" .md)"
                    echo "  - $ctx_name"
                done
                echo ""
                echo "Use 'evolve resume <context-id>' to review each one."
            else
                echo "No resume contexts found."
            fi
            ;;
        4)
            echo "Circuit breaker remains tripped. Pipeline will not run."
            ;;
        *)
            echo "Invalid choice: $choice" >&2
            return 1
            ;;
    esac
}
