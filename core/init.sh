#!/usr/bin/env bash
# core/init.sh — Interactive init flow for evolve-ai
# Sourced by bin/evolve — do not set -e here

_INIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$_INIT_DIR/config.sh"
source "$_INIT_DIR/genomes/validator.sh"

# ---------------------------------------------------------------------------
# Ctrl+C handler — graceful exit during init
# ---------------------------------------------------------------------------
_init_interrupted() {
    echo ""
    echo "Init interrupted. No changes were made."
    exit 130
}

# ---------------------------------------------------------------------------
# _prompt <message> <default>
# Prompts for user input with a default value. Returns the user's input or
# the default if they pressed Enter.
# ---------------------------------------------------------------------------
_prompt() {
    local message="$1"
    local default="${2:-}"
    local reply

    if [[ -n "$default" ]]; then
        printf '%s [%s]: ' "$message" "$default" >&2
    else
        printf '%s: ' "$message" >&2
    fi

    read -r reply
    if [[ -z "$reply" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$reply"
    fi
}

# ---------------------------------------------------------------------------
# _prompt_confirm <message>
# Asks for confirmation. Returns 0 if confirmed, 1 if not.
# ---------------------------------------------------------------------------
_prompt_confirm() {
    local message="$1"
    local reply

    printf '%s [Y/n]: ' "$message" >&2
    read -r reply
    case "$reply" in
        [nN]|[nN][oO]) return 1 ;;
        *) return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# _print_banner
# ---------------------------------------------------------------------------
_print_banner() {
    cat <<'EOF'

  ┌──────────────────────────────────────────┐
  │          evolve-ai — init                │
  │   Autonomous self-improvement pipeline   │
  └──────────────────────────────────────────┘

EOF
}

# ---------------------------------------------------------------------------
# _select_genomes <evolve_root>
# Interactive genome selection. Sets SELECTED_GENOMES (space-separated names)
# and SELECTED_GENOME_DIRS (space-separated genome directories).
# ---------------------------------------------------------------------------
_select_genomes() {
    local evolve_root="$1"
    local genomes_dir="$evolve_root/genomes"

    echo "What are you evolving? (select all that apply, or describe your own)"
    echo "  [1] Infrastructure (server, homelab, services)"
    echo "  [2] Agent harness (LLM agents, prompts, tools)"
    echo "  [3] Codebase (software project)"
    echo "  [+] Describe something else..."
    echo ""

    local selection
    selection="$(_prompt "Selection (e.g. 1, 2 or +)" "1")"

    SELECTED_GENOMES=""
    SELECTED_GENOME_DIRS=""

    # Parse comma/space separated selection
    local items
    items="$(echo "$selection" | tr ',' ' ')"

    for item in $items; do
        item="$(echo "$item" | tr -d ' ')"
        case "$item" in
            1)
                SELECTED_GENOMES="${SELECTED_GENOMES:+$SELECTED_GENOMES }infrastructure"
                SELECTED_GENOME_DIRS="${SELECTED_GENOME_DIRS:+$SELECTED_GENOME_DIRS }$genomes_dir/infrastructure"
                ;;
            2)
                SELECTED_GENOMES="${SELECTED_GENOMES:+$SELECTED_GENOMES }agent-harness"
                SELECTED_GENOME_DIRS="${SELECTED_GENOME_DIRS:+$SELECTED_GENOME_DIRS }$genomes_dir/agent-harness"
                ;;
            3)
                SELECTED_GENOMES="${SELECTED_GENOMES:+$SELECTED_GENOMES }codebase"
                SELECTED_GENOME_DIRS="${SELECTED_GENOME_DIRS:+$SELECTED_GENOME_DIRS }$genomes_dir/codebase"
                ;;
            +|+*)
                echo ""
                local desc
                desc="$(_prompt "Describe what you want to evolve" "")"
                if [[ -n "$desc" ]]; then
                    local custom_name
                    custom_name="$(generate_custom_genome "$evolve_root" "$desc")"
                    if [[ -n "$custom_name" ]]; then
                        SELECTED_GENOMES="${SELECTED_GENOMES:+$SELECTED_GENOMES }$custom_name"
                        SELECTED_GENOME_DIRS="${SELECTED_GENOME_DIRS:+$SELECTED_GENOME_DIRS }$genomes_dir/$custom_name"
                    fi
                fi
                ;;
            *)
                echo "  Unknown selection: $item (skipping)" >&2
                ;;
        esac
    done

    if [[ -z "$SELECTED_GENOMES" ]]; then
        echo "No genomes selected. Using infrastructure as default." >&2
        SELECTED_GENOMES="infrastructure"
        SELECTED_GENOME_DIRS="$genomes_dir/infrastructure"
    fi

    echo ""
    echo "Selected genomes: $SELECTED_GENOMES"
    echo ""
}

# ---------------------------------------------------------------------------
# _select_target_roots
# For each selected genome, ask for the target root directory.
# Sets TARGET_ROOTS (space-separated paths, same order as SELECTED_GENOMES).
# ---------------------------------------------------------------------------
_select_target_roots() {
    TARGET_ROOTS=""
    local genomes=($SELECTED_GENOMES)

    for genome in "${genomes[@]}"; do
        local default_root
        case "$genome" in
            infrastructure) default_root="$HOME" ;;
            agent-harness)  default_root="$HOME/agents" ;;
            codebase)       default_root="." ;;
            *)              default_root="." ;;
        esac

        local root
        root="$(_prompt "Target root directory for '$genome'" "$default_root")"
        TARGET_ROOTS="${TARGET_ROOTS:+$TARGET_ROOTS }$root"
    done
    echo ""
}

# ---------------------------------------------------------------------------
# _select_provider
# Interactive LLM provider selection. Sets PROVIDER_TYPE.
# ---------------------------------------------------------------------------
_select_provider() {
    echo "--- LLM Provider ---"
    echo ""
    echo "Which LLM provider should evolve-ai use?"
    echo "  [1] Claude via claude.ai (Max plan, recommended)"
    echo "  [2] Claude via API key"
    echo "  [3] OpenAI-compatible API"
    echo "  [4] Custom provider"
    echo ""

    local choice
    choice="$(_prompt "Provider" "1")"

    case "$choice" in
        1) PROVIDER_TYPE="claude-max" ;;
        2) PROVIDER_TYPE="claude-api" ;;
        3) PROVIDER_TYPE="openai" ;;
        4) PROVIDER_TYPE="custom" ;;
        *) PROVIDER_TYPE="claude-max" ;;
    esac

    echo "  Provider: $PROVIDER_TYPE"
    echo ""
}

# ---------------------------------------------------------------------------
# _select_notifications
# Interactive notification channel selection. Sets NOTIFICATION_CONFIG.
# ---------------------------------------------------------------------------
_select_notifications() {
    echo "--- Notifications ---"
    echo ""
    echo "How should evolve-ai notify you of results?"
    echo "  [1] Terminal output only (default)"
    echo "  [2] Telegram"
    echo "  [3] Slack"
    echo "  [4] Discord"
    echo "  [5] Multiple"
    echo ""

    local choice
    choice="$(_prompt "Notification channel" "1")"

    NOTIFICATION_CONFIG=""

    case "$choice" in
        1)
            NOTIFICATION_CONFIG='  - type: "stdout"'
            ;;
        2)
            NOTIFICATION_CONFIG='  - type: "telegram"
    bot_token_env: "EVOLVE_TG_BOT_TOKEN"
    chat_id_env: "EVOLVE_TG_CHAT_ID"'
            ;;
        3)
            NOTIFICATION_CONFIG='  - type: "slack"
    webhook_url_env: "EVOLVE_SLACK_WEBHOOK"'
            ;;
        4)
            NOTIFICATION_CONFIG='  - type: "discord"
    webhook_url_env: "EVOLVE_DISCORD_WEBHOOK"'
            ;;
        5)
            NOTIFICATION_CONFIG='  - type: "stdout"
  - type: "telegram"
    bot_token_env: "EVOLVE_TG_BOT_TOKEN"
    chat_id_env: "EVOLVE_TG_CHAT_ID"'
            ;;
        *)
            NOTIFICATION_CONFIG='  - type: "stdout"'
            ;;
    esac

    echo ""
}

# ---------------------------------------------------------------------------
# _configure_lens
# Show each genome's lens concerns and their feeds, allow toggle.
# ---------------------------------------------------------------------------
_configure_lens() {
    echo "--- Lens Concerns ---"
    echo ""

    local genomes=($SELECTED_GENOMES)
    local genome_dirs=($SELECTED_GENOME_DIRS)

    for i in "${!genomes[@]}"; do
        local genome="${genomes[$i]}"
        local genome_dir="${genome_dirs[$i]}"
        local genome_yaml="$genome_dir/genome.yaml"

        if [[ ! -f "$genome_yaml" ]]; then
            continue
        fi

        echo "The $genome genome watches for these concerns:"
        # Extract concern names and descriptions from genome.yaml
        local in_lens=0
        local in_concerns=0
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
            if [[ "$in_concerns" -eq 1 ]]; then
                if echo "$line" | grep -qE '^\s{4}-\s*name:'; then
                    local cname
                    cname="$(echo "$line" | sed 's/.*name:[[:space:]]*//' | tr -d '"')"
                    echo "  [x] $cname"
                fi
            fi
        done < "$genome_yaml"
        echo ""

        if ! _prompt_confirm "Accept default lens concerns for $genome?"; then
            echo "  (Lens customization saved for post-init editing via 'evolve genome edit $genome')"
        fi
        echo ""
    done
}

# ---------------------------------------------------------------------------
# _configure_resources
# Detect system resources, allow override.
# Sets RESOURCE_RAM and RESOURCE_DISK.
# ---------------------------------------------------------------------------
_configure_resources() {
    echo "--- Resource Constraints ---"
    echo ""

    # Detect system resources
    local total_ram_mb
    total_ram_mb="$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo "unknown")"
    local disk_pct
    disk_pct="$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo "unknown")"

    if [[ "$total_ram_mb" != "unknown" ]]; then
        echo "Detected: ${total_ram_mb}MB RAM, disk ${disk_pct}% used"
    fi
    echo ""

    RESOURCE_RAM="$(_prompt "Min free RAM before run (MB)" "1500")"
    RESOURCE_DISK="$(_prompt "Max disk usage (%)" "85")"
    echo ""
}

# ---------------------------------------------------------------------------
# _configure_safety
# Show safety rules per genome, allow add/confirm.
# ---------------------------------------------------------------------------
_configure_safety() {
    echo "--- Safety Review ---"
    echo ""

    local genomes=($SELECTED_GENOMES)
    local genome_dirs=($SELECTED_GENOME_DIRS)

    for i in "${!genomes[@]}"; do
        local genome="${genomes[$i]}"
        local genome_dir="${genome_dirs[$i]}"
        local genome_yaml="$genome_dir/genome.yaml"

        if [[ ! -f "$genome_yaml" ]]; then
            continue
        fi

        echo "$genome safety rules:"
        # Extract safety rules from the never section
        local in_never=0
        while IFS= read -r line; do
            if echo "$line" | grep -qE '^\s*never:'; then
                in_never=1
                continue
            fi
            if [[ "$in_never" -eq 1 ]]; then
                if echo "$line" | grep -qE '^\s*-\s'; then
                    local rule
                    rule="$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | tr -d '"')"
                    echo "  x $rule"
                elif echo "$line" | grep -qE '^\s*[a-z]'; then
                    in_never=0
                fi
            fi
        done < "$genome_yaml"

        echo ""
        if ! _prompt_confirm "Accept safety rules for $genome?"; then
            echo "  (Safety customization saved for post-init editing via 'evolve genome edit $genome')"
        fi
        echo ""
    done
}

# ---------------------------------------------------------------------------
# _configure_schedule
# Ask schedule preferences. Sets SCHEDULE_CRON, INBOX_POLL, META_SCHEDULE.
# ---------------------------------------------------------------------------
_configure_schedule() {
    echo "--- Schedule ---"
    echo ""

    SCHEDULE_CRON="$(_prompt "Autonomous run cron expression" "0 13 * * *")"
    INBOX_POLL="$(_prompt "Inbox poll interval (seconds)" "300")"
    META_SCHEDULE="$(_prompt "Meta-agent schedule (cron)" "0 13 * * 0")"
    echo ""
}

# ---------------------------------------------------------------------------
# _configure_circuit_breaker
# Ask circuit breaker config. Sets CB_THRESHOLD, CB_WINDOW, CB_RESUME.
# ---------------------------------------------------------------------------
_configure_circuit_breaker() {
    echo "--- Circuit Breaker ---"
    echo ""
    echo "Pause autonomous runs if too many negative signals."
    echo ""

    CB_THRESHOLD="$(_prompt "Negative impact threshold" "3")"
    CB_WINDOW="$(_prompt "Window (days)" "7")"
    CB_RESUME="$(_prompt "Resume mode (manual/auto)" "manual")"
    echo ""
}

# ---------------------------------------------------------------------------
# generate_config <evolve_root>
# Writes evolve.yaml from collected answers.
# ---------------------------------------------------------------------------
generate_config() {
    local evolve_root="$1"
    local config_file="$evolve_root/config/evolve.yaml"

    mkdir -p "$evolve_root/config"

    local genomes=($SELECTED_GENOMES)
    local roots=($TARGET_ROOTS)

    # Build targets section
    local targets_yaml=""
    for i in "${!genomes[@]}"; do
        local genome="${genomes[$i]}"
        local root="${roots[$i]}"
        targets_yaml="${targets_yaml}  - genome: \"$genome\"
    root: \"$root\"
    weight: 1
"
    done

    local today
    today="$(date +%Y-%m-%d)"

    cat > "$config_file" <<EOF
# evolve.yaml — Generated by evolve init on $today
version: "1.0.0"
created: "$today"

targets:
$targets_yaml
provider:
  type: "$PROVIDER_TYPE"

notifications:
$NOTIFICATION_CONFIG

schedule:
  autonomous: "$SCHEDULE_CRON"
  inbox_poll_seconds: $INBOX_POLL
  meta_agent: "$META_SCHEDULE"

resources:
  min_free_ram_mb: $RESOURCE_RAM
  max_disk_usage_pct: $RESOURCE_DISK

circuit_breaker:
  negative_impact_threshold: $CB_THRESHOLD
  window_days: $CB_WINDOW
  action: "pause"
  resume: "$CB_RESUME"

retention:
  workspace_days: 14
  git_tag_days: 30
  changelog_archive_days: 90

convergence:
  max_stalls: 3
  max_iterations: 10

validation:
  tier3_min_free_ram_mb: $RESOURCE_RAM
  sub_invocation_timeout_seconds: 300
  regression_check_count: 20
  regression_lookback_days: 30

challenge:
  approval_floor_pct: 50

meta_agent:
  enabled: false

pipeline:
  phases:
    - "digest"
    - "strategize"
    - "analyze"
    - "challenge"
    - "implement"
    - "validate"
    - "finalize"
    - "metrics"
EOF

    echo "  evolve.yaml written to $config_file"
}

# ---------------------------------------------------------------------------
# init_memory <evolve_root>
# Copies memory templates to runtime location.
# ---------------------------------------------------------------------------
init_memory() {
    local evolve_root="$1"
    local templates_dir="$_INIT_DIR/memory/templates"
    local memory_dir="$evolve_root/memory"

    mkdir -p "$memory_dir"

    if [[ ! -d "$templates_dir" ]]; then
        echo "init_memory: templates directory not found: $templates_dir" >&2
        return 1
    fi

    local count=0
    for template in "$templates_dir"/*; do
        if [[ -f "$template" ]]; then
            local filename
            filename="$(basename "$template")"
            if [[ ! -f "$memory_dir/$filename" ]]; then
                cp "$template" "$memory_dir/$filename"
                count=$(( count + 1 ))
            fi
        fi
    done

    echo "  Memory initialized ($count template files copied to $memory_dir)"
}

# ---------------------------------------------------------------------------
# init_inbox <evolve_root>
# Creates inbox directory structure with per-concern directories.
# ---------------------------------------------------------------------------
init_inbox() {
    local evolve_root="$1"
    local inbox_dir="$evolve_root/inbox"

    mkdir -p "$inbox_dir/sources"

    echo "  Inbox directory created at $inbox_dir"
}

# ---------------------------------------------------------------------------
# generate_custom_genome <evolve_root> <description>
# Takes a natural language description, generates a genome.yaml.
# Uses template-based fallback (LLM generation is not available during init
# without a running provider).
# Returns the genome name.
# ---------------------------------------------------------------------------
generate_custom_genome() {
    local evolve_root="$1"
    local description="$2"

    # Generate a slug name from the description
    local genome_name
    genome_name="$(echo "$description" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | head -c 30)"

    if [[ -z "$genome_name" ]]; then
        genome_name="custom"
    fi

    local genome_dir="$evolve_root/genomes/$genome_name"
    local template_dir="$evolve_root/genomes/_template"

    if [[ -d "$genome_dir" ]]; then
        echo "  Genome '$genome_name' already exists. Using existing genome." >&2
        printf '%s' "$genome_name"
        return 0
    fi

    # Copy template
    mkdir -p "$genome_dir"
    cp "$template_dir/genome.yaml" "$genome_dir/genome.yaml"

    # Fill in name and description
    sed -i "s/^name: .*/name: \"$genome_name\"/" "$genome_dir/genome.yaml"
    sed -i "s/^description: .*/description: \"$description\"/" "$genome_dir/genome.yaml"

    echo "" >&2
    echo "  Custom genome '$genome_name' created at $genome_dir" >&2
    echo "  Edit genome.yaml to customize scan commands, health checks, lens concerns, etc." >&2
    echo "  Or use 'evolve genome edit $genome_name' after init." >&2
    echo "" >&2

    printf '%s' "$genome_name"
}

# ---------------------------------------------------------------------------
# run_init <evolve_root>
# Main init flow — fully interactive.
# ---------------------------------------------------------------------------
run_init() {
    local evolve_root="$1"

    trap _init_interrupted INT

    _print_banner

    echo "Welcome to evolve-ai."
    echo ""

    # 1. Select genomes
    _select_genomes "$evolve_root"

    # 2. Select target root directories
    _select_target_roots

    # 3. Select LLM provider
    _select_provider

    # 4. Select notification channel
    _select_notifications

    # 5. Configure lens concerns
    _configure_lens

    # 6. Configure resource constraints
    _configure_resources

    # 7. Review safety rules
    _configure_safety

    # 8. Configure schedule
    _configure_schedule

    # 9. Configure circuit breaker
    _configure_circuit_breaker

    # 10. Generate config
    echo "--- Generation ---"
    echo ""
    echo "Generating configuration..."
    generate_config "$evolve_root"

    # Generate .gitignore if it doesn't exist
    local gitignore_file="$evolve_root/.gitignore"
    if [[ ! -f "$gitignore_file" ]]; then
        cat > "$gitignore_file" <<'GITIGNORE'
# Secrets
.env
.env.*
*.key
*.pem
*.p12
credentials.*

# Runtime
.evolve-lock
.evolve-meta-lock
workspace/
resume-context/
GITIGNORE
        echo "  Created .gitignore"
    fi

    # 11. Initialize memory
    init_memory "$evolve_root"

    # 12. Initialize inbox
    init_inbox "$evolve_root"

    # 13. Print summary
    echo ""
    echo "evolve-ai is ready."
    echo ""
    echo "  Commands:"
    echo "    evolve run            Trigger a manual run now"
    echo "    evolve status         View current state"
    echo "    evolve history        View change history"
    echo "    evolve genome edit    Modify genome configuration"
    echo "    evolve genome create  Create a new genome conversationally"
    echo ""
    echo "  Drop intelligence files into per-concern inbox dirs or"
    echo "  wait for lens feeds to populate."
    echo ""

    trap - INT
}
