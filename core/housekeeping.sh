#!/usr/bin/env bash
# core/housekeeping.sh — Pre-pipeline housekeeping for evolve-ai

# shellcheck source=core/config.sh
HOUSEKEEPING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOUSEKEEPING_DIR/config.sh"

# run_housekeeping <evolve_root>
# Runs all pre-pipeline housekeeping steps. All steps are best-effort.
run_housekeeping() {
    local evolve_root="$1"

    if [[ -z "$evolve_root" ]]; then
        echo "run_housekeeping: evolve_root is required" >&2
        return 1
    fi

    if [[ ! -d "$evolve_root" ]]; then
        echo "run_housekeeping: directory not found: $evolve_root" >&2
        return 1
    fi

    local workspace_root="$evolve_root/workspace"
    local retention_days
    local tag_retention_days

    retention_days="$(config_get_default "retention.workspace_days" "14")"
    tag_retention_days="$(config_get_default "retention.git_tag_days" "30")"

    echo "[housekeeping] Starting pre-pipeline housekeeping in: $evolve_root"

    # 1. Clean old workspace directories
    echo "[housekeeping] Cleaning workspace dirs older than ${retention_days} days..."
    if [[ -d "$workspace_root" ]]; then
        find "$workspace_root" -maxdepth 1 -type d -mtime +"$retention_days" -exec rm -rf {} \; || true
    else
        echo "[housekeeping] Workspace root not found, skipping: $workspace_root"
    fi

    # 2. Prune old git tags
    echo "[housekeeping] Pruning git tags older than ${tag_retention_days} days..."
    _housekeeping_prune_git_tags "$evolve_root" "$tag_retention_days" || true

    # 3. Backup crontab
    echo "[housekeeping] Backing up crontab..."
    crontab -l > "$evolve_root/crontab.bak" 2>/dev/null || true

    # 4. Git snapshot + tag
    echo "[housekeeping] Creating git snapshot..."
    _housekeeping_git_snapshot "$evolve_root" || true

    echo "[housekeeping] Housekeeping complete."
}

# _housekeeping_prune_git_tags <evolve_root> <tag_retention_days>
# Iterates evolve-* tags, extracts date from tag name, deletes tags older than retention.
_housekeeping_prune_git_tags() {
    local evolve_root="$1"
    local tag_retention_days="$2"
    local cutoff_epoch
    local tag tag_date tag_epoch

    cutoff_epoch="$(date -d "-${tag_retention_days} days" +%s 2>/dev/null)" || {
        echo "[housekeeping] Could not compute tag cutoff date, skipping tag pruning" >&2
        return 0
    }

    while IFS= read -r tag; do
        # Extract date portion from tag name: evolve-YYYY-MM-DD[-suffix]
        tag_date="$(printf '%s' "$tag" | grep -oP '(?<=evolve-)\d{4}-\d{2}-\d{2}')" || true

        if [[ -z "$tag_date" ]]; then
            continue
        fi

        tag_epoch="$(date -d "$tag_date" +%s 2>/dev/null)" || continue

        if (( tag_epoch < cutoff_epoch )); then
            echo "[housekeeping] Deleting old tag: $tag (date: $tag_date)"
            git -C "$evolve_root" tag -d "$tag" || true
        fi
    done < <(git -C "$evolve_root" tag -l 'evolve-*' 2>/dev/null || true)
}

# _housekeeping_git_snapshot <evolve_root>
# Stages all changes, commits if any exist, then tags as evolve-YYYY-MM-DD-pre.
_housekeeping_git_snapshot() {
    local evolve_root="$1"
    local today tag_name

    today="$(date +%Y-%m-%d)"
    tag_name="evolve-${today}-pre"

    git -C "$evolve_root" add -A || true

    # Only commit if there are staged changes
    if ! git -C "$evolve_root" diff --cached --quiet 2>/dev/null; then
        git -C "$evolve_root" commit -m "chore: pre-pipeline snapshot ${today}" || true
    else
        echo "[housekeeping] No changes to commit for snapshot."
    fi

    # Tag (force-update if tag already exists for today)
    git -C "$evolve_root" tag -f "$tag_name" || true
    echo "[housekeeping] Tagged snapshot as: $tag_name"
}
