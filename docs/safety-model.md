# Safety Model

evolve-ai is designed to make autonomous changes to real systems. The safety model ensures it does so responsibly through multiple layers of protection.

## Safety Layers

The safety system has 5 independent layers:

```
Layer 1: Genome Safety Rules       (hard-coded prohibitions per target)
Layer 2: Directives               (runtime constraints from humans)
Layer 3: Challenge Phase           (adversarial pre-implementation review)
Layer 4: Circuit Breaker           (automatic pause after repeated failures)
Layer 5: Reversibility Model       (every change must be undoable)
```

Each layer can independently block or undo a change. They operate in sequence -- a change must pass all layers to proceed.

## Layer 1: Genome Safety Rules

Every genome defines two types of safety rules in `genome.yaml`:

### Never Rules

Absolute prohibitions that the pipeline must never violate under any circumstances.

```yaml
safety_rules:
  never:
    - "expose ports to public internet"
    - "disable firewall or security services"
    - "delete data volumes or databases"
    - "modify SSH to allow password authentication"
    - "run unverified scripts from the internet"
    - "store credentials in plain text"
```

Never rules are enforced at multiple points:
- The **challenge phase** kills any proposal that would violate a never rule
- The **validate phase** checks implementation output against never rules
- Phase prompt templates include the never rules as explicit guardrails

### Require Approval

Conditions that trigger human review before execution. When a condition matches, a resume context is generated and the change is held.

```yaml
safety_rules:
  require_approval:
    - condition: "category == 'security-config'"
    - condition: "ambition >= 5"
```

Conditions reference pool entry fields: `category`, `ambition`, `status`, and any custom fields.

### How Safety Rules Interact With Phases

| Phase | Safety Rule Effect |
|---|---|
| Analyze | Never rules included in prompt as constraints |
| Challenge | Proposals violating never rules are killed |
| Implement | Phase prompt includes never rules as hard guardrails |
| Validate | Output checked against never rules |
| Finalize | Require_approval conditions generate resume contexts |

## Layer 2: Directives

Directives are runtime-created constraints that persist across pipeline runs. They are YAML files stored in the `directives/` directory. Humans create them via the resume interface or manually.

### Directive Types

#### Lock

Prevents changes to specific files or paths. Uses glob matching.

```yaml
type: "lock"
target: "src/auth/*"
rule: "Authentication module is frozen during security audit"
created: "2026-04-01T10:00:00Z"
source: "human-resume"
expires: "2026-04-15"
```

When a lock directive exists, the pipeline will not modify any file matching the target glob pattern.

#### Priority

Boosts (or deprioritizes) a specific category or topic.

```yaml
type: "priority"
target: "security"
rule: "+3"
created: "2026-04-01T10:00:00Z"
source: "human-resume"
expires: null
```

The rule field contains a numeric boost (e.g., `+3`, `-1`). This adjusts the priority score of proposals in the matching category during the strategize phase.

#### Constraint

Adds a global constraint that the pipeline must respect.

```yaml
type: "constraint"
target: "pipeline"
rule: "Do not modify any Docker container configurations this week"
created: "2026-04-01T10:00:00Z"
source: "human-circuit-breaker"
expires: "2026-04-08"
```

Constraints are included in phase prompts as additional rules the LLM must follow.

#### Override

Forces a specific decision for a particular change ID.

```yaml
type: "override"
target: "S-007"
rule: "approved"
created: "2026-04-01T10:00:00Z"
source: "human-resume"
expires: null
```

Override directives bypass the normal challenge process for a specific change, forcing the specified verdict.

### Directive Expiry

All directives have an `expires` field:
- A date string (`"2026-04-15"`) -- the directive is ignored after this date
- `null` -- the directive never expires (remains active until manually removed)

Expired directives are cleaned up during housekeeping.

### Creating Directives

Directives are created through:

1. **Resume interface** -- when reviewing a decision via `evolve resume <id>`, choosing "Directive" lets you create one interactively
2. **Circuit breaker review** -- when reviewing a circuit breaker trip, choosing "Directive" creates a constraint
3. **Manual file creation** -- write a YAML file directly to the `directives/` directory

### Directive Enforcement

```
directive_check_lock <directives_dir> <file_path>
  -> Returns 0 (locked) or 1 (not locked)
  -> Uses glob matching against the target field

directive_check_priority <directives_dir> <category>
  -> Returns the boost value or empty string

directive_check_override <directives_dir> <change_id>
  -> Returns the forced verdict or empty string

directive_get_constraints <directives_dir>
  -> Returns all active constraint rules as newline-separated text
```

## Layer 3: Challenge Phase

The challenge phase is an adversarial gating mechanism that reviews every proposal before implementation. It operates under strict information isolation -- it cannot read strategy rationale or proposal justifications, only the pool entries and affected files.

### 7 Core Attack Vectors

1. **Correctness** -- Will the change do what it claims?
2. **Blast Radius** -- What else could break?
3. **Reversibility** -- Can this be cleanly undone?
4. **Resource Impact** -- Will this exhaust RAM/disk/CPU?
5. **Conflict With Existing** -- Does this clash with other changes?
6. **Proportionality** -- Is the ambition score appropriate?
7. **Timing** -- Is now the right time for this change?

Plus genome-specific challenge vectors defined in `genome.yaml`.

### Verdicts

- **approved** -- all clear, proceed to implementation
- **weakened** -- concerns noted, ambition reduced by 1, extra care required
- **probation** -- serious concerns, gets one implementation attempt with no fix cycles
- **killed** -- too risky, change is terminated

### Approval Floor

The challenge phase must approve at least `approval_floor_pct` (default: 50%) of reviewed entries. If the kill rate exceeds this floor, the challenge phase must re-examine killed entries and potentially rescue some by reducing scope.

This prevents an overly aggressive challenge phase from blocking all progress.

## Layer 4: Circuit Breaker

The circuit breaker automatically pauses autonomous runs when too many changes produce negative impact signals.

### Configuration

```yaml
circuit_breaker:
  negative_impact_threshold: 3
  window_days: 7
  action: "pause"
  resume: "manual"
```

### How It Works

1. Every time a change receives a `negative` impact signal, it counts against the circuit breaker
2. When the count reaches `negative_impact_threshold` within the rolling `window_days`, the circuit breaker trips
3. A trip marker file (`circuit-breaker.trip`) is created
4. Subsequent autonomous runs check for this marker and refuse to start

### Resume Modes

- **manual** -- a human must review the situation and explicitly clear the trip via `evolve resume circuit-breaker`
- **auto** -- the trip clears automatically after the window expires

### Reviewing a Circuit Breaker Trip

```bash
evolve resume circuit-breaker
```

This shows:
- The trip information
- All negative-impact changes from the last 7 days
- A diagnostic summary

Actions available:
1. **Reset** -- clear the circuit breaker, allow pipeline to resume
2. **Directive** -- create a constraint to prevent recurrence
3. **Review** -- examine each negative-impact change individually
4. **Nothing** -- keep the circuit breaker tripped

## Layer 5: Reversibility Model

Every change must register its undo mechanism before executing. This is the last line of defense -- even if all other layers fail, changes can be rolled back.

### Primary Reversibility

The primary mechanism is defined in `genome.yaml`:

```yaml
reversibility:
  primary: "git"
```

Options:
- `git` -- changes are committed and can be reverted with `git revert`
- `snapshot` -- a filesystem snapshot is taken before changes
- `state-capture` -- custom state capture mechanism

### Side Effect Reversibility

Non-git changes (package installs, service modifications, cron changes) register their undo commands in a rollback manifest:

```yaml
reversibility:
  side_effects:
    - type: "apt"
      undo: "apt remove -y {package}"
    - type: "systemd"
      undo: "systemctl stop {service} && systemctl disable {service}"
    - type: "cron"
      undo: "crontab restore from backup"
```

### Rollback Manifest

The rollback manifest (`rollback-manifest.json`) tracks every side effect change:

```json
{
  "changes": [
    {
      "type": "apt",
      "package": "nginx",
      "undo": "apt remove -y nginx"
    },
    {
      "type": "systemd",
      "service": "nginx",
      "undo": "systemctl stop nginx && systemctl disable nginx"
    }
  ]
}
```

### Crash Recovery

If the pipeline crashes (ERR, INT, or TERM signal), the crash recovery handler:

1. Restores files from the pre-run git snapshot
2. Restores the crontab from backup
3. Executes every undo command in the rollback manifest
4. Sends a crash notification
5. Releases the global lock

### Temporary Exclusions

Some changes are inherently irreversible or have limited reversibility:
- Data migrations (data can be transformed but not un-transformed)
- External API calls (requests sent cannot be unsent)
- Published artifacts (cannot unpublish)

These should be flagged in the challenge phase under the "Reversibility" vector. The challenge phase can kill or weaken proposals with poor reversibility.

## Safety in Practice

### A Change's Journey Through Safety

1. **Analyze** -- proposal is created with safety rules in the prompt
2. **Challenge** -- adversarial review checks 7+ vectors including safety
3. **Directives** -- lock directives prevent touching frozen files; constraints add rules
4. **Implement** -- undo is registered before each modification; never rules in prompt
5. **Validate** -- health checks verify no regression; scoring measures impact
6. **Finalize** -- negative impact triggers revert; circuit breaker counts negatives
7. **Resume** -- human reviews all decisions, can create directives for future runs

### When Things Go Wrong

| Scenario | Protection Layer |
|---|---|
| Bad proposal | Challenge phase kills it |
| Change breaks something | Validate phase catches regression |
| Subtle degradation | Scoring produces negative impact signal |
| Repeated failures | Circuit breaker pauses autonomous runs |
| Crash during implementation | Crash recovery restores pre-run state |
| Human disagrees with decision | Resume interface allows override/redirect |
| Certain files must not be touched | Lock directive prevents changes |
| Category needs temporary freeze | Constraint directive blocks category |
