# Defect Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all 21 verified defects across 6 dependency layers, making the evolve-ai pipeline functional and secure.

**Architecture:** Bottom-up layer approach — fix foundations (parser, lock, housekeeping) first, then provider pipeline wiring, config consumers, input sanitization, behavioral bugs, and cleanup. Each layer is tested before the next begins.

**Tech Stack:** Bash, `yq` v4 (Mike Farah Go binary), `jq`, `flock`, existing test framework in `tests/helpers.sh`

**Spec:** `docs/superpowers/specs/2026-04-06-defect-remediation-design.md`

---

### Task 1: Install `yq` and add dependency check

**Files:**
- Modify: `bin/evolve:1-10`
- Test: manual verification

- [ ] **Step 1: Install yq v4**

```bash
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq
```

- [ ] **Step 2: Verify installation**

Run: `yq --version`
Expected: `yq (https://github.com/mikefarah/yq/) version v4.x.x`

- [ ] **Step 3: Test yq with the project config**

Run: `yq '.. | select(tag != "!!map" and tag != "!!seq") | (path | join(".")) + "=" + .' config/evolve.yaml | head -20`
Expected: Lines like `version=1.0.0`, `targets.0.genome=infrastructure`, `resources.min_free_ram_mb=1500`

- [ ] **Step 4: Add dependency check to bin/evolve**

In `bin/evolve`, add after line 6 (`EVOLVE_ROOT=...`):

```bash
# Check required dependencies
for cmd in jq yq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "evolve-ai: required command '$cmd' not found in PATH" >&2
        echo "  Install yq: https://github.com/mikefarah/yq#install" >&2
        echo "  Install jq: apt install jq" >&2
        exit 1
    fi
done
```

- [ ] **Step 5: Run bin/evolve help to verify it still works**

Run: `bash bin/evolve help`
Expected: Usage text prints normally, no errors

- [ ] **Step 6: Commit**

```bash
git add bin/evolve
git commit -m "feat: add yq dependency check to CLI entry point"
```

---

### Task 2: Rewrite YAML parser with `yq` backend

**Files:**
- Modify: `core/config.sh`
- Modify: `config/evolve.yaml.template` (no change, used by tests)
- Test: `tests/test_config.sh`

- [ ] **Step 1: Write failing test for list/nested parsing**

Append to `tests/test_config.sh`, before the "Run all tests" section:

```bash
# ---------------------------------------------------------------------------
# test_load_config_list_items
# ---------------------------------------------------------------------------
test_load_config_list_items() {
    echo "test_load_config_list_items"
    setup_test_env

    local yaml="$TEST_TMPDIR/evolve.yaml"
    cp "$PROJECT_ROOT/config/evolve.yaml.template" "$yaml"

    load_config "$yaml"

    assert_eq "infrastructure" "$(config_get targets.0.genome)" "targets.0.genome"
    assert_eq "."              "$(config_get targets.0.root)"   "targets.0.root"
    assert_eq "1"              "$(config_get targets.0.weight)" "targets.0.weight"
    assert_eq "digest"         "$(config_get pipeline.phases.0)" "pipeline.phases.0"
    assert_eq "metrics"        "$(config_get pipeline.phases.7)" "pipeline.phases.7"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_load_config_deep_nesting
# ---------------------------------------------------------------------------
test_load_config_deep_nesting() {
    echo "test_load_config_deep_nesting"
    setup_test_env

    local yaml="$TEST_TMPDIR/genome.yaml"
    cat > "$yaml" <<'YAML'
name: "test-genome"
scorers:
  llm_judge:
    enabled: true
    prompt: "Rate this change"
  heuristic:
    - name: "uptime"
      weight: 2
YAML

    load_config "$yaml"

    assert_eq "test-genome" "$(config_get name)"                        "name"
    assert_eq "true"        "$(config_get scorers.llm_judge.enabled)"   "scorers.llm_judge.enabled"
    assert_eq "Rate this change" "$(config_get scorers.llm_judge.prompt)" "scorers.llm_judge.prompt"
    assert_eq "uptime"      "$(config_get scorers.heuristic.0.name)"    "scorers.heuristic.0.name"
    assert_eq "2"           "$(config_get scorers.heuristic.0.weight)"  "scorers.heuristic.0.weight"

    teardown_test_env
}
```

Also add these to the "Run all tests" section:
```bash
test_load_config_list_items
test_load_config_deep_nesting
```

- [ ] **Step 2: Run tests to verify new tests fail**

Run: `bash tests/test_config.sh`
Expected: `test_load_config_list_items` and `test_load_config_deep_nesting` FAIL (targets.0.genome returns empty, scorers.llm_judge.enabled returns empty). Existing tests should still pass.

- [ ] **Step 3: Rewrite load_config in core/config.sh**

Replace the entire `load_config` function body (lines 11-93) with:

```bash
load_config() {
    local config_file="$1"

    if [[ -z "$config_file" ]]; then
        echo "load_config: no config file specified" >&2
        return 1
    fi

    if [[ ! -f "$config_file" ]]; then
        echo "load_config: file not found: $config_file" >&2
        return 1
    fi

    # Use yq to flatten YAML into key.path=value pairs
    # Select only scalar (leaf) nodes, build dotted path, append =value
    _CONFIG_CACHE="$(yq '
        .. | select(tag != "!!map" and tag != "!!seq") |
        (path | join(".")) + "=" + (. | tostring)
    ' "$config_file")"

    return 0
}
```

Leave `config_get` and `config_get_default` unchanged — they work on the `key=value` format which `yq` now produces.

- [ ] **Step 4: Run all config tests**

Run: `bash tests/test_config.sh`
Expected: ALL tests pass, including the new list/nesting tests.

- [ ] **Step 5: Verify with actual project config**

Run: `source core/config.sh && load_config config/evolve.yaml && config_get targets.0.genome`
Expected: `infrastructure`

Run: `config_get resources.min_free_ram_mb`
Expected: `1500`

- [ ] **Step 6: Commit**

```bash
git add core/config.sh tests/test_config.sh
git commit -m "feat: replace awk YAML parser with yq backend

Supports lists, deep nesting, and array indexing. Public API
(config_get, config_get_default) unchanged."
```

---

### Task 3: Rewrite lock with `flock`

**Files:**
- Modify: `core/lock.sh`
- Modify: `core/meta/meta-agent.sh:18`
- Test: `tests/test_lock.sh`

- [ ] **Step 1: Rewrite core/lock.sh**

Replace the entire file content with:

```bash
#!/usr/bin/env bash
# core/lock.sh — global lock management with flock-based atomic locking

EVOLVE_DEFAULT_LOCK="${EVOLVE_ROOT:-.}/.evolve-lock"
EVOLVE_LOCK_FD=9

# acquire_lock [lock_file]
# Uses flock for atomic lock acquisition. Writes PID + timestamp for diagnostics.
# Returns 1 if locked by another process, 0 on success.
acquire_lock() {
    local lock_file="${1:-$EVOLVE_DEFAULT_LOCK}"

    # Open FD for locking (create file if needed)
    eval "exec ${EVOLVE_LOCK_FD}>\"$lock_file\""

    if ! flock -n "$EVOLVE_LOCK_FD"; then
        return 1
    fi

    # Write PID + timestamp for diagnostics
    echo "$$ $(date +%s)" >&${EVOLVE_LOCK_FD}

    return 0
}

# release_lock [lock_file]
# Releases the flock and removes the lock file.
release_lock() {
    local lock_file="${1:-$EVOLVE_DEFAULT_LOCK}"
    flock -u "$EVOLVE_LOCK_FD" 2>/dev/null || true
    eval "exec ${EVOLVE_LOCK_FD}>&-" 2>/dev/null || true
    rm -f "$lock_file"
}

# is_locked [lock_file]
# Returns 0 if locked by a live process, 1 otherwise.
# Attempts a non-blocking flock to test; releases immediately if acquired.
is_locked() {
    local lock_file="${1:-$EVOLVE_DEFAULT_LOCK}"

    if [[ ! -f "$lock_file" ]]; then
        return 1
    fi

    # Try to acquire on a different FD to test
    local test_result
    (
        exec 8>"$lock_file"
        flock -n 8 && exit 0 || exit 1
    )
    test_result=$?

    if [[ $test_result -eq 0 ]]; then
        # We could acquire it, so it's NOT locked
        return 1
    else
        return 0
    fi
}

# lock_owner_pid [lock_file]
# Outputs the PID stored in the lock file.
lock_owner_pid() {
    local lock_file="${1:-$EVOLVE_DEFAULT_LOCK}"
    awk '{print $1}' "$lock_file" 2>/dev/null
}

# lock_is_stale [lock_file] [max_age_seconds]
# Returns 0 (true) if the lock file exists and its timestamp is older than max_age.
# Returns 1 (false) if the lock is fresh, missing, or has no timestamp.
lock_is_stale() {
    local lock_file="$1"
    local max_age="${2:-7200}"

    [ ! -f "$lock_file" ] && return 1

    local lock_ts
    lock_ts=$(awk '{print $2}' "$lock_file" 2>/dev/null || echo "")

    # No timestamp — can't determine staleness by age
    [ -z "$lock_ts" ] && return 1

    local now age
    now=$(date +%s)
    age=$((now - lock_ts))

    [ "$age" -gt "$max_age" ]
}
```

- [ ] **Step 2: Update meta-agent lock path**

In `core/meta/meta-agent.sh`, change line 18:

```bash
# Before:
EVOLVE_META_LOCK="/tmp/evolve-ai-meta.lock"

# After:
EVOLVE_META_LOCK="${EVOLVE_ROOT:-.}/.evolve-meta-lock"
```

- [ ] **Step 3: Update lock tests for flock behavior**

The existing tests in `tests/test_lock.sh` test PID-based behavior. The `test_lock_blocks_second_acquire` test needs adjustment because `flock` on the same FD in the same process is a no-op (the process already holds it). Replace that test:

```bash
test_lock_blocks_second_acquire() {
    echo "test_lock_blocks_second_acquire"
    setup_test_env

    local lock_file="$TEST_TMPDIR/test.lock"

    acquire_lock "$lock_file"

    # Second acquire from a SUBSHELL must fail because flock is held by parent
    local second_rc=0
    (
        # Open a new FD in the child — the parent holds the flock
        exec 9>"$lock_file"
        flock -n 9 && exit 0 || exit 1
    ) || second_rc=$?

    assert_eq "1" "$second_rc" "second acquire from subshell returns 1 while first is held"

    release_lock "$lock_file"
    teardown_test_env
}
```

Also update `test_stale_lock_cleanup` — with flock, a stale lock file (dead PID) is released automatically. The test should verify acquire succeeds over an orphaned lock file:

```bash
test_stale_lock_cleanup() {
    echo "test_stale_lock_cleanup"
    setup_test_env

    local lock_file="$TEST_TMPDIR/test.lock"

    # Write a stale lock file (no flock held — simulates dead process)
    echo "99999999 $(date +%s)" > "$lock_file"

    # acquire should succeed because no flock is actually held
    acquire_lock "$lock_file"
    local rc=$?
    assert_eq "0" "$rc" "acquire succeeds over stale lock"

    local stored_pid
    stored_pid="$(lock_owner_pid "$lock_file")"
    assert_eq "$$" "$stored_pid" "stale PID replaced with current PID"

    release_lock "$lock_file"
    teardown_test_env
}
```

- [ ] **Step 4: Run lock tests**

Run: `bash tests/test_lock.sh`
Expected: ALL tests pass

- [ ] **Step 5: Commit**

```bash
git add core/lock.sh core/meta/meta-agent.sh tests/test_lock.sh
git commit -m "feat: replace PID-based lock with flock for atomic locking

Eliminates TOCTOU race condition. Moves lock files from /tmp to
project directory to prevent symlink attacks."
```

---

### Task 4: Fix housekeeping git safety

**Files:**
- Modify: `core/housekeeping.sh:87-106`
- Modify: `core/init.sh` (add .gitignore generation)

- [ ] **Step 1: Change git add -A to git add -u in housekeeping**

In `core/housekeeping.sh`, change line 94:

```bash
# Before:
git -C "$evolve_root" add -A || true

# After:
git -C "$evolve_root" add -u || true
```

- [ ] **Step 2: Add large-diff warning after the git add**

In `core/housekeeping.sh`, add after line 94 (the `git add -u` line), before the commit check:

```bash
    # Warn if snapshot is unusually large
    local staged_lines
    staged_lines="$(git -C "$evolve_root" diff --cached --stat | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    if (( staged_lines > 1000 )); then
        echo "[housekeeping] Warning: snapshot includes $staged_lines changed lines — verify .gitignore" >&2
    fi
```

- [ ] **Step 3: Add .gitignore generation to init**

Find the section in `core/init.sh` where config files are generated (the `run_init` function). Add .gitignore generation. Search for where `evolve.yaml` is written and add after it:

```bash
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
```

- [ ] **Step 4: Add .gitignore to existing project if missing**

Run: `ls -la /home/dan/Projects/evolve-ai/.gitignore`

If it doesn't exist, create it:

```bash
cat > /home/dan/Projects/evolve-ai/.gitignore <<'GITIGNORE'
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
```

- [ ] **Step 5: Commit**

```bash
git add core/housekeeping.sh core/init.sh .gitignore
git commit -m "fix: prevent housekeeping from staging untracked files or secrets

Switch git add -A to git add -u for pre-pipeline snapshots. Add
.gitignore with secret and runtime exclusion patterns."
```

---

### Task 5: Source provider interface in orchestrator (fixes #1)

**Files:**
- Modify: `core/orchestrator.sh:5-11`

- [ ] **Step 1: Add provider interface source**

In `core/orchestrator.sh`, add after line 11 (`source "$SCRIPT_DIR_ORCH/lens/engine.sh"`):

```bash
source "$SCRIPT_DIR_ORCH/providers/interface.sh"
```

- [ ] **Step 2: Verify provider_invoke is now defined**

Run: `bash -c 'source core/orchestrator.sh && declare -f provider_invoke >/dev/null && echo "OK"'`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add core/orchestrator.sh
git commit -m "fix: source provider interface so phases actually execute

The orchestrator never loaded core/providers/interface.sh, causing
every phase to hit the STUB fallback."
```

---

### Task 6: Fix argument order and prompt path (fixes #2, #3)

**Files:**
- Modify: `core/orchestrator.sh:92,237`

- [ ] **Step 1: Fix argument order on line 92**

In `core/orchestrator.sh`, change line 92:

```bash
# Before:
provider_invoke "$phase_name" "$prompt_file" "$workspace" "$max_turns"

# After:
provider_invoke "$prompt_file" "$max_turns" "$workspace" "$phase_name"
```

- [ ] **Step 2: Fix prompt directory on line 237**

In `core/orchestrator.sh`, change line 237:

```bash
# Before:
local prompts_dir="$evolve_root/prompts"

# After:
local prompts_dir="$evolve_root/core/phases"
```

- [ ] **Step 3: Verify prompt files exist at new path**

Run: `ls core/phases/*.md`
Expected: `analyze.md challenge.md digest.md finalize.md implement.md metrics.md strategize.md validate.md`

- [ ] **Step 4: Commit**

```bash
git add core/orchestrator.sh
git commit -m "fix: correct provider_invoke argument order and prompt path

Arguments were (phase, prompt, workspace, turns) but interface
expects (prompt, turns, workspace, phase). Prompt dir pointed to
nonexistent prompts/ instead of core/phases/."
```

---

### Task 7: Replace eval with structured rollback (fixes #4)

**Files:**
- Modify: `core/orchestrator.sh:98-127`
- Modify: `core/phases/implement.md`
- Test: `tests/test_orchestrator.sh`

- [ ] **Step 1: Write test for rollback safety**

Add to `tests/test_orchestrator.sh`:

```bash
# ---------------------------------------------------------------------------
# test_rollback_rejects_path_traversal
# ---------------------------------------------------------------------------
test_rollback_rejects_path_traversal() {
    echo "test_rollback_rejects_path_traversal"
    setup_test_env

    local manifest="$TEST_TMPDIR/rollback-manifest.json"
    cat > "$manifest" <<'JSON'
{
  "changes": [
    {
      "description": "malicious traversal",
      "undo": {
        "op": "rm",
        "path": "../../etc/shadow"
      }
    }
  ]
}
JSON

    local output
    output="$(execute_rollback_manifest "$manifest" 2>&1)"

    # The traversal path should be blocked
    assert_contains "$output" "blocked" "path traversal blocked"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_rollback_rejects_absolute_path
# ---------------------------------------------------------------------------
test_rollback_rejects_absolute_path() {
    echo "test_rollback_rejects_absolute_path"
    setup_test_env

    local manifest="$TEST_TMPDIR/rollback-manifest.json"
    cat > "$manifest" <<'JSON'
{
  "changes": [
    {
      "description": "malicious absolute",
      "undo": {
        "op": "rm",
        "path": "/etc/passwd"
      }
    }
  ]
}
JSON

    local output
    output="$(execute_rollback_manifest "$manifest" 2>&1)"

    assert_contains "$output" "blocked" "absolute path blocked"

    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_rollback_executes_safe_ops
# ---------------------------------------------------------------------------
test_rollback_executes_safe_ops() {
    echo "test_rollback_executes_safe_ops"
    setup_test_env

    # Create a file to be removed by rollback
    mkdir -p "$TEST_TMPDIR/src"
    echo "test" > "$TEST_TMPDIR/src/new-file.sh"

    local manifest="$TEST_TMPDIR/rollback-manifest.json"
    cat > "$manifest" <<JSON
{
  "changes": [
    {
      "description": "remove new file",
      "undo": {
        "op": "rm",
        "path": "src/new-file.sh"
      }
    }
  ]
}
JSON

    # Need EVOLVE_ROOT set for path resolution
    EVOLVE_ROOT="$TEST_TMPDIR" execute_rollback_manifest "$manifest" 2>/dev/null

    local exists=0
    [[ -f "$TEST_TMPDIR/src/new-file.sh" ]] && exists=1
    assert_eq "0" "$exists" "safe rm operation executed"

    teardown_test_env
}
```

Add to the run section:
```bash
test_rollback_rejects_path_traversal
test_rollback_rejects_absolute_path
test_rollback_executes_safe_ops
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_orchestrator.sh`
Expected: New rollback tests FAIL (current code uses eval, doesn't have structured ops)

- [ ] **Step 3: Replace execute_rollback_manifest in core/orchestrator.sh**

Replace lines 98-127 with:

```bash
# ---------------------------------------------------------------------------
# _validate_rollback_path <path>
# Returns 0 if path is safe (relative, no traversal), 1 if unsafe.
# ---------------------------------------------------------------------------
_validate_rollback_path() {
    local p="$1"
    [[ "$p" == /* ]] && return 1     # absolute path
    [[ "$p" == *..* ]] && return 1   # traversal
    return 0
}

# ---------------------------------------------------------------------------
# execute_rollback_manifest <manifest_file>
# Reads a JSON manifest with a .changes array.
# Each element has a structured .undo object with an .op field.
# Supported ops: git_checkout, git_revert, rm, cp
# ---------------------------------------------------------------------------
execute_rollback_manifest() {
    local manifest_file="$1"
    local evolve_root="${EVOLVE_ROOT:-.}"

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
        local op
        op="$(jq -r ".changes[$i].undo.op // empty" "$manifest_file")"

        if [[ -z "$op" ]]; then
            echo "[orchestrator] Rollback step $i: no op specified — skipping" >&2
            (( i++ )) || true
            continue
        fi

        case "$op" in
            git_checkout)
                local ref path
                ref="$(jq -r ".changes[$i].undo.ref" "$manifest_file")"
                path="$(jq -r ".changes[$i].undo.path" "$manifest_file")"
                if _validate_rollback_path "$path"; then
                    echo "[orchestrator] Rollback step $i: git checkout $ref -- $path" >&2
                    git -C "$evolve_root" checkout "$ref" -- "$path" 2>/dev/null \
                        || echo "[orchestrator] Rollback step $i failed (continuing)" >&2
                else
                    echo "[orchestrator] Rollback step $i: blocked unsafe path '$path'" >&2
                fi
                ;;
            git_revert)
                local ref
                ref="$(jq -r ".changes[$i].undo.ref" "$manifest_file")"
                echo "[orchestrator] Rollback step $i: git revert $ref" >&2
                git -C "$evolve_root" revert --no-edit "$ref" 2>/dev/null \
                    || echo "[orchestrator] Rollback step $i failed (continuing)" >&2
                ;;
            rm)
                local path
                path="$(jq -r ".changes[$i].undo.path" "$manifest_file")"
                if _validate_rollback_path "$path"; then
                    echo "[orchestrator] Rollback step $i: rm $path" >&2
                    rm -f "$evolve_root/$path" \
                        || echo "[orchestrator] Rollback step $i failed (continuing)" >&2
                else
                    echo "[orchestrator] Rollback step $i: blocked unsafe path '$path'" >&2
                fi
                ;;
            cp)
                local src dst
                src="$(jq -r ".changes[$i].undo.src" "$manifest_file")"
                dst="$(jq -r ".changes[$i].undo.dst" "$manifest_file")"
                if _validate_rollback_path "$src" && _validate_rollback_path "$dst"; then
                    echo "[orchestrator] Rollback step $i: cp $src -> $dst" >&2
                    cp "$evolve_root/$src" "$evolve_root/$dst" \
                        || echo "[orchestrator] Rollback step $i failed (continuing)" >&2
                else
                    echo "[orchestrator] Rollback step $i: blocked unsafe path(s)" >&2
                fi
                ;;
            *)
                echo "[orchestrator] Rollback step $i: unknown op '$op' — skipping" >&2
                ;;
        esac

        (( i++ )) || true
    done
}
```

- [ ] **Step 4: Update implement phase prompt**

In `core/phases/implement.md`, find the section about rollback/undo registration and add:

```markdown
## Rollback Manifest Format

When registering undo operations in `rollback-manifest.json`, use structured operations:

```json
{
  "changes": [
    {
      "description": "What this change did",
      "undo": {
        "op": "git_checkout",
        "ref": "HEAD~1",
        "path": "relative/path/to/file.sh"
      }
    }
  ]
}
```

**Supported ops:**
- `git_checkout` — requires `ref` and `path` (relative)
- `git_revert` — requires `ref` (commit hash)
- `rm` — requires `path` (relative, single file)
- `cp` — requires `src` and `dst` (both relative)

**All paths must be relative** (no leading `/`, no `..` components). Absolute or traversal paths are blocked.

Do NOT use free-form shell commands. Only the structured ops above are supported.
```

- [ ] **Step 5: Run orchestrator tests**

Run: `bash tests/test_orchestrator.sh`
Expected: ALL tests pass

- [ ] **Step 6: Commit**

```bash
git add core/orchestrator.sh core/phases/implement.md tests/test_orchestrator.sh
git commit -m "fix: replace eval in crash recovery with structured rollback ops

Eliminates arbitrary code execution from rollback-manifest.json.
Only git_checkout, git_revert, rm, and cp ops are allowed. All
paths validated as relative with no traversal."
```

---

### Task 8: Fix resource limit key lookups (fixes #13)

**Files:**
- Modify: `core/resources.sh:25,48`

- [ ] **Step 1: Fix key prefixes**

In `core/resources.sh`:

Change line 25:
```bash
# Before:
threshold="$(config_get_default "min_free_ram_mb" "1500")"

# After:
threshold="$(config_get_default "resources.min_free_ram_mb" "1500")"
```

Change line 48:
```bash
# Before:
threshold="$(config_get_default "max_disk_usage_pct" "85")"

# After:
threshold="$(config_get_default "resources.max_disk_usage_pct" "85")"
```

- [ ] **Step 2: Verify keys resolve**

Run: `bash -c 'source core/config.sh && load_config config/evolve.yaml && config_get resources.min_free_ram_mb'`
Expected: `1500`

- [ ] **Step 3: Commit**

```bash
git add core/resources.sh
git commit -m "fix: use correct scoped keys for resource limit lookups

Config stores values as resources.min_free_ram_mb but code looked
up min_free_ram_mb. Bug was masked by matching hardcoded defaults."
```

---

### Task 9: Fix notification config key mismatch (fixes #9)

**Files:**
- Modify: `core/notifications/engine.sh:88-114`
- Test: `tests/test_notifications.sh`

- [ ] **Step 1: Write failing test for env var resolution**

Add to `tests/test_notifications.sh`, before the "Run all tests" section:

```bash
# ---------------------------------------------------------------------------
# test_load_notification_config_env_vars
# ---------------------------------------------------------------------------
test_load_notification_config_env_vars() {
    echo "test_load_notification_config_env_vars"
    setup_test_env

    local yaml="$TEST_TMPDIR/evolve.yaml"
    cat > "$yaml" <<'YAML'
version: "1.0.0"

notifications:
  - type: "telegram"
    bot_token_env: "TEST_BOT_TOKEN"
    chat_id_env: "TEST_CHAT_ID"
  - type: "slack"
    webhook_url_env: "TEST_SLACK_WEBHOOK"

provider:
  type: "claude-max"
YAML

    export TEST_BOT_TOKEN="my-secret-token"
    export TEST_CHAT_ID="12345"
    export TEST_SLACK_WEBHOOK="https://hooks.slack.com/secret"

    load_notification_config "$yaml"

    assert_eq 2 "${#_NOTIFICATION_ENTRIES[@]}" "parsed 2 notification entries"
    assert_eq "telegram|my-secret-token|12345" "${_NOTIFICATION_ENTRIES[0]}" "telegram env vars resolved"
    assert_eq "slack|https://hooks.slack.com/secret|" "${_NOTIFICATION_ENTRIES[1]}" "slack env var resolved"

    unset TEST_BOT_TOKEN TEST_CHAT_ID TEST_SLACK_WEBHOOK
    teardown_test_env
}
```

Add to the run section:
```bash
test_load_notification_config_env_vars
```

- [ ] **Step 2: Run tests to verify new test fails**

Run: `bash tests/test_notifications.sh`
Expected: `test_load_notification_config_env_vars` FAILS

- [ ] **Step 3: Add _env resolution to engine.sh**

In `core/notifications/engine.sh`, after the `bot_token:` regex block (around line 97), add:

```bash
            # bot_token_env (env var reference — resolve it)
            if [[ "$stripped" =~ ^bot_token_env:[[:space:]]*(.+) ]]; then
                local env_name="${BASH_REMATCH[1]}"
                env_name="${env_name%\"}"
                env_name="${env_name#\"}"
                env_name="${env_name%\'}"
                env_name="${env_name#\'}"
                if [[ -z "$current_param1" ]]; then
                    current_param1="${!env_name:-}"
                fi
            fi
```

After the `chat_id:` block (around line 105), add:

```bash
            # chat_id_env
            if [[ "$stripped" =~ ^chat_id_env:[[:space:]]*(.+) ]]; then
                local env_name="${BASH_REMATCH[1]}"
                env_name="${env_name%\"}"
                env_name="${env_name#\"}"
                env_name="${env_name%\'}"
                env_name="${env_name#\'}"
                if [[ -z "$current_param2" ]]; then
                    current_param2="${!env_name:-}"
                fi
            fi
```

After the `webhook_url:` block (around line 113), add:

```bash
            # webhook_url_env
            if [[ "$stripped" =~ ^webhook_url_env:[[:space:]]*(.+) ]]; then
                local env_name="${BASH_REMATCH[1]}"
                env_name="${env_name%\"}"
                env_name="${env_name#\"}"
                env_name="${env_name%\'}"
                env_name="${env_name#\'}"
                if [[ -z "$current_param1" ]]; then
                    current_param1="${!env_name:-}"
                fi
            fi
```

- [ ] **Step 4: Run notification tests**

Run: `bash tests/test_notifications.sh`
Expected: ALL tests pass

- [ ] **Step 5: Commit**

```bash
git add core/notifications/engine.sh tests/test_notifications.sh
git commit -m "fix: add env var resolution for notification config keys

Init writes bot_token_env/chat_id_env/webhook_url_env but engine
only parsed bot_token/chat_id/webhook_url. Now supports both
formats with direct values taking precedence."
```

---

### Task 10: Fix LLM judge config and response parsing (fixes #10, #11)

**Files:**
- Modify: `core/scoring/engine.sh:92-145,470-541`

- [ ] **Step 1: Fix config key paths**

In `core/scoring/engine.sh`:

Change line 97:
```bash
# Before:
llm_enabled="$(config_get_default "llm_judge.enabled" "false")"

# After:
llm_enabled="$(config_get_default "scorers.llm_judge.enabled" "false")"
```

Change line 116:
```bash
# Before:
judge_prompt="$(config_get_default "llm_judge.prompt" "Rate this change from 0.0 to 1.0 based on quality and impact.")"

# After:
judge_prompt="$(config_get_default "scorers.llm_judge.prompt" "Rate this change from 0.0 to 1.0 based on quality and impact.")"
```

- [ ] **Step 2: Fix response parsing (lines 143-145)**

Replace lines 143-145:

```bash
# Before:
local score reasoning
score="$(printf '%s' "$response" | jq -r '.score // 0.5' 2>/dev/null)" || score="0.5"
reasoning="$(printf '%s' "$response" | jq -r '.reasoning // "no reasoning"' 2>/dev/null)" || reasoning="no reasoning"

# After:
local score="0.5"
local reasoning="no reasoning"
if [[ -f "$response" ]] && jq empty "$response" 2>/dev/null; then
    score="$(jq -r '.score // 0.5' "$response" 2>/dev/null)" || score="0.5"
    reasoning="$(jq -r '.reasoning // "no reasoning"' "$response" 2>/dev/null)" || reasoning="no reasoning"
else
    reasoning="response file missing or invalid JSON"
fi
```

- [ ] **Step 3: Replace _parse_scorer_list with yq**

Replace lines 470-541 (the entire `_parse_scorer_list` function) with:

```bash
# ---------------------------------------------------------------------------
# _parse_scorer_list <genome_yaml> <scorer_type>
# Extracts scorer definitions from scorers.<type>[] using yq.
# Outputs a JSON array of {name, command, weight, direction}.
# ---------------------------------------------------------------------------
_parse_scorer_list() {
    local genome_yaml="$1"
    local scorer_type="$2"

    if [[ ! -f "$genome_yaml" ]]; then
        echo "[]"
        return 0
    fi

    yq -o=json ".scorers.$scorer_type // []" "$genome_yaml" 2>/dev/null || echo "[]"
}
```

- [ ] **Step 4: Run scoring tests**

Run: `bash tests/test_scoring.sh`
Expected: ALL tests pass

- [ ] **Step 5: Commit**

```bash
git add core/scoring/engine.sh
git commit -m "fix: correct LLM judge config paths and response file parsing

Config keys updated from llm_judge.* to scorers.llm_judge.*.
Response parsing now reads the file at the path instead of piping
the path string through jq. Replaced 70-line awk scorer parser
with 5-line yq call."
```

---

### Task 11: Fix genome validation and stub providers (fixes #8, #14)

**Files:**
- Modify: `core/genomes/validator.sh:45-76`
- Modify: `core/init.sh:174-197`
- Modify: `core/providers/interface.sh:34`

- [ ] **Step 1: Strengthen genome validation**

In `core/genomes/validator.sh`, add after the existing field-presence loop (after line 66, before restoring cache):

```bash
    # Schema shape validation using yq
    # scan_commands must be a list of strings (not maps)
    if yq 'has("scan_commands")' "$genome_yaml" 2>/dev/null | grep -q "true"; then
        local bad_items
        bad_items="$(yq '.scan_commands[] | tag' "$genome_yaml" 2>/dev/null | grep -v '!!str' | head -1 || true)"
        if [[ -n "$bad_items" ]]; then
            echo "validate_genome: scan_commands contains non-string items (found $bad_items) in $genome_yaml" >&2
            errors=$(( errors + 1 ))
        fi
    fi

    # health_checks entries must have name, command, expect
    if yq 'has("health_checks")' "$genome_yaml" 2>/dev/null | grep -q "true"; then
        local hc_count
        hc_count="$(yq '.health_checks | length' "$genome_yaml" 2>/dev/null || echo 0)"
        local j=0
        while (( j < hc_count )); do
            local hc_name
            hc_name="$(yq ".health_checks[$j].name // \"\"" "$genome_yaml" 2>/dev/null)"
            if [[ -z "$hc_name" || "$hc_name" == "null" ]]; then
                echo "validate_genome: health_checks[$j] missing 'name' field in $genome_yaml" >&2
                errors=$(( errors + 1 ))
            fi
            local hc_cmd
            hc_cmd="$(yq ".health_checks[$j].command // \"\"" "$genome_yaml" 2>/dev/null)"
            if [[ -z "$hc_cmd" || "$hc_cmd" == "null" ]]; then
                echo "validate_genome: health_checks[$j] missing 'command' field in $genome_yaml" >&2
                errors=$(( errors + 1 ))
            fi
            (( j++ )) || true
        done
    fi
```

- [ ] **Step 2: Mark stub providers in init**

In `core/init.sh`, replace lines 178-181:

```bash
# Before:
echo "  [2] Claude via API key"
echo "  [3] OpenAI-compatible API"
echo "  [4] Custom provider"

# After:
echo "  [2] Claude via API key (not yet implemented)"
echo "  [3] OpenAI-compatible API (not yet implemented)"
```

Replace the case block (lines 187-193):

```bash
    case "$choice" in
        1) PROVIDER_TYPE="claude-max" ;;
        2)
            echo "  Warning: claude-api provider is a stub and will fail at runtime." >&2
            local confirm
            read -rp "  Continue anyway? (y/N) " confirm
            [[ "$confirm" =~ ^[Yy] ]] && PROVIDER_TYPE="claude-api" || PROVIDER_TYPE="claude-max"
            ;;
        3)
            echo "  Warning: openai provider is a stub and will fail at runtime." >&2
            local confirm
            read -rp "  Continue anyway? (y/N) " confirm
            [[ "$confirm" =~ ^[Yy] ]] && PROVIDER_TYPE="openai" || PROVIDER_TYPE="claude-max"
            ;;
        *) PROVIDER_TYPE="claude-max" ;;
    esac
```

- [ ] **Step 3: Add custom case to provider interface**

In `core/providers/interface.sh`, change the `*)` wildcard case (line 34) to add `custom)` before it:

```bash
        custom)
            echo "[provider] Custom provider not configured" >&2
            return 1
            ;;
        *)
            echo "[provider] Unknown provider type: $provider_type" >&2
            return 1
            ;;
```

- [ ] **Step 4: Run genome tests**

Run: `bash tests/test_genomes.sh`
Expected: ALL tests pass

- [ ] **Step 5: Commit**

```bash
git add core/genomes/validator.sh core/init.sh core/providers/interface.sh
git commit -m "fix: strengthen genome validation and mark stub providers

Genome validator now checks scan_commands type and health_check
required fields. Init marks claude-api and openai as unimplemented
with confirmation prompt. Adds explicit custom provider case."
```

---

### Task 12: Fix JSON injection in resume-runner (fixes #15)

**Files:**
- Modify: `core/resume/resume-runner.sh:136-189`

- [ ] **Step 1: Replace redirect heredoc (lines 136-145)**

Replace:
```bash
            cat > "$inject_file" <<INJEOF
{
  "id": "${change_id}-redirect",
  "source": "human",
  "status": "pending",
  "description": "${new_framing}",
  "origin_context": "${context_id}",
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
INJEOF
```

With:
```bash
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

- [ ] **Step 2: Replace expand heredoc (lines 158-167)**

Replace the heredoc with:
```bash
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
```

- [ ] **Step 3: Replace modify heredoc (lines 180-189)**

Replace the heredoc with:
```bash
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
```

- [ ] **Step 4: Verify JSON output with special characters**

Run: `jq -n --arg desc 'He said "hello" and it'\''s fine\nwith newlines' '{description: $desc}'`
Expected: Valid JSON with escaped quotes and literal `\n`

- [ ] **Step 5: Commit**

```bash
git add core/resume/resume-runner.sh
git commit -m "fix: use jq for safe JSON construction in resume-runner

Replaces heredoc interpolation with jq --arg to properly escape
quotes, newlines, and special characters in user input."
```

---

### Task 13: Fix YAML injection in directives (fixes #16)

**Files:**
- Modify: `core/directives/manager.sh:22-62`

- [ ] **Step 1: Add _yaml_quote helper**

Add after line 13 (the `_sanitize_target` function):

```bash
# ---------------------------------------------------------------------------
# _yaml_quote <value>
#
# Safely quotes a string for YAML output using single-quote wrapping.
# Single quotes inside the value are escaped as '' (YAML spec).
# ---------------------------------------------------------------------------
_yaml_quote() {
    local val="$1"
    val="${val//\'/\'\'}"
    printf "'%s'" "$val"
}
```

- [ ] **Step 2: Update directive_create to use safe quoting**

Replace the two heredoc blocks in `directive_create` (lines 41-59) with:

```bash
    local q_type q_target q_rule q_source
    q_type="$(_yaml_quote "$type")"
    q_target="$(_yaml_quote "$target")"
    q_rule="$(_yaml_quote "$rule")"
    q_source="$(_yaml_quote "$source")"

    if [[ "$expires" == "null" ]]; then
        cat > "$filepath" <<YAMLEOF
type: ${q_type}
target: ${q_target}
rule: ${q_rule}
created: "${created}"
source: ${q_source}
expires: null
YAMLEOF
    else
        cat > "$filepath" <<YAMLEOF
type: ${q_type}
target: ${q_target}
rule: ${q_rule}
created: "${created}"
source: ${q_source}
expires: "$(_yaml_quote "$expires")"
YAMLEOF
    fi
```

- [ ] **Step 3: Run directive tests**

Run: `bash tests/test_directives.sh`
Expected: ALL tests pass

- [ ] **Step 4: Commit**

```bash
git add core/directives/manager.sh
git commit -m "fix: use YAML single-quote escaping in directive creation

Prevents YAML injection from user-supplied target and rule values
containing quotes, colons, or newlines."
```

---

### Task 14: Fix JSON injection in Slack/Discord notifications (fixes #17)

**Files:**
- Modify: `core/notifications/slack.sh`
- Modify: `core/notifications/discord.sh`

- [ ] **Step 1: Rewrite slack.sh**

Replace the entire file:

```bash
#!/usr/bin/env bash
# core/notifications/slack.sh — Slack notification provider

# notify_slack <message> <webhook_url>
# Posts a message to a Slack incoming webhook. Silent on failure.
notify_slack() {
    local message="$1"
    local webhook_url="$2"

    if [[ -z "$webhook_url" ]]; then
        return 0
    fi

    local payload
    payload="$(jq -n --arg text "$message" '{"text": $text}')"

    curl -s -X POST "$webhook_url" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        >/dev/null 2>&1 || true
}
```

- [ ] **Step 2: Rewrite discord.sh**

Replace the entire file:

```bash
#!/usr/bin/env bash
# core/notifications/discord.sh — Discord notification provider

# notify_discord <message> <webhook_url>
# Posts a message to a Discord webhook. Silent on failure.
notify_discord() {
    local message="$1"
    local webhook_url="$2"

    if [[ -z "$webhook_url" ]]; then
        return 0
    fi

    local payload
    payload="$(jq -n --arg text "$message" '{"content": $text}')"

    curl -s -X POST "$webhook_url" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        >/dev/null 2>&1 || true
}
```

- [ ] **Step 3: Commit**

```bash
git add core/notifications/slack.sh core/notifications/discord.sh
git commit -m "fix: use jq for safe JSON payloads in Slack/Discord notifications

Prevents message content with quotes or newlines from breaking
the curl JSON payload."
```

---

### Task 15: Fix sed injection in custom genome creation (fixes #18)

**Files:**
- Modify: `core/init.sh:576-577`

- [ ] **Step 1: Replace sed with yq**

In `core/init.sh`, replace lines 576-577:

```bash
# Before:
sed -i "s/^name: .*/name: \"$genome_name\"/" "$genome_dir/genome.yaml"
sed -i "s/^description: .*/description: \"$description\"/" "$genome_dir/genome.yaml"

# After:
yq -i ".name = \"$genome_name\"" "$genome_dir/genome.yaml"
DESC="$description" yq -i '.description = strenv(DESC)' "$genome_dir/genome.yaml"
```

The `genome_name` is already sanitized (alphanumeric + hyphens only, line 556). The `description` uses `strenv()` to safely inject the env var value without shell quoting issues.

- [ ] **Step 2: Commit**

```bash
git add core/init.sh
git commit -m "fix: use yq instead of sed for safe genome YAML editing

Prevents description values containing /, &, or quotes from
breaking sed replacement patterns."
```

---

### Task 16: Fix feed schedule advancement on failure (fixes #12)

**Files:**
- Modify: `core/lens/feed-runner.sh:277-296`

- [ ] **Step 1: Replace unconditional source_mark_run**

In `core/lens/feed-runner.sh`, replace the case block and `source_mark_run` call (approximately lines 277-296) with:

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
            echo "[feed-runner] Webhook feed '$name' is a listener — start separately" >&2
            return 0
            ;;
        *)
            echo "[feed-runner] Unknown feed type '$type' for '$name'" >&2
            return 1
            ;;
    esac

    if [[ $adapter_rc -eq 0 ]]; then
        # Mark as run only on success
        source_mark_run "$evolve_root" "$name"
    else
        echo "[feed-runner] Feed '$name' failed (rc=$adapter_rc) — will retry next run" >&2
    fi
```

- [ ] **Step 2: Commit**

```bash
git add core/lens/feed-runner.sh
git commit -m "fix: only advance feed schedule on successful adapter run

Failed RSS fetches or command runs no longer suppress retries
for the entire schedule interval."
```

---

### Task 17: Fix metrics dedup to use composite key (fixes #19)

**Files:**
- Modify: `core/memory/manager.sh:200-211`

- [ ] **Step 1: Replace id-only dedup with composite key**

In `core/memory/manager.sh`, replace lines 200-211:

```bash
# Before:
    if [[ -z "$metric_id" ]]; then
        printf '%s\n' "$metric_json" >> "$metrics_file"
        return 0
    fi

    # Dedup check: skip if id already exists
    if [[ -f "$metrics_file" ]] && grep -q "\"id\":\"${metric_id}\"" "$metrics_file" 2>/dev/null; then
        return 0
    fi

    printf '%s\n' "$metric_json" >> "$metrics_file"
    return 0
```

With:

```bash
    if [[ -z "$metric_id" ]]; then
        printf '%s\n' "$metric_json" >> "$metrics_file"
        return 0
    fi

    # Dedup check: composite key id + run_date
    local run_date
    run_date="$(printf '%s' "$metric_json" | jq -r '.run_date // ""' 2>/dev/null)"

    if [[ -n "$run_date" && -f "$metrics_file" ]]; then
        # Check composite key: both id AND run_date must match
        if grep -F "\"id\":\"${metric_id}\"" "$metrics_file" 2>/dev/null | grep -Fq "\"run_date\":\"${run_date}\"" 2>/dev/null; then
            return 0
        fi
    elif [[ -z "$run_date" && -f "$metrics_file" ]]; then
        # Fallback: if no run_date, dedup by id only
        if grep -Fq "\"id\":\"${metric_id}\"" "$metrics_file" 2>/dev/null; then
            return 0
        fi
    fi

    printf '%s\n' "$metric_json" >> "$metrics_file"
    return 0
```

- [ ] **Step 2: Commit**

```bash
git add core/memory/manager.sh
git commit -m "fix: use composite id+run_date key for metrics dedup

Same metric ID across different runs is now correctly stored as
separate records, matching the metrics phase contract."
```

---

### Task 18: Deduplicate inbox/lens adapters (fixes #20)

**Files:**
- Create: `core/adapters/command.sh`
- Create: `core/adapters/rss.sh`
- Create: `core/adapters/manual.sh`
- Create: `core/adapters/webhook.sh`
- Modify: `core/inbox/sources/command.sh`
- Modify: `core/inbox/sources/rss.sh`
- Modify: `core/inbox/sources/manual.sh`
- Modify: `core/inbox/sources/webhook.sh`
- Modify: `core/lens/adapters/command.sh`
- Modify: `core/lens/adapters/rss.sh`
- Modify: `core/lens/adapters/manual.sh`
- Modify: `core/lens/adapters/webhook.sh`

- [ ] **Step 1: Create core/adapters/ directory and move canonical files**

```bash
mkdir -p core/adapters
cp core/inbox/sources/command.sh core/adapters/command.sh
cp core/inbox/sources/rss.sh core/adapters/rss.sh
cp core/inbox/sources/manual.sh core/adapters/manual.sh
cp core/inbox/sources/webhook.sh core/adapters/webhook.sh
```

- [ ] **Step 2: Replace inbox source files with wrappers**

For each file in `core/inbox/sources/`, replace content with a source wrapper:

`core/inbox/sources/command.sh`:
```bash
#!/usr/bin/env bash
# core/inbox/sources/command.sh — delegates to shared adapter
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/command.sh"
```

`core/inbox/sources/rss.sh`:
```bash
#!/usr/bin/env bash
# core/inbox/sources/rss.sh — delegates to shared adapter
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/rss.sh"
```

`core/inbox/sources/manual.sh`:
```bash
#!/usr/bin/env bash
# core/inbox/sources/manual.sh — delegates to shared adapter
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/manual.sh"
```

`core/inbox/sources/webhook.sh`:
```bash
#!/usr/bin/env bash
# core/inbox/sources/webhook.sh — delegates to shared adapter
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/webhook.sh"
```

- [ ] **Step 3: Replace lens adapter files with wrappers**

Same pattern for `core/lens/adapters/`:

`core/lens/adapters/command.sh`:
```bash
#!/usr/bin/env bash
# core/lens/adapters/command.sh — delegates to shared adapter
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/command.sh"
```

`core/lens/adapters/rss.sh`:
```bash
#!/usr/bin/env bash
# core/lens/adapters/rss.sh — delegates to shared adapter
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/rss.sh"
```

`core/lens/adapters/manual.sh`:
```bash
#!/usr/bin/env bash
# core/lens/adapters/manual.sh — delegates to shared adapter
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/manual.sh"
```

`core/lens/adapters/webhook.sh`:
```bash
#!/usr/bin/env bash
# core/lens/adapters/webhook.sh — delegates to shared adapter
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/webhook.sh"
```

- [ ] **Step 4: Run inbox tests**

Run: `bash tests/test_inbox.sh`
Expected: ALL tests pass

- [ ] **Step 5: Commit**

```bash
git add core/adapters/ core/inbox/sources/ core/lens/adapters/
git commit -m "refactor: deduplicate inbox/lens adapters into core/adapters/

Four file pairs (command, rss, manual, webhook) were byte-for-byte
identical. Canonical implementations now live in core/adapters/
with both inbox and lens locations as thin source wrappers."
```

---

### Task 19: Fix notification test coverage (fixes #21)

**Files:**
- Modify: `tests/test_notifications.sh`

- [ ] **Step 1: Add round-trip test**

Add to `tests/test_notifications.sh`, before the "Run all tests" section:

```bash
# ---------------------------------------------------------------------------
# test_notification_config_init_format_roundtrip
# ---------------------------------------------------------------------------
test_notification_config_init_format_roundtrip() {
    echo "test_notification_config_init_format_roundtrip"
    setup_test_env

    # This is exactly what evolve init generates for Telegram
    local yaml="$TEST_TMPDIR/evolve.yaml"
    cat > "$yaml" <<'YAML'
version: "1.0.0"

notifications:
  - type: "telegram"
    bot_token_env: "EVOLVE_TG_BOT_TOKEN"
    chat_id_env: "EVOLVE_TG_CHAT_ID"
  - type: "slack"
    webhook_url_env: "EVOLVE_SLACK_WEBHOOK"
  - type: "discord"
    webhook_url_env: "EVOLVE_DISCORD_WEBHOOK"
YAML

    export EVOLVE_TG_BOT_TOKEN="tg-token-123"
    export EVOLVE_TG_CHAT_ID="tg-chat-456"
    export EVOLVE_SLACK_WEBHOOK="https://hooks.slack.com/services/xxx"
    export EVOLVE_DISCORD_WEBHOOK="https://discord.com/api/webhooks/yyy"

    load_notification_config "$yaml"

    assert_eq 3 "${#_NOTIFICATION_ENTRIES[@]}" "parsed 3 init-format entries"
    assert_eq "telegram|tg-token-123|tg-chat-456" "${_NOTIFICATION_ENTRIES[0]}" "telegram init format roundtrip"
    assert_eq "slack|https://hooks.slack.com/services/xxx|" "${_NOTIFICATION_ENTRIES[1]}" "slack init format roundtrip"
    assert_eq "discord|https://discord.com/api/webhooks/yyy|" "${_NOTIFICATION_ENTRIES[2]}" "discord init format roundtrip"

    unset EVOLVE_TG_BOT_TOKEN EVOLVE_TG_CHAT_ID EVOLVE_SLACK_WEBHOOK EVOLVE_DISCORD_WEBHOOK
    teardown_test_env
}

# ---------------------------------------------------------------------------
# test_notification_config_missing_env_var
# ---------------------------------------------------------------------------
test_notification_config_missing_env_var() {
    echo "test_notification_config_missing_env_var"
    setup_test_env

    local yaml="$TEST_TMPDIR/evolve.yaml"
    cat > "$yaml" <<'YAML'
version: "1.0.0"

notifications:
  - type: "telegram"
    bot_token_env: "NONEXISTENT_VAR"
    chat_id_env: "ALSO_NONEXISTENT"
YAML

    unset NONEXISTENT_VAR 2>/dev/null || true
    unset ALSO_NONEXISTENT 2>/dev/null || true

    load_notification_config "$yaml"

    # Should parse the entry but with empty resolved values
    assert_eq 1 "${#_NOTIFICATION_ENTRIES[@]}" "parsed 1 entry with missing env vars"
    assert_eq "telegram||" "${_NOTIFICATION_ENTRIES[0]}" "missing env vars resolve to empty"

    teardown_test_env
}
```

Add to the run section:
```bash
test_notification_config_init_format_roundtrip
test_notification_config_missing_env_var
```

- [ ] **Step 2: Run notification tests**

Run: `bash tests/test_notifications.sh`
Expected: ALL tests pass

- [ ] **Step 3: Commit**

```bash
git add tests/test_notifications.sh
git commit -m "test: add notification config round-trip and missing env var tests

Covers the exact YAML format that evolve init generates, verifying
env var resolution works end-to-end. Also tests graceful handling
of missing environment variables."
```

---

### Task 20: Run full test suite and verify

- [ ] **Step 1: Run all test files**

```bash
for t in tests/test_*.sh; do
    echo "=== $t ==="
    bash "$t"
    echo ""
done
```

Expected: All tests pass across all files.

- [ ] **Step 2: Verify pipeline starts without STUB messages**

Run: `bash -c 'source core/orchestrator.sh && declare -f provider_invoke >/dev/null && echo "provider loaded"'`
Expected: `provider loaded`

- [ ] **Step 3: Verify directed mode genome lookup works (defect #5)**

```bash
bash -c '
source core/config.sh
load_config config/evolve.yaml
genome="$(config_get targets.0.genome)"
echo "targets.0.genome = $genome"
if [[ "$genome" == "infrastructure" ]]; then
    echo "PASS: directed mode genome lookup works"
else
    echo "FAIL: expected infrastructure, got $genome"
fi
'
```

Expected: `PASS: directed mode genome lookup works`

- [ ] **Step 4: Verify config parser handles all key formats**

```bash
bash -c '
source core/config.sh
load_config config/evolve.yaml
echo "targets.0.genome = $(config_get targets.0.genome)"
echo "resources.min_free_ram_mb = $(config_get resources.min_free_ram_mb)"
echo "convergence.max_stalls = $(config_get convergence.max_stalls)"
echo "pipeline.phases.0 = $(config_get pipeline.phases.0)"
'
```

Expected:
```
targets.0.genome = infrastructure
resources.min_free_ram_mb = 1500
convergence.max_stalls = 3
pipeline.phases.0 = digest
```

- [ ] **Step 5: Commit (if any fixups were needed)**

Only if issues were found and fixed in previous steps.
