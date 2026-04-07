# Defect Remediation Design

**Date:** 2026-04-06
**Scope:** Fix all 21 confirmed defects from Codex code review
**Strategy:** Layer-by-layer, bottom-up — fix foundations before consumers

## Context

A comprehensive code review identified 21 defects across Critical, High, Medium, and Low severity tiers. All 21 were independently verified as real. The defects interact: the pipeline is currently a complete no-op (Critical #1-3 compound), which masks all other bugs. Fixing the pipeline will activate dormant issues, so all layers must be addressed.

## Defect Index

| # | Severity | Summary | Layer | Root File(s) |
|---|----------|---------|-------|---------------|
| 1 | Critical | Provider never loaded — phases are no-ops | 1 | `core/orchestrator.sh` |
| 2 | Critical | Wrong argument order in provider_invoke call | 1 | `core/orchestrator.sh` |
| 3 | Critical | Prompt directory points to nonexistent path | 1 | `core/orchestrator.sh` |
| 4 | Critical | Crash recovery `eval` on unsanitized JSON | 1 | `core/orchestrator.sh` |
| 5 | High | Directed mode genome lookup always empty | 2 | `core/orchestrator.sh`, `core/config.sh` |
| 6 | High | Housekeeping auto-commits entire worktree | 0 | `core/housekeeping.sh` |
| 7 | High | Lock is race-prone, unsafe in `/tmp` | 0 | `core/lock.sh` |
| 8 | High | Init offers stub/nonexistent providers | 2 | `core/init.sh`, `core/providers/interface.sh` |
| 9 | High | Notification config key mismatch (init vs engine) | 2 | `core/init.sh`, `core/notifications/engine.sh` |
| 10 | High | LLM judge config unreachable (parser nesting limit) | 2 | `core/scoring/engine.sh`, `core/config.sh` |
| 11 | High | LLM judge pipes file path through jq instead of reading file | 2 | `core/scoring/engine.sh` |
| 12 | High | Feed schedule advanced even after adapter failure | 4 | `core/lens/feed-runner.sh` |
| 13 | Medium | Resource limit keys missing `resources.` prefix | 2 | `core/resources.sh` |
| 14 | Medium | Malformed genome passes validation (presence-only check) | 2 | `core/genomes/validator.sh` |
| 15 | Medium | Resume-session JSON injection via heredocs | 3 | `core/resume/resume-runner.sh` |
| 16 | Medium | Directive YAML injection via unescaped user input | 3 | `core/directives/manager.sh` |
| 17 | Medium | Slack/Discord notification JSON injection | 3 | `core/notifications/slack.sh`, `core/notifications/discord.sh` |
| 18 | Medium | Custom genome sed injection (`$description` unescaped) | 3 | `core/init.sh` |
| 19 | Medium | Metrics dedup by `id` only, should be `id + run_date` | 4 | `core/memory/manager.sh` |
| 20 | Low | Inbox/lens adapters are byte-for-byte duplicates (316 lines) | 5 | `core/inbox/sources/*`, `core/lens/adapters/*` |
| 21 | Low | Notification tests cover schema init never produces | 5 | `tests/test_notifications.sh` |

## Layer 0 — Foundations

These are root causes that multiple downstream bugs depend on. All other layers are blocked on Layer 0.

### 0a. Replace YAML parser with `yq` (fixes #5, #10, #13)

**Problem:** The awk parser in `core/config.sh` only supports flat `section.key=value`. It skips list items, can't handle nesting deeper than 1 level, and has no array indexing. This is the root cause behind 4+ defects.

**Change:** Rewrite `load_config` in `core/config.sh` to use `yq` (Mike Farah's Go binary, v4) as the parsing backend.

The `yq` command to produce flat key-path output:
```bash
yq '.. | select(tag != "!!map" and tag != "!!seq") | (path | join(".")) + "=" + .' "$config_file"
```

This produces paths like:
- `targets.0.genome=infrastructure`
- `resources.min_free_ram_mb=1500`
- `scorers.llm_judge.enabled=true`
- `pipeline.phases.0=digest`

**Public API unchanged:** `config_get` and `config_get_default` remain the interface. Callers don't change (except where their key paths were wrong — those are fixed in Layer 2).

**Also replace:** The hand-rolled awk YAML parser in `core/scoring/engine.sh:470-541` (`_parse_scorer_list`). Replace with `yq` calls to extract scorer arrays as JSON directly:
```bash
yq -o=json '.scorers.'"$scorer_type" "$genome_yaml"
```

**Dependency:** `yq` must be installed. Add a check to `bin/evolve` startup and to `evolve init` that verifies `yq` is in PATH, with install instructions if missing. `yq` is a single static binary (~5MB), comparable to `jq` which is already required.

### 0b. Fix lock with `flock` (fixes #7)

**Problem:** `core/lock.sh` uses a check-then-write pattern (TOCTOU race) with predictable `/tmp` paths (symlink attack vector).

**Change:** Rewrite `acquire_lock` to use `flock` for atomic mutual exclusion.

```bash
EVOLVE_LOCK_FD=9

acquire_lock() {
    local lock_file="${1:-$EVOLVE_DEFAULT_LOCK}"
    exec 9>"$lock_file"
    if ! flock -n 9; then
        return 1
    fi
    # Write PID + timestamp for diagnostics (lock is already held via FD)
    echo "$$ $(date +%s)" >&9
    return 0
}

release_lock() {
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    rm -f "${1:-$EVOLVE_DEFAULT_LOCK}"
}
```

**Lock file location:** Move from `/tmp/evolve-ai.lock` to `$EVOLVE_ROOT/.evolve-lock`. Add `.evolve-lock` to `.gitignore`. This eliminates the `/tmp` symlink vector and scopes the lock to the project. Similarly update `core/meta/meta-agent.sh` to use `$EVOLVE_ROOT/.evolve-meta-lock`.

**Stale detection:** `lock_is_stale` still works — it reads PID/timestamp from the file. `flock` automatically releases on process death, so stale locks self-clear.

### 0c. Fix housekeeping git safety (fixes #6)

**Problem:** `_housekeeping_git_snapshot` runs `git add -A` which stages the entire worktree — including secrets, WIP, or unrelated files.

**Change:** `git add -A` already respects `.gitignore`. The fix is to ensure proper ignore rules exist:

1. In `evolve init`, generate a `.gitignore` that includes:
   ```
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
   ```

2. Before committing, warn if the staged diff is unusually large (>1000 lines) — this catches cases where the user dropped large files into the project dir:
   ```bash
   local staged_lines
   staged_lines="$(git -C "$evolve_root" diff --cached --stat | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
   if (( staged_lines > 1000 )); then
       echo "[housekeeping] Warning: snapshot includes $staged_lines changed lines — verify .gitignore" >&2
   fi
   ```

## Layer 1 — Provider Pipeline

Makes the core pipeline actually execute phases. Blocked on Layer 0 (config parser).

### 1a. Source provider interface (fixes #1)

**Problem:** `core/orchestrator.sh` never sources `core/providers/interface.sh`, so `provider_invoke` is never defined. Every phase hits the STUB fallback.

**Change:** Add to `core/orchestrator.sh` after the existing source block (line 11):
```bash
source "$SCRIPT_DIR_ORCH/providers/interface.sh"
```

### 1b. Fix argument order (fixes #2)

**Problem:** `run_phase` on line 92 calls `provider_invoke "$phase_name" "$prompt_file" "$workspace" "$max_turns"` but the interface expects `provider_invoke <prompt_file> <max_turns> <workspace> <phase_name>`.

**Change:** Line 92 becomes:
```bash
provider_invoke "$prompt_file" "$max_turns" "$workspace" "$phase_name"
```

### 1c. Fix prompt directory (fixes #3)

**Problem:** Line 237 points to `$evolve_root/prompts` which doesn't exist. Actual prompts are in `core/phases/`.

**Change:** Line 237 becomes:
```bash
local prompts_dir="$evolve_root/core/phases"
```

### 1d. Replace `eval` with structured rollback operations (fixes #4)

**Problem:** `execute_rollback_manifest` runs `eval "$undo_cmd"` on arbitrary strings from `rollback-manifest.json`. This is an arbitrary code execution vector.

**Change:** Replace the free-form `undo` string with a structured operation format in the manifest:

**New manifest schema:**
```json
{
  "changes": [
    {
      "description": "Reverted src/foo.sh",
      "undo": {
        "op": "git_checkout",
        "ref": "HEAD~1",
        "path": "src/foo.sh"
      }
    },
    {
      "description": "Removed new file",
      "undo": {
        "op": "rm",
        "path": "src/new-file.sh"
      }
    },
    {
      "description": "Restored backup",
      "undo": {
        "op": "cp",
        "src": "backups/config.bak",
        "dst": "config/evolve.yaml"
      }
    }
  ]
}
```

**Dispatcher (replaces the eval):**
```bash
local op
op="$(jq -r ".changes[$i].undo.op" "$manifest_file")"
case "$op" in
    git_checkout)
        local ref path
        ref="$(jq -r ".changes[$i].undo.ref" "$manifest_file")"
        path="$(jq -r ".changes[$i].undo.path" "$manifest_file")"
        git -C "$evolve_root" checkout "$ref" -- "$path"
        ;;
    rm)
        local path
        path="$(jq -r ".changes[$i].undo.path" "$manifest_file")"
        # Validate path is relative and inside evolve_root
        [[ "$path" != /* ]] && rm -f "$evolve_root/$path"
        ;;
    cp)
        local src dst
        src="$(jq -r ".changes[$i].undo.src" "$manifest_file")"
        dst="$(jq -r ".changes[$i].undo.dst" "$manifest_file")"
        [[ "$src" != /* && "$dst" != /* ]] && cp "$evolve_root/$src" "$evolve_root/$dst"
        ;;
    *)
        echo "[orchestrator] Unknown rollback op: $op — skipping" >&2
        ;;
esac
```

**Path validation:** All paths are validated as relative (no leading `/`) and resolved under `$evolve_root` only. Absolute paths are rejected.

**Phase prompt updates:** The `implement` phase prompt (`core/phases/implement.md`) must be updated to document the new structured undo format so the LLM generates manifests in the correct schema.

## Layer 2 — Config Consumers

With `yq` in place and the pipeline wired, these fix callers that use wrong key paths or misparse provider output.

### 2a. Fix resource limit key lookups (fixes #13)

**File:** `core/resources.sh`

**Change:**
- Line 25: `"min_free_ram_mb"` -> `"resources.min_free_ram_mb"`
- Line 48: `"max_disk_usage_pct"` -> `"resources.max_disk_usage_pct"`

**Impact:** Currently masked because hardcoded defaults match config values. After this fix, user-customized resource thresholds will actually take effect.

### 2b. Fix notification config — add `*_env` resolution to engine (fixes #9)

**Problem:** `init.sh` writes `bot_token_env: "EVOLVE_TG_BOT_TOKEN"` but `engine.sh` only parses `bot_token:`.

**Design choice:** Keep the `*_env` pattern — it's better security (config never contains raw secrets). Fix the engine to support both formats.

**Change in `core/notifications/engine.sh`:** Add regex matches for `*_env` keys alongside existing ones:

```bash
# bot_token (direct value)
if [[ "$stripped" =~ ^bot_token:[[:space:]]*(.+) ]]; then
    current_param1="${BASH_REMATCH[1]}"
    # ... strip quotes ...
fi
# bot_token_env (env var reference — resolve it)
if [[ "$stripped" =~ ^bot_token_env:[[:space:]]*(.+) ]]; then
    local env_name="${BASH_REMATCH[1]}"
    # ... strip quotes ...
    current_param1="${!env_name}"  # Bash indirect expansion
fi
```

Same pattern for `chat_id_env` and `webhook_url_env`.

**Fallback order:** If both `bot_token` and `bot_token_env` are present, direct value wins. This provides backward compatibility.

### 2c. Fix LLM judge config path (fixes #10)

**File:** `core/scoring/engine.sh`

**Change:** With `yq`, genome YAML now produces `scorers.llm_judge.enabled` and `scorers.llm_judge.prompt`. Update:
- Line 97: `"llm_judge.enabled"` -> `"scorers.llm_judge.enabled"`
- Line 116: `"llm_judge.prompt"` -> `"scorers.llm_judge.prompt"`

**Also:** Replace `_parse_scorer_list` (lines 470-541) with:
```bash
_parse_scorer_list() {
    local genome_yaml="$1"
    local scorer_type="$2"
    yq -o=json ".scorers.$scorer_type // []" "$genome_yaml"
}
```

This eliminates the entire 70-line hand-rolled awk parser and the bug class it carries.

### 2d. Verify directed mode genome lookup (fixes #5)

**Change:** With `yq`, `config_get "targets.0.genome"` will now correctly return `"infrastructure"`. No code change needed in `core/orchestrator.sh:257` beyond the Layer 0a parser replacement. Add a test to verify.

### 2e. Fix LLM judge response parsing (fixes #11)

**File:** `core/scoring/engine.sh`

**Problem:** `$response` contains a file path (e.g., `/path/to/llm-judge-response.json`), but line 144 pipes that string through `jq` instead of reading the file.

**Change:**
```bash
# Before (broken):
score="$(printf '%s' "$response" | jq -r '.score // 0.5' 2>/dev/null)"
reasoning="$(printf '%s' "$response" | jq -r '.reasoning // "no reasoning"' 2>/dev/null)"

# After (fixed):
if [[ -f "$response" ]] && jq empty "$response" 2>/dev/null; then
    score="$(jq -r '.score // 0.5' "$response" 2>/dev/null)" || score="0.5"
    reasoning="$(jq -r '.reasoning // "no reasoning"' "$response" 2>/dev/null)" || reasoning="no reasoning"
else
    score="0.5"
    reasoning="response file missing or invalid JSON"
fi
```

The `jq empty` pre-check handles cases where Claude returns non-JSON (rate limiting, errors).

### 2f. Strengthen genome validation (fixes #14)

**File:** `core/genomes/validator.sh`

**Change:** Extend validation beyond field presence to check schema shape using `yq`:

- `scan_commands`: must be a sequence of strings. Validate with:
  ```bash
  yq '.scan_commands[] | tag' "$genome_yaml" | grep -v '!!str' && validation_error "scan_commands must be a list of strings"
  ```
- `health_checks`: each entry must have `name`, `command`, `expect` fields
- `scorers.heuristic`: each entry must have `name` and `command`

**Scope:** Validate structure, not content. We check types and required sub-fields, not whether commands are valid.

### 2g. Mark stub providers in init (fixes #8)

**File:** `core/init.sh`

**Change:** In `_select_provider` (lines 174-197):
- Mark `claude-api` and `openai` as "(not yet implemented)" in the menu
- If selected, print a warning and require confirmation: `"This provider is a stub and will fail at runtime. Continue anyway? (y/N)"`
- Remove `custom` from the menu entirely

**File:** `core/providers/interface.sh`

**Change:** Add explicit `custom)` case in the dispatch (line 34):
```bash
custom)
    echo "[provider] Custom provider not configured. See docs/creating-providers.md" >&2
    return 1
    ;;
```

## Layer 3 — Input Sanitization

All injection fixes. Independent of each other. Each introduces a `jq -n --arg` pattern to build JSON safely, or uses proper quoting for YAML.

### 3a. Fix JSON injection in resume-runner (fixes #15)

**File:** `core/resume/resume-runner.sh`

**Change:** Replace all three heredoc blocks (lines 136-145, 158-167, 180-189) with `jq` construction:

```bash
# Example for the "redirect" case (line 136-145):
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
```

Same pattern for expand (line 158) and modify (line 180) cases. `jq --arg` handles all escaping.

### 3b. Fix YAML injection in directives (fixes #16)

**File:** `core/directives/manager.sh`

**Change:** In `directive_create` (lines 40-58), properly quote all values using single-quote wrapping with escaped embedded single quotes:

```bash
_yaml_quote() {
    local val="$1"
    # Single-quote wrap: replace ' with '' (YAML escape for single quotes)
    val="${val//\'/\'\'}"
    printf "'%s'" "$val"
}
```

Then in the heredoc:
```yaml
target: $(_yaml_quote "$target")
rule: $(_yaml_quote "$rule")
```

### 3c. Fix JSON injection in Slack/Discord (fixes #17)

**Files:** `core/notifications/slack.sh`, `core/notifications/discord.sh`

**Change:** Use `jq` to build the payload:

```bash
# slack.sh
notify_slack() {
    local message="$1"
    local webhook_url="$2"
    [[ -z "$webhook_url" ]] && return 0
    local payload
    payload="$(jq -n --arg text "$message" '{"text": $text}')"
    curl -s -X POST "$webhook_url" \
        -H 'Content-Type: application/json' \
        -d "$payload" >/dev/null 2>&1 || true
}

# discord.sh — same pattern with {"content": $text}
```

### 3d. Fix sed injection in custom genome creation (fixes #18)

**File:** `core/init.sh`

**Change:** Replace `sed -i` on line 577 with `yq` (already available after Layer 0a):

```bash
yq -i ".description = \"$description\"" "$genome_dir/genome.yaml"
```

Or safer, to avoid shell quoting issues with `yq`:
```bash
yq -i ".description = strenv(DESC)" "$genome_dir/genome.yaml"
```
(with `DESC="$description" exported`)

## Layer 4 — Behavioral Bugs

### 4a. Fix feed schedule advancement on failure (fixes #12)

**File:** `core/lens/feed-runner.sh`

**Change:** Capture adapter exit code and only mark as run on success:

```bash
local adapter_rc=0
case "$type" in
    rss)
        source_rss_fetch "$name" "$url" "$output_dir" || adapter_rc=$?
        ;;
    command)
        source_command_run "$name" "$command" "$output_dir" || adapter_rc=$?
        ;;
    manual)
        source_manual_scan "$watch_dir" "$output_dir" || adapter_rc=$?
        ;;
    webhook)
        echo "[feed-runner] Webhook '$name' is a listener" >&2
        return 0
        ;;
    *)
        echo "[feed-runner] Unknown feed type '$type'" >&2
        return 1
        ;;
esac

if [[ $adapter_rc -eq 0 ]]; then
    source_mark_run "$evolve_root" "$name"
else
    echo "[feed-runner] Feed '$name' failed (rc=$adapter_rc) — will retry next run" >&2
fi
```

### 4b. Fix metrics dedup to use composite key (fixes #19)

**File:** `core/memory/manager.sh`

**Change:** Replace the grep-based id-only check (lines 205-207) with composite key matching. Since `metrics.jsonl` is JSONL (one JSON object per line), grep is sufficient:

```bash
# Extract run_date from the metric being appended
local run_date
run_date="$(printf '%s' "$metric_json" | jq -r '.run_date // ""')"

if [[ -n "$metric_id" && -n "$run_date" && -f "$metrics_file" ]]; then
    if grep "\"id\":\"${metric_id}\"" "$metrics_file" | grep -q "\"run_date\":\"${run_date}\"" 2>/dev/null; then
        return 0
    fi
elif [[ -n "$metric_id" && -f "$metrics_file" ]]; then
    # Fallback: if no run_date, dedup by id only (current behavior)
    if grep -q "\"id\":\"${metric_id}\"" "$metrics_file" 2>/dev/null; then
        return 0
    fi
fi
```

## Layer 5 — Cleanup

### 5a. Deduplicate inbox/lens adapters (fixes #20)

**Problem:** Four file pairs are byte-for-byte identical (316 lines total):
- `core/inbox/sources/command.sh` = `core/lens/adapters/command.sh`
- `core/inbox/sources/rss.sh` = `core/lens/adapters/rss.sh`
- `core/inbox/sources/manual.sh` = `core/lens/adapters/manual.sh`
- `core/inbox/sources/webhook.sh` = `core/lens/adapters/webhook.sh`

**Change:**
1. Create `core/adapters/` as the canonical location
2. Move `command.sh`, `rss.sh`, `manual.sh`, `webhook.sh` there
3. Replace both `core/inbox/sources/*.sh` and `core/lens/adapters/*.sh` with one-line source wrappers:
   ```bash
   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/command.sh"
   ```
4. Keep `_template.sh` files in their original locations (they're scaffolding, not runtime code)

### 5b. Fix notification test coverage (fixes #21)

**File:** `tests/test_notifications.sh`

**Change:** Add test cases that:
1. Test `bot_token_env`/`chat_id_env`/`webhook_url_env` resolution (after 2b adds support)
2. Test round-trip: generate config via init's format, load it via the engine, verify credentials resolve
3. Test that missing env vars produce clear errors rather than silent failures

## Dependencies Between Layers

```
Layer 0 (foundations)
  |
  +---> Layer 1 (provider pipeline) --- depends on 0a (parser)
  |
  +---> Layer 2 (config consumers) --- depends on 0a; items 2c-2e also depend on 1a-1c
  |
  +---> Layer 3 (input sanitization) --- independent, can run parallel with 1-2
  |
  +---> Layer 4 (behavioral bugs) --- independent, can run parallel with 1-3
  |
  +---> Layer 5 (cleanup) --- depends on 2b (notification fix) for test updates
```

Layers 3 and 4 have no dependencies on Layers 1-2 and can be implemented in parallel.

## Files Modified Per Layer

| Layer | Files Modified |
|-------|---------------|
| 0 | `core/config.sh`, `core/lock.sh`, `core/housekeeping.sh`, `core/meta/meta-agent.sh`, `core/init.sh` (.gitignore generation), `bin/evolve` (yq check) |
| 1 | `core/orchestrator.sh`, `core/phases/implement.md` (undo format docs) |
| 2 | `core/resources.sh`, `core/notifications/engine.sh`, `core/scoring/engine.sh`, `core/genomes/validator.sh`, `core/init.sh`, `core/providers/interface.sh` |
| 3 | `core/resume/resume-runner.sh`, `core/directives/manager.sh`, `core/notifications/slack.sh`, `core/notifications/discord.sh`, `core/init.sh` |
| 4 | `core/lens/feed-runner.sh`, `core/memory/manager.sh` |
| 5 | `core/adapters/` (new), `core/inbox/sources/*.sh`, `core/lens/adapters/*.sh`, `tests/test_notifications.sh` |

## New Dependencies

- `yq` v4 (Mike Farah's Go binary, ~5MB static binary). Install via `wget` or package manager. Already consistent with the project's dependency on `jq`.

## Testing Strategy

Each layer gets tested before moving to the next:

- **Layer 0:** Run existing `tests/test_config.sh` and `tests/test_lock.sh` — they should still pass with the new implementations. Add tests for list/nested parsing.
- **Layer 1:** Manual `evolve run` in a sandbox — verify phases actually execute (no more STUB messages). Verify prompt content is non-empty.
- **Layer 2:** Run `tests/test_scoring.sh`, `tests/test_genomes.sh`. Add directed-mode test. Verify resource limits respond to config changes.
- **Layer 3:** Add injection test cases: strings containing `"`, `\n`, `'`, `:`, `/`, `&` must not break JSON/YAML output.
- **Layer 4:** Run `tests/test_inbox.sh`. Verify failed RSS fetch doesn't advance schedule. Verify metrics with same id but different run_date are both kept.
- **Layer 5:** Verify inbox and lens still function after adapter consolidation. Run full `tests/test_notifications.sh` with new cases.
