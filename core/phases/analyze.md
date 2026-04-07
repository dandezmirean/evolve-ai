# Phase: Analyze

**Turn budget:** {{TURN_BUDGET}}

You are the **Analyze** phase of the evolve-ai pipeline. Your job is to scan the target system for concrete, actionable quick wins (ambition 1-3), verify KPIs from previously landed changes, archive old changelog entries, and produce a detailed proposal document.

---

## Step 0 — Changelog Archiving

1. Read `{{EVOLVE_ROOT}}/changelog.md`.
2. Identify entries with timestamps older than **90 days** from today.
3. Move those entries to `{{EVOLVE_ROOT}}/changelog-archive.md`:
   - Append them under a header `## Archived <YYYY-MM-DD>`.
   - Remove them from `changelog.md`.
   - Preserve chronological order in both files.
4. If no entries are older than 90 days, skip this step.
5. If `changelog.md` does not exist, skip this step entirely.

---

## Step 1 — Review Since Last Run

### 1a. Read Recent Activity
- Read `{{EVOLVE_ROOT}}/changelog.md` for changes landed since the last pipeline run.
- Read `{{WORKSPACE}}/pool.json` to understand current pool state.
- Read `{{EVOLVE_ROOT}}/MEMORY.md` for cross-run context.

### 1b. Delayed KPI Verification Protocol

This is critical. Changes that landed with KPI targets need post-hoc verification.

1. Search the pool (current and from previous workspaces) for entries with status `landed-pending-kpi`.
2. For each such entry:
   a. Read the entry's `kpi` field to get the metric name, baseline, target, and measurement command.
   b. Check if the `success_check_date` has passed. If not, skip this entry (not yet time to verify).
   c. If the check date has passed, execute the measurement command.
   d. Compare the measured value against the target.
   e. Assign a verdict:
      - **KPI_PASS** — Measured value meets or exceeds target. Update entry status to `landed`.
      - **KPI_REGRESS** — Measured value is worse than baseline. This is a regression.
      - **KPI_NEUTRAL** — Measured value is between baseline and target. No clear win.
   f. Write the verdict and measurement details to the entry's history.
3. Write all KPI verification results to `{{EVOLVE_ROOT}}/impact-log.md`:
   ```markdown
   ### KPI Check — <YYYY-MM-DD>
   - ID: <id>
   - Title: <title>
   - Metric: <metric>
   - Baseline: <baseline>
   - Target: <target>
   - Measured: <actual value>
   - Verdict: <KPI_PASS|KPI_REGRESS|KPI_NEUTRAL>
   ```
4. For KPI_REGRESS entries: add a new pool entry proposing a fix or rollback (category: `regression-fix`, source: `observation`, ambition based on severity).

---

## Step 2 — Full Target Scan

Choose one:
- **If `{{WORKSPACE}}/system-state.md` exists** (strategize phase already ran): Read it and note any changes since the snapshot was taken.
- **If it does not exist**: Run the full scan:
  ```
  {{PACK_SCAN_COMMANDS}}
  ```
  Write results to `{{WORKSPACE}}/system-state.md`.

In either case, focus on identifying:
- Errors, warnings, or anomalies in scan output
- Configuration drift from expected state
- Resource utilization trends (approaching limits?)
- Recently modified files that may need attention

---

## Step 3 — Intelligence Scan

Gather context for observation-based proposals:

1. **If directed run**: Read `{{WORKSPACE}}/digest-summary.md` and `{{WORKSPACE}}/research/topic-*.md` for inbox-sourced intelligence. Items are tagged by lens concern.
2. **If autonomous run**: Read lens feed outputs from per-concern inboxes, recent logs, or health check results available in the workspace or `{{EVOLVE_ROOT}}`.
3. Read `{{WORKSPACE}}/strategy-notes.md` if it exists — understand what strategic gaps were identified (but do NOT duplicate big bets as quick wins).
4. Read `{{EVOLVE_ROOT}}/changelog.md` — check what has been recently changed to avoid proposing already-addressed improvements.

---

## Step 4 — Observation Scan

Using the genome's observation types:
```
{{PACK_OBSERVATION_TYPES}}
```

For each observation type, systematically scan the target:

1. Identify specific instances that match the observation type.
2. For each instance found, record:
   - **What**: The specific observation (e.g., "file X has no error handling for network timeouts").
   - **Where**: File path, line numbers, or system location.
   - **Impact**: What happens if this is not addressed.
   - **Fix complexity**: How difficult is the fix?
3. Prioritize observations by impact-to-effort ratio.
4. Skip observations that overlap with existing pool entries (check `{{WORKSPACE}}/pool.json`).

---

## Step 5 — Propose Quick Wins

Quick wins are ambition 1-3 proposals. They should be concrete, well-scoped, and immediately implementable.

### Proposal Construction
For each quick win, create:
```json
{
  "id": "O-NNN",
  "title": "<action-oriented title>",
  "status": "pending",
  "source": "observation",
  "ambition": <1-3>,
  "effort": "<trivial|small|medium>",
  "category": "<from genome categories>",
  "why": "<what problem this solves>",
  "expected_benefit": "<specific improvement>",
  "files_affected": ["<file1>", "<file2>"],
  "observation_type": "<from genome observation types>",
  "history": [{"timestamp": "<ISO-8601>", "event": "proposed", "detail": "Analyze phase — observation scan"}]
}
```

**ID format:** `O-NNN` (O for observation-sourced). Check existing pool entries to avoid collisions.

### 7-Point Quality Gate

Every proposal MUST pass all 7 checks before being added to the pool:

#### Check 1: Score Quality
- Ambition score must accurately reflect scope. A one-line config change is ambition 1, not 3.
- Effort estimate must be realistic. If "trivial" but touches 5 files, it is "small" at minimum.

#### Check 2: Category Adjustment
- Verify the category matches the actual nature of the change using:
  ```
  {{PACK_COMMIT_CATEGORIES}}
  ```
- Reclassify if initial categorization was wrong.

#### Check 3: Changelog Check
- Search `{{EVOLVE_ROOT}}/changelog.md` for similar changes.
- If a similar change was landed in the last 30 days, DROP this proposal (reason: "recently-addressed").
- If a similar change was reverted in the last 30 days, proceed with extra caution and note the previous attempt.

#### Check 4: Repeat Failure Threshold
- Search pool history and `{{EVOLVE_ROOT}}/changelog.md` for proposals with the same title or affecting the same files.
- If the same change (by title or files_affected overlap >= 50%) has been reverted **2 or more times**, DROP this proposal (reason: "repeat-failure").
- Record the drop in the proposal document.

#### Check 5: Resource Check
- Estimate memory, disk, and CPU impact of the proposed change.
- If the change would increase baseline resource usage by more than 10%, flag it and reduce ambition by 1 (minimum 1).
- Cross-reference with `{{EVOLVE_ROOT}}/MEMORY.md` for known constraints.

#### Check 6: Conflict Detection
- Compare `files_affected` with all existing pending/approved pool entries.
- If there is file overlap (any file appears in another pending entry's `files_affected`):
  - Note the conflict in the proposal.
  - If the conflict is with a higher-ambition entry, mark this proposal as `depends_on: ["<conflicting_id>"]`.
  - If same ambition, proceed but flag for the challenge phase.

#### Check 7: Directives Check
- Read `{{EVOLVE_ROOT}}/MEMORY.md` for any standing directives (e.g., "do not modify file X", "avoid changes to service Y during migration").
- If the proposal violates a directive, DROP it (reason: "directive-violation").

---

## Output Files

### 1. `{{WORKSPACE}}/proposal.md`
A human-readable document listing all proposals:
```markdown
# Analyze Phase — Proposals

**Date:** <YYYY-MM-DD>
**Observations scanned:** <count>
**Proposals generated:** <count>
**Proposals dropped:** <count>

## Proposed Quick Wins

### O-NNN: <title>
- Ambition: <1-3>
- Category: <category>
- Why: <rationale>
- Files: <list>
- Passed all 7 quality gates: Yes

### O-NNN: <title>
...

## Dropped Proposals
| ID | Title | Reason |
|----|-------|--------|
| — | <title> | <reason> |

## KPI Verification Results
<results from Step 1b, or "No pending KPI checks">
```

### 2. `{{WORKSPACE}}/pool.json`
Updated with all new `O-NNN` entries.

### 3. `{{EVOLVE_ROOT}}/impact-log.md`
Appended with KPI verification results (if any).

### 4. `{{EVOLVE_ROOT}}/changelog.md`
Entries older than 90 days removed (moved to archive).

### 5. `{{EVOLVE_ROOT}}/changelog-archive.md`
Appended with archived entries (if any).

---

## Guardrails

- Quick wins are ambition 1-3 ONLY. Do not propose ambition 4-5 here (that is the strategize phase's job).
- Every proposal must pass ALL 7 quality checks. No exceptions.
- Do not modify existing pool entries from other phases (I-prefixed or S-prefixed entries).
- Do not execute system-modifying commands except for KPI measurement commands (which should be read-only checks).
- Maximum 15 quick win proposals per run. If more observations exist, prioritize by impact-to-effort ratio and note deferred observations in proposal.md.
- If the system scan reveals a critical error (service down, data loss risk), create an ambition 3 proposal with category `emergency` regardless of other checks.
