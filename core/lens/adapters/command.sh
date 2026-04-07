#!/usr/bin/env bash
# core/lens/adapters/command.sh — Local command adapter for evolve-ai
# Runs a shell command and drops the output into inbox/pending/.

# ---------------------------------------------------------------------------
# source_command_run <name> <command> <output_dir>
# Runs a shell command, captures output, writes to output_dir as
# {name}-{date}.md. Only writes a file if the command produces non-empty output.
# ---------------------------------------------------------------------------
source_command_run() {
    local name="$1"
    local command="$2"
    local output_dir="$3"

    mkdir -p "$output_dir"

    local today
    today="$(date +%Y-%m-%d)"
    local iso_date
    iso_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Run command and capture output
    local output
    output="$(eval "$command" 2>&1)" || true

    # Only write if output is non-empty
    if [[ -z "$output" ]]; then
        echo "[source:command] Command '$name' produced no output — skipping" >&2
        return 0
    fi

    local out_file="$output_dir/${name}-${today}.md"
    cat > "$out_file" <<EOF
# ${name} — Command Output
Source: ${name} (command)
Command: ${command}
Date: ${iso_date}

${output}
EOF

    echo "[source:command] Wrote output from '$name' to $out_file"
}
