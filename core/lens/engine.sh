#!/usr/bin/env bash
# core/lens/engine.sh — Lens engine for evolve-ai
# The perceptual layer: concern-based intelligence gathering.
# Reads lens.concerns from genome.yaml, manages per-concern inboxes,
# runs feeds, and gathers pending items for digest.

SCRIPT_DIR_LENS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source feed runner (which sources adapters)
source "$SCRIPT_DIR_LENS/feed-runner.sh"

# ---------------------------------------------------------------------------
# lens_run <evolve_root> <genome_yaml>
# Main entry point. Reads lens.concerns from genome.yaml, for each concern:
#   1. Ensure per-concern inbox directories exist
#   2. Run each feed in the concern (respecting schedule)
#   3. Log what was gathered
# ---------------------------------------------------------------------------
lens_run() {
    local evolve_root="$1"
    local genome_yaml="$2"

    if [[ ! -f "$genome_yaml" ]]; then
        echo "[lens] Genome file not found: $genome_yaml" >&2
        return 1
    fi

    echo "[lens] Running lens for $(basename "$(dirname "$genome_yaml")")"

    # Ensure base inbox structure exists
    mkdir -p "$evolve_root/inbox/sources"

    # Create per-concern directories for all concerns
    local concerns
    concerns="$(lens_list_concerns "$genome_yaml")"
    if [[ -n "$concerns" ]]; then
        while IFS= read -r concern; do
            mkdir -p "$evolve_root/inbox/$concern/pending"
            mkdir -p "$evolve_root/inbox/$concern/processed"
        done <<< "$concerns"
    fi

    # Run all feeds via the feed runner
    run_feeds "$evolve_root" "$genome_yaml"

    echo "[lens] Lens run complete"
}

# ---------------------------------------------------------------------------
# lens_list_concerns <genome_yaml>
# Parses and lists all concern names from a genome.yaml, one per line.
# ---------------------------------------------------------------------------
lens_list_concerns() {
    local genome_yaml="$1"

    if [[ ! -f "$genome_yaml" ]]; then
        return 1
    fi

    local in_lens=0
    local in_concerns=0

    while IFS= read -r line; do
        if echo "$line" | grep -qE '^lens:'; then
            in_lens=1
            continue
        fi

        if [[ "$in_lens" -eq 1 ]] && echo "$line" | grep -qE '^[a-z]'; then
            in_lens=0
            continue
        fi

        if [[ "$in_lens" -eq 0 ]]; then
            continue
        fi

        if echo "$line" | grep -qE '^\s+concerns:'; then
            in_concerns=1
            continue
        fi

        if [[ "$in_concerns" -eq 1 ]]; then
            if echo "$line" | grep -qE '^\s{4}-\s*name:'; then
                echo "$line" | sed 's/.*name:[[:space:]]*//' | tr -d '"'
            fi
        fi
    done < "$genome_yaml"
}

# ---------------------------------------------------------------------------
# lens_get_concern_config <genome_yaml> <concern_name>
# Returns the full config for a specific concern as key=value output.
# Output: description, accepts_inbox, accepts_agents, research_on_arrival
# ---------------------------------------------------------------------------
lens_get_concern_config() {
    local genome_yaml="$1"
    local target_concern="$2"

    if [[ ! -f "$genome_yaml" ]]; then
        return 1
    fi

    local in_lens=0
    local in_concerns=0
    local in_target=0
    local description="" accepts_inbox="true" accepts_agents="false" research_on_arrival="false"

    while IFS= read -r line; do
        if echo "$line" | grep -qE '^lens:'; then
            in_lens=1
            continue
        fi

        if [[ "$in_lens" -eq 1 ]] && echo "$line" | grep -qE '^[a-z]'; then
            break
        fi

        if [[ "$in_lens" -eq 0 ]]; then
            continue
        fi

        if echo "$line" | grep -qE '^\s+concerns:'; then
            in_concerns=1
            continue
        fi

        if [[ "$in_concerns" -eq 0 ]]; then
            continue
        fi

        # Detect concern start
        if echo "$line" | grep -qE '^\s{4}-\s*name:'; then
            local cname
            cname="$(echo "$line" | sed 's/.*name:[[:space:]]*//' | tr -d '"')"
            if [[ "$cname" == "$target_concern" ]]; then
                in_target=1
            elif [[ "$in_target" -eq 1 ]]; then
                # We hit the next concern; stop
                break
            fi
            continue
        fi

        if [[ "$in_target" -eq 1 ]]; then
            if echo "$line" | grep -qE '^\s+description:'; then
                description="$(echo "$line" | sed 's/.*description:[[:space:]]*//' | tr -d '"')"
            elif echo "$line" | grep -qE '^\s+accepts_inbox:'; then
                accepts_inbox="$(echo "$line" | sed 's/.*accepts_inbox:[[:space:]]*//' | tr -d '"')"
            elif echo "$line" | grep -qE '^\s+accepts_agents:'; then
                accepts_agents="$(echo "$line" | sed 's/.*accepts_agents:[[:space:]]*//' | tr -d '"')"
            elif echo "$line" | grep -qE '^\s+research_on_arrival:'; then
                research_on_arrival="$(echo "$line" | sed 's/.*research_on_arrival:[[:space:]]*//' | tr -d '"')"
            fi
        fi
    done < "$genome_yaml"

    if [[ "$in_target" -eq 0 ]]; then
        echo "[lens] Concern '$target_concern' not found in $genome_yaml" >&2
        return 1
    fi

    echo "description=$description"
    echo "accepts_inbox=$accepts_inbox"
    echo "accepts_agents=$accepts_agents"
    echo "research_on_arrival=$research_on_arrival"
}

# ---------------------------------------------------------------------------
# lens_check_new_items <evolve_root> <genome_yaml>
# Checks all concern inboxes for new (unprocessed) items.
# Returns 0 if any new items exist, 1 if none.
# Outputs summary: concern name, count of new items.
# ---------------------------------------------------------------------------
lens_check_new_items() {
    local evolve_root="$1"
    local genome_yaml="$2"

    local concerns
    concerns="$(lens_list_concerns "$genome_yaml")"

    if [[ -z "$concerns" ]]; then
        echo "0"
        return 1
    fi

    local total_new=0

    while IFS= read -r concern; do
        local pending_dir="$evolve_root/inbox/$concern/pending"
        if [[ ! -d "$pending_dir" ]]; then
            continue
        fi

        local count=0
        for f in "$pending_dir"/*; do
            if [[ -f "$f" ]]; then
                local basename
                basename="$(basename "$f")"
                # Skip dotfiles
                if [[ "$basename" == .* ]]; then
                    continue
                fi
                (( count++ )) || true
            fi
        done

        if (( count > 0 )); then
            echo "$concern: $count new item(s)"
            total_new=$(( total_new + count ))
        fi
    done <<< "$concerns"

    if (( total_new > 0 )); then
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# lens_gather_all_pending <evolve_root> <genome_yaml> <workspace>
# Gathers all pending items from all concerns into a single workspace file
# (inbox-diff.txt) that digest can process. Each item is tagged with its
# concern name. This is the handoff to digest.
# ---------------------------------------------------------------------------
lens_gather_all_pending() {
    local evolve_root="$1"
    local genome_yaml="$2"
    local workspace="$3"

    mkdir -p "$workspace"

    local output_file="$workspace/inbox-diff.txt"
    : > "$output_file"

    local concerns
    concerns="$(lens_list_concerns "$genome_yaml")"

    if [[ -z "$concerns" ]]; then
        echo "[lens] No concerns defined — nothing to gather" >&2
        return 0
    fi

    local total_items=0

    while IFS= read -r concern; do
        local pending_dir="$evolve_root/inbox/$concern/pending"
        if [[ ! -d "$pending_dir" ]]; then
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

                echo "--- [concern: $concern] $basename ---" >> "$output_file"
                cat "$f" >> "$output_file"
                echo "" >> "$output_file"
                (( total_items++ )) || true
            fi
        done
    done <<< "$concerns"

    echo "[lens] Gathered $total_items item(s) from all concerns into $output_file"
}
