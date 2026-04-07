#!/usr/bin/env bash
# core/resources.sh — RAM and disk resource gates for evolve-ai

# shellcheck source=core/config.sh
RESOURCES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$RESOURCES_DIR/config.sh"

# get_free_ram_mb
# Outputs the current available (free + cache) RAM in megabytes.
get_free_ram_mb() {
    free -m | awk '/^Mem:/ {print $7}'
}

# get_disk_usage_pct
# Outputs the current disk usage percentage for / (integer, no % sign).
get_disk_usage_pct() {
    df / --output=pcent | tail -1 | tr -d ' %'
}

# check_ram_gate
# Reads min_free_ram_mb from config (default 1500).
# Returns 0 if free RAM is at or above threshold, 1 if below.
check_ram_gate() {
    local threshold
    threshold="$(config_get_default "min_free_ram_mb" "1500")"

    local free_mb
    free_mb="$(get_free_ram_mb)"

    if [[ -z "$free_mb" ]]; then
        echo "check_ram_gate: could not read free RAM" >&2
        return 1
    fi

    if (( free_mb < threshold )); then
        echo "check_ram_gate: free RAM ${free_mb}MB is below threshold ${threshold}MB" >&2
        return 1
    fi

    return 0
}

# check_disk_gate
# Reads max_disk_usage_pct from config (default 85).
# Returns 0 if disk usage is at or below threshold, 1 if above.
check_disk_gate() {
    local threshold
    threshold="$(config_get_default "max_disk_usage_pct" "85")"

    local usage_pct
    usage_pct="$(get_disk_usage_pct)"

    if [[ -z "$usage_pct" ]]; then
        echo "check_disk_gate: could not read disk usage" >&2
        return 1
    fi

    if (( usage_pct > threshold )); then
        echo "check_disk_gate: disk usage ${usage_pct}% exceeds threshold ${threshold}%" >&2
        return 1
    fi

    return 0
}

# check_all_gates
# Runs both RAM and disk gates.
# Returns 1 if either gate fails, 0 if both pass.
check_all_gates() {
    local status=0

    check_ram_gate  || status=1
    check_disk_gate || status=1

    return "$status"
}
