#!/usr/bin/env bash
# core/orchestrator.sh — Main pipeline orchestrator for evolve-ai
# Sequences phases, handles convergence detection, and crash recovery.

SCRIPT_DIR_ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR_ORCH/config.sh"
source "$SCRIPT_DIR_ORCH/pool.sh"
source "$SCRIPT_DIR_ORCH/lock.sh"
source "$SCRIPT_DIR_ORCH/housekeeping.sh"
source "$SCRIPT_DIR_ORCH/resources.sh"

# ---------------------------------------------------------------------------
# create_workspace <evolve_root> [date_suffix]
# Creates a workspace directory under evolve_root/workspace/<date_suffix> and
# initialises an empty pool.json inside it.
# Outputs the full path of the created workspace directory.
# date_suffix defaults to YYYY-MM-DD.
# ---------------------------------------------------------------------------
create_workspace() {
    local evolve_root="$1"
    local date_suffix="${2:-$(date +%Y-%m-%d)}"

    local workspace_dir="$evolve_root/workspace/$date_suffix"
    mkdir -p "$workspace_dir"

    local pool_file="$workspace_dir/pool.json"
    if [[ ! -f "$pool_file" ]]; then
        pool_init "$pool_file"
    fi

    printf '%s' "$workspace_dir"
}

# ---------------------------------------------------------------------------
# check_convergence <pool_file> [prev_hash]
# Returns 0 if the pool has converged (settled or empty).
# Returns 1 if not converged (work still in progress or stalled but not done).
# A stall is when prev_hash is provided and the current hash matches — the
# caller is responsible for counting stalls; this function just returns 1.
# ---------------------------------------------------------------------------
check_convergence() {
    local pool_file="$1"
    local prev_hash="${2:-}"

    # Empty pool — nothing to do, consider converged
    if pool_is_empty "$pool_file"; then
        return 0
    fi

    # All entries in terminal states — converged
    if pool_is_settled "$pool_file"; then
        return 0
    fi

    # If we have a previous hash, check for stall
    if [[ -n "$prev_hash" ]]; then
        local current_hash
        current_hash="$(pool_status_hash "$pool_file")"
        if [[ "$current_hash" == "$prev_hash" ]]; then
            # Hash unchanged — stalled, but NOT converged
            return 1
        fi
    fi

    # Pool has active entries and hash changed (or no prev_hash) — not converged
    return 1
}

# ---------------------------------------------------------------------------
# run_phase <phase_name> <prompt_file> <workspace> <max_turns>
# Runs a single pipeline phase.
# Checks resource gates first — returns 2 if gates fail.
# Calls provider_invoke if defined, otherwise prints a STUB message to stderr.
# ---------------------------------------------------------------------------
run_phase() {
    local phase_name="$1"
    local prompt_file="$2"
    local workspace="$3"
    local max_turns="$4"

    # Resource gate check
    if ! check_all_gates; then
        echo "[orchestrator] run_phase: resource gates failed for phase '$phase_name'" >&2
        return 2
    fi

    echo "[orchestrator] Running phase: $phase_name"

    # Invoke provider if available, otherwise STUB
    if declare -f provider_invoke >/dev/null 2>&1; then
        provider_invoke "$phase_name" "$prompt_file" "$workspace" "$max_turns"
    else
        echo "[orchestrator] STUB: provider_invoke not available — skipping phase '$phase_name'" >&2
    fi
}

# ---------------------------------------------------------------------------
# execute_rollback_manifest <manifest_file>
# Reads a JSON manifest with a .changes array.
# Each element must have an .undo string command which is executed in order.
# ---------------------------------------------------------------------------
execute_rollback_manifest() {
    local manifest_file="$1"

    if [[ ! -f "$manifest_file" ]]; then
        echo "[orchestrator] execute_rollback_manifest: manifest not found: $manifest_file" >&2
        return 1
    fi

    local count
    count="$(jq '.changes | length' "$manifest_file" 2>/dev/null)" || {
        echo "[orchestrator] execute_rollback_manifest: failed to parse manifest" >&2
        return 1
    }

    local i=0
    while (( i < count )); do
        local undo_cmd
        undo_cmd="$(jq -r ".changes[$i].undo" "$manifest_file")"
        if [[ -n "$undo_cmd" && "$undo_cmd" != "null" ]]; then
            echo "[orchestrator] Executing rollback step $i: $undo_cmd" >&2
            eval "$undo_cmd" || echo "[orchestrator] Rollback step $i failed (continuing)" >&2
        fi
        (( i++ )) || true
    done
}

# ---------------------------------------------------------------------------
# cleanup_on_error <evolve_root> <lock_file> <snapshot_tag>
# Crash recovery handler:
#   1. git checkout snapshot_tag -- . (restores files without moving HEAD)
#   2. Restore crontab from backup if it exists
#   3. Execute rollback manifest if present
#   4. Stub notification to stderr
#   5. Release lock
# ---------------------------------------------------------------------------
cleanup_on_error() {
    local evolve_root="$1"
    local lock_file="$2"
    local snapshot_tag="$3"

    echo "[orchestrator] CRASH RECOVERY: restoring snapshot '$snapshot_tag'" >&2

    # 1. Restore files via git checkout (NOT reset --hard)
    if [[ -n "$snapshot_tag" ]]; then
        git -C "$evolve_root" checkout "$snapshot_tag" -- . 2>/dev/null \
            || echo "[orchestrator] git checkout of snapshot failed" >&2
    fi

    # 2. Restore crontab from backup
    local crontab_bak="$evolve_root/crontab.bak"
    if [[ -f "$crontab_bak" ]]; then
        crontab "$crontab_bak" 2>/dev/null \
            && echo "[orchestrator] Crontab restored from backup" >&2 \
            || echo "[orchestrator] Failed to restore crontab" >&2
    fi

    # 3. Execute rollback manifest if present
    local manifest_file="$evolve_root/rollback-manifest.json"
    if [[ -f "$manifest_file" ]]; then
        execute_rollback_manifest "$manifest_file"
    fi

    # 4. Notify (stub)
    echo "[orchestrator] NOTIFY: pipeline crashed — snapshot '$snapshot_tag' restored in '$evolve_root'" >&2

    # 5. Release lock
    if [[ -n "$lock_file" ]]; then
        release_lock "$lock_file"
    fi
}

# ---------------------------------------------------------------------------
# run_pipeline <evolve_root> <mode>
# Main pipeline execution.
# mode: "directed" | "autonomous"
# ---------------------------------------------------------------------------
run_pipeline() {
    local evolve_root="$1"
    local mode="${2:-autonomous}"

    # --- Load config ---
    local config_file="$evolve_root/config/evolve.yaml"
    if [[ -f "$config_file" ]]; then
        load_config "$config_file"
    else
        echo "[orchestrator] Warning: config not found at $config_file, using defaults" >&2
    fi

    local max_stalls
    max_stalls="$(config_get_default "convergence.max_stalls" "3")"
    local max_iterations
    max_iterations="$(config_get_default "convergence.max_iterations" "10")"
    local max_turns
    max_turns="$(config_get_default "pipeline.max_turns" "50")"

    # --- Acquire lock ---
    local lock_file="$EVOLVE_DEFAULT_LOCK"
    if ! acquire_lock "$lock_file"; then
        echo "[orchestrator] Another pipeline is running (lock held). Exiting." >&2
        exit 1
    fi

    # --- Determine snapshot tag for crash recovery ---
    local today
    today="$(date +%Y-%m-%d)"
    local snapshot_tag="evolve-${today}-pre"

    # --- Set up crash recovery trap ---
    trap 'cleanup_on_error "$evolve_root" "$lock_file" "$snapshot_tag"' ERR INT TERM

    # --- Housekeeping ---
    run_housekeeping "$evolve_root"

    # --- Create workspace ---
    local workspace
    if [[ "$mode" == "directed" ]]; then
        # Directed mode: YYYY-MM-DD-iN naming with incrementing N
        local n=1
        local ws_suffix
        while true; do
            ws_suffix="${today}-i${n}"
            if [[ ! -d "$evolve_root/workspace/$ws_suffix" ]]; then
                break
            fi
            (( n++ )) || true
        done
        workspace="$(create_workspace "$evolve_root" "$ws_suffix")"
    else
        workspace="$(create_workspace "$evolve_root")"
    fi

    echo "[orchestrator] Workspace: $workspace"

    local pool_file="$workspace/pool.json"
    local prompts_dir="$evolve_root/prompts"

    # Helper: get prompt file path for a phase (falls back to /dev/null if missing)
    _prompt_for() {
        local phase="$1"
        local pf="$prompts_dir/${phase}.md"
        if [[ -f "$pf" ]]; then
            printf '%s' "$pf"
        else
            printf '/dev/null'
        fi
    }

    # --- Run phases based on mode ---
    local phase_rc

    if [[ "$mode" == "directed" ]]; then
        # Directed: digest → strategize → analyze → challenge → impl loop → metrics
        run_phase "digest"     "$(_prompt_for digest)"     "$workspace" "$max_turns" || { phase_rc=$?; [[ $phase_rc -eq 2 ]] && { release_lock "$lock_file"; trap - ERR INT TERM; return 2; }; }
        run_phase "strategize" "$(_prompt_for strategize)" "$workspace" "$max_turns" || { phase_rc=$?; [[ $phase_rc -eq 2 ]] && { release_lock "$lock_file"; trap - ERR INT TERM; return 2; }; }
        run_phase "analyze"    "$(_prompt_for analyze)"    "$workspace" "$max_turns" || { phase_rc=$?; [[ $phase_rc -eq 2 ]] && { release_lock "$lock_file"; trap - ERR INT TERM; return 2; }; }
        run_phase "challenge"  "$(_prompt_for challenge)"  "$workspace" "$max_turns" || { phase_rc=$?; [[ $phase_rc -eq 2 ]] && { release_lock "$lock_file"; trap - ERR INT TERM; return 2; }; }
    else
        # Autonomous: strategize → analyze → challenge → impl loop → metrics
        run_phase "strategize" "$(_prompt_for strategize)" "$workspace" "$max_turns" || { phase_rc=$?; [[ $phase_rc -eq 2 ]] && { release_lock "$lock_file"; trap - ERR INT TERM; return 2; }; }
        run_phase "analyze"    "$(_prompt_for analyze)"    "$workspace" "$max_turns" || { phase_rc=$?; [[ $phase_rc -eq 2 ]] && { release_lock "$lock_file"; trap - ERR INT TERM; return 2; }; }
        run_phase "challenge"  "$(_prompt_for challenge)"  "$workspace" "$max_turns" || { phase_rc=$?; [[ $phase_rc -eq 2 ]] && { release_lock "$lock_file"; trap - ERR INT TERM; return 2; }; }
    fi

    # --- If pool is empty after analyze: run finalize + metrics and exit ---
    if pool_is_empty "$pool_file"; then
        echo "[orchestrator] Pool is empty after analysis phases — skipping implementation loop" >&2
        run_phase "finalize" "$(_prompt_for finalize)" "$workspace" "$max_turns" || true
        run_phase "metrics"  "$(_prompt_for metrics)"  "$workspace" "$max_turns" || true
        release_lock "$lock_file"
        trap - ERR INT TERM
        return 0
    fi

    # --- Implementation loop: implement → validate → finalize ---
    local stall_count=0
    local prev_hash=""
    local iteration=0

    while (( iteration < max_iterations )); do
        (( iteration++ )) || true
        echo "[orchestrator] Implementation loop iteration $iteration / $max_iterations"

        run_phase "implement" "$(_prompt_for implement)" "$workspace" "$max_turns" || { phase_rc=$?; [[ $phase_rc -eq 2 ]] && break; }
        run_phase "validate"  "$(_prompt_for validate)"  "$workspace" "$max_turns" || { phase_rc=$?; [[ $phase_rc -eq 2 ]] && break; }
        run_phase "finalize"  "$(_prompt_for finalize)"  "$workspace" "$max_turns" || { phase_rc=$?; [[ $phase_rc -eq 2 ]] && break; }

        # Convergence check
        local current_hash
        current_hash="$(pool_status_hash "$pool_file")"

        if check_convergence "$pool_file" "$prev_hash"; then
            echo "[orchestrator] Pool converged after iteration $iteration"
            break
        fi

        if [[ -n "$prev_hash" && "$current_hash" == "$prev_hash" ]]; then
            # Hash unchanged — stall
            (( stall_count++ )) || true
            echo "[orchestrator] Stall detected (${stall_count}/${max_stalls})" >&2
            if (( stall_count >= max_stalls )); then
                echo "[orchestrator] Max stalls reached — running final finalize and stopping" >&2
                run_phase "finalize" "$(_prompt_for finalize)" "$workspace" "$max_turns" || true
                break
            fi
        else
            # Hash changed — reset stall counter
            stall_count=0
        fi

        prev_hash="$current_hash"
    done

    # --- Always run metrics at end ---
    run_phase "metrics" "$(_prompt_for metrics)" "$workspace" "$max_turns" || true

    # --- Release lock ---
    release_lock "$lock_file"
    trap - ERR INT TERM

    echo "[orchestrator] Pipeline complete."
}
