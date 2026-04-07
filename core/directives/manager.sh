#!/usr/bin/env bash
# core/directives/manager.sh — persistent directives system for evolve-ai

# ---------------------------------------------------------------------------
# _sanitize_target <target>
#
# Sanitizes a target string for use in filenames.
# Replaces / * and spaces with hyphens, collapses multiple hyphens.
# ---------------------------------------------------------------------------
_sanitize_target() {
    local target="$1"
    echo "$target" | sed 's|[/*. ]|-|g; s|--*|-|g; s|^-||; s|-$||'
}

# ---------------------------------------------------------------------------
# directive_create <directives_dir> <type> <target> <rule> <source> <expires>
#
# Creates a new directive YAML file.
# type: lock | priority | constraint | override
# expires: "null" for no expiry, or ISO date string (YYYY-MM-DD)
# ---------------------------------------------------------------------------
directive_create() {
    local directives_dir="$1"
    local type="$2"
    local target="$3"
    local rule="$4"
    local source="$5"
    local expires="$6"

    mkdir -p "$directives_dir"

    local sanitized
    sanitized="$(_sanitize_target "$target")"
    local filename="${type}-${sanitized}.yaml"
    local filepath="$directives_dir/$filename"

    local created
    created="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    # Write YAML — expires is either null (unquoted) or a quoted date
    if [[ "$expires" == "null" ]]; then
        cat > "$filepath" <<YAMLEOF
type: "${type}"
target: "${target}"
rule: "${rule}"
created: "${created}"
source: "${source}"
expires: null
YAMLEOF
    else
        cat > "$filepath" <<YAMLEOF
type: "${type}"
target: "${target}"
rule: "${rule}"
created: "${created}"
source: "${source}"
expires: "${expires}"
YAMLEOF
    fi

    printf '%s' "$filepath"
}

# ---------------------------------------------------------------------------
# _directive_read_field <file> <field>
#
# Reads a field value from a directive YAML file.
# Handles quoted and unquoted values.
# ---------------------------------------------------------------------------
_directive_read_field() {
    local file="$1"
    local field="$2"
    awk -F': ' -v f="$field" '
        $1 == f {
            val = $2
            for (i = 3; i <= NF; i++) val = val ": " $i
            # Strip surrounding quotes
            gsub(/^"/, "", val)
            gsub(/"$/, "", val)
            print val
            exit
        }
    ' "$file"
}

# ---------------------------------------------------------------------------
# _directive_is_expired <file>
#
# Returns 0 if the directive has expired, 1 if still active.
# ---------------------------------------------------------------------------
_directive_is_expired() {
    local file="$1"
    local expires
    expires="$(_directive_read_field "$file" "expires")"

    if [[ -z "$expires" || "$expires" == "null" ]]; then
        return 1  # No expiry — still active
    fi

    local today
    today="$(date +%Y-%m-%d)"
    # Compare date strings (works for YYYY-MM-DD format)
    if [[ "$expires" < "$today" ]]; then
        return 0  # Expired
    fi

    return 1  # Not expired yet
}

# ---------------------------------------------------------------------------
# directive_list <directives_dir>
#
# Lists all active (non-expired) directives in a formatted table.
# ---------------------------------------------------------------------------
directive_list() {
    local directives_dir="$1"

    if [[ ! -d "$directives_dir" ]]; then
        echo "No directives directory found."
        return 0
    fi

    local found=0
    printf "%-12s %-30s %-40s %s\n" "TYPE" "TARGET" "RULE" "EXPIRES"
    printf "%-12s %-30s %-40s %s\n" "----" "------" "----" "-------"

    local file
    for file in "$directives_dir"/*.yaml; do
        [[ ! -f "$file" ]] && continue

        # Skip expired
        if _directive_is_expired "$file"; then
            continue
        fi

        found=1
        local dtype dtarget drule dexpires
        dtype="$(_directive_read_field "$file" "type")"
        dtarget="$(_directive_read_field "$file" "target")"
        drule="$(_directive_read_field "$file" "rule")"
        dexpires="$(_directive_read_field "$file" "expires")"
        [[ "$dexpires" == "null" ]] && dexpires="never"

        printf "%-12s %-30s %-40s %s\n" "$dtype" "$dtarget" "$drule" "$dexpires"
    done

    if [[ "$found" -eq 0 ]]; then
        echo "No active directives."
    fi
}

# ---------------------------------------------------------------------------
# directive_check_lock <directives_dir> <file_path>
#
# Checks if a file path is locked by any lock directive.
# Returns 0 if locked, 1 if not.
# Uses glob matching — directive target "src/auth/*" matches "src/auth/login.sh".
# ---------------------------------------------------------------------------
directive_check_lock() {
    local directives_dir="$1"
    local file_path="$2"

    if [[ ! -d "$directives_dir" ]]; then
        return 1
    fi

    local file
    for file in "$directives_dir"/lock-*.yaml; do
        [[ ! -f "$file" ]] && continue

        # Skip expired
        if _directive_is_expired "$file"; then
            continue
        fi

        local target
        target="$(_directive_read_field "$file" "target")"

        # Glob match: unquoted $target allows glob expansion in [[ ]]
        # shellcheck disable=SC2053
        if [[ "$file_path" == $target ]]; then
            return 0  # Locked
        fi
    done

    return 1  # Not locked
}

# ---------------------------------------------------------------------------
# directive_check_priority <directives_dir> <category>
#
# Checks if a category/topic has a priority boost directive.
# Returns the boost value (from rule field, default +1) or empty if none.
# ---------------------------------------------------------------------------
directive_check_priority() {
    local directives_dir="$1"
    local category="$2"

    if [[ ! -d "$directives_dir" ]]; then
        return 0
    fi

    local file
    for file in "$directives_dir"/priority-*.yaml; do
        [[ ! -f "$file" ]] && continue

        # Skip expired
        if _directive_is_expired "$file"; then
            continue
        fi

        local target
        target="$(_directive_read_field "$file" "target")"

        if [[ "$target" == "$category" ]]; then
            local rule
            rule="$(_directive_read_field "$file" "rule")"
            # Extract numeric boost from rule, default to +1
            local boost
            boost="$(echo "$rule" | grep -oE '[+-]?[0-9]+' | head -1 || true)"
            if [[ -z "$boost" ]]; then
                boost="+1"
            fi
            echo "$boost"
            return 0
        fi
    done
}

# ---------------------------------------------------------------------------
# directive_check_override <directives_dir> <change_id>
#
# Checks if a specific change ID has an override directive.
# Returns the forced verdict (from rule field) or empty if none.
# ---------------------------------------------------------------------------
directive_check_override() {
    local directives_dir="$1"
    local change_id="$2"

    if [[ ! -d "$directives_dir" ]]; then
        return 0
    fi

    local file
    for file in "$directives_dir"/override-*.yaml; do
        [[ ! -f "$file" ]] && continue

        # Skip expired
        if _directive_is_expired "$file"; then
            continue
        fi

        local target
        target="$(_directive_read_field "$file" "target")"

        if [[ "$target" == "$change_id" ]]; then
            local rule
            rule="$(_directive_read_field "$file" "rule")"
            echo "$rule"
            return 0
        fi
    done
}

# ---------------------------------------------------------------------------
# directive_cleanup_expired <directives_dir>
#
# Removes directives where expires date has passed.
# Returns count of cleaned directives.
# ---------------------------------------------------------------------------
directive_cleanup_expired() {
    local directives_dir="$1"

    if [[ ! -d "$directives_dir" ]]; then
        echo "0"
        return 0
    fi

    local count=0
    local file
    for file in "$directives_dir"/*.yaml; do
        [[ ! -f "$file" ]] && continue

        if _directive_is_expired "$file"; then
            rm "$file"
            (( count++ )) || true
        fi
    done

    echo "$count"
}

# ---------------------------------------------------------------------------
# directive_get_constraints <directives_dir>
#
# Outputs all active constraint directives as a newline-separated list of rules.
# ---------------------------------------------------------------------------
directive_get_constraints() {
    local directives_dir="$1"

    if [[ ! -d "$directives_dir" ]]; then
        return 0
    fi

    local file
    for file in "$directives_dir"/constraint-*.yaml; do
        [[ ! -f "$file" ]] && continue

        # Skip expired
        if _directive_is_expired "$file"; then
            continue
        fi

        local rule
        rule="$(_directive_read_field "$file" "rule")"
        echo "$rule"
    done
}
