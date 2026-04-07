#!/usr/bin/env bash
# core/lens/adapters/_template.sh — Template for custom feed adapters
#
# To create a custom feed adapter:
# 1. Copy this file to core/lens/adapters/my-adapter.sh
# 2. Implement the source_MYTYPE_fetch function
# 3. Reference it in your genome.yaml under lens.concerns[].feeds:
#      - type: "my-adapter"
#        schedule: "daily"
#        # ...additional config keys specific to your adapter
#
# Conventions:
# - Function name: source_{type}_fetch or source_{type}_run
# - Arguments: (name, ...adapter-specific-args, output_dir)
# - The output_dir is always the last argument (inbox/pending/)
# - Write files as: {name}-{YYYY-MM-DD}.md (or with index for multiple items)
# - Only write files when there is actual content
# - Log to stderr with [source:{type}] prefix
# - Return 0 on success, 1 on failure

# ---------------------------------------------------------------------------
# source_template_fetch <name> <output_dir>
# Replace 'template' with your adapter type name.
# ---------------------------------------------------------------------------
source_template_fetch() {
    local name="$1"
    local output_dir="$2"

    mkdir -p "$output_dir"

    local today
    today="$(date +%Y-%m-%d)"
    local iso_date
    iso_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # --- Your data-fetching logic here ---
    local content=""
    # content="$(your_fetch_command)"

    # Only write if content is non-empty
    if [[ -z "$content" ]]; then
        echo "[source:template] No content from '$name' — skipping" >&2
        return 0
    fi

    local out_file="$output_dir/${name}-${today}.md"
    cat > "$out_file" <<EOF
# ${name} — Template Output
Source: ${name} (template)
Date: ${iso_date}

${content}
EOF

    echo "[source:template] Wrote output from '$name' to $out_file"
}
