# Architecture

## Two-Loop Design

evolve-ai operates two independent loops:

### Inner Loop (Daily Pipeline)

The 8-phase pipeline runs once per day (or on-demand via `evolve run`). Each phase is powered by an LLM invocation with a phase-specific prompt template, operating within a workspace directory that contains the run's state.

### Outer Loop (Meta-Agent)

The meta-agent runs weekly. It reads accumulated metrics, evaluates pipeline health across 4 dimensions, and generates proposals to tune the inner loop's parameters. It cannot modify safety rules or its own evaluation prompt.

```
                    +-------------------------------+
                    |          Meta-Agent           |
                    |                               |
                    |  Pipeline Health              |
                    |  Scoring Calibration          |
                    |  Source Effectiveness          |
                    |  Strategic Drift              |
                    |                               |
                    |  CAN tune:                    |
                    |    - Turn budgets             |
                    |    - Scoring weights          |
                    |    - Source priorities         |
                    |    - Challenge floor          |
                    |                               |
                    |  CANNOT touch:                |
                    |    - Safety rules             |
                    |    - Genome identity           |
                    |    - Circuit breaker          |
                    |    - Its own prompt           |
                    +-------------------------------+
                                |
              reads metrics.jsonl, source-credibility.jsonl
                                |
    +----------------------------------------------------------+
    |                                                          |
    |                    Inner Pipeline                        |
    |                                                          |
    |   Autonomous mode:                                       |
    |   strategize -> analyze -> challenge -> impl loop        |
    |                                                          |
    |   Directed mode (inbox-triggered):                       |
    |   digest -> strategize -> analyze -> challenge -> impl   |
    |                                                          |
    +----------------------------------------------------------+
```

## Phase Flow

### Autonomous Mode

```
  +-------------+     +-------------+     +-------------+
  | strategize  | --> |   analyze   | --> |  challenge  |
  +-------------+     +-------------+     +------+------+
                                                 |
                           +---------------------+-----+
                           |                           |
                       approved/weakened            killed
                           |                       (terminal)
                    +------v------+
                    |  implement  |<------+
                    +------+------+       |
                           |              |
                    +------v------+       |
                    |  validate   |-------+ (fix cycle if failing)
                    +------+------+
                           |
                    +------v------+
                    |  finalize   |  land / revert / kill
                    +------+------+
                           |
                    +------v------+
                    |   metrics   |  record 17-field entries
                    +-------------+
```

### Directed Mode (Inbox-Triggered)

Prepends a **digest** phase that processes incoming inbox items before the normal pipeline flow.

### Phase Descriptions

| Phase | Purpose |
|---|---|
| **digest** | Process inbox items: research, feasibility check, vision alignment filter |
| **strategize** | Scan target system, read memory, identify improvement opportunities |
| **analyze** | Deep-dive into opportunities, establish KPI baselines, populate pool |
| **challenge** | Adversarial review with 7+ attack vectors; approve, weaken, or kill |
| **implement** | Execute approved changes with undo registration |
| **validate** | Run health checks, scoring, regression tests |
| **finalize** | Decide: land, revert, or fix-cycle each change; update memory |
| **metrics** | Record 17-field metrics per entry, generate resume contexts |

## Pool State Machine

The pool (`pool.json`) tracks every proposed change through its lifecycle. Each entry has a `status` field that follows this state machine:

```
                                +----> killed (terminal)
                                |
  pending --+--> probation -----+
            |                   |
            +--> approved ------+--> implemented --+--> landed (terminal)
            |                                      |
            +--> weakened                           +--> landed-pending-kpi (terminal)
            |   (stays pending                     |
            |    with reduced ambition)             +--> reverted (terminal)
            |                                      |
            +----> killed (terminal)               +--> fix-cycle -> implemented
                                                         (back to validate)
```

Terminal states: `landed`, `landed-pending-kpi`, `reverted`, `killed`

The implementation loop repeats until convergence -- all pool entries reach a terminal state, or the max stalls/iterations limit is hit.

### Convergence Detection

After each implementation loop iteration, the orchestrator computes an MD5 hash of all `id:status` pairs in the pool. If the hash matches the previous iteration's hash, it counts as a "stall." After `max_stalls` (default: 3) consecutive stalls, the pipeline forces a final finalize and stops.

The `max_iterations` setting (default: 10) provides a hard upper bound.

## File/Directory Structure

### Runtime Directories (gitignored)

| Path | Purpose |
|---|---|
| `workspace/YYYY-MM-DD/` | Per-run workspace with pool.json and phase artifacts |
| `memory/` | Persistent memory files (changelog, metrics, vision, etc.) |
| `inbox/pending/` | Incoming intelligence items awaiting processing |
| `inbox/processed/` | Processed inbox items |
| `inbox/.manifest.json` | MD5-based manifest tracking processed files |
| `resume-context/YYYY-MM-DD/` | Resume context files for human review |
| `directives/` | Active directive YAML files |
| `meta/` | Meta-agent reports and proposals |

### Core Modules

| Module | File | Responsibility |
|---|---|---|
| Orchestrator | `core/orchestrator.sh` | Phase sequencing, convergence loop, crash recovery |
| Pool | `core/pool.sh` | JSON state machine via jq -- add, transition, query, hash |
| Config | `core/config.sh` | YAML parser producing flat key=value pairs |
| Lock | `core/lock.sh` | PID-based global lock with stale detection |
| Housekeeping | `core/housekeeping.sh` | Workspace cleanup, git tag pruning, pre-run snapshots |
| Resources | `core/resources.sh` | RAM and disk gate checks |
| Init | `core/init.sh` | Interactive init wizard |
| Scoring | `core/scoring/engine.sh` | Four-layer scoring: heuristic, LLM judge, KPI, user-defined |
| Metrics | `core/scoring/metrics.sh` | Metrics recording, weekly digest, category stats |
| Memory | `core/memory/manager.sh` | Memory file CRUD, changelog pruning, metrics append |
| Notifications | `core/notifications/engine.sh` | Multi-provider notification routing |
| Providers | `core/providers/interface.sh` | LLM provider dispatch and usage logging |
| Inbox | `core/inbox/watcher.sh` | Polling inbox watcher, one-shot check |
| Manifest | `core/inbox/manifest.sh` | MD5-based change detection for inbox items |
| Sources | `core/inbox/source-runner.sh` | Source adapter dispatch (RSS, command, manual, webhook) |
| Resume | `core/resume/context-generator.sh` | Generate resume context markdown files |
| Resume Runner | `core/resume/resume-runner.sh` | Interactive resume session with 6 action types |
| Directives | `core/directives/manager.sh` | CRUD for lock/priority/constraint/override directives |
| Meta-Agent | `core/meta/meta-agent.sh` | Outer loop: 4 evaluation dimensions + proposals |
| Genomes | `core/genomes/validator.sh` | Genome schema validation, loading, listing |

## How Phases Interact

### Data Flow

Each phase reads from and writes to the workspace directory and memory:

```
  Inbox items --> digest --> pool.json (new entries)
                              |
  Memory + scan data --> strategize --> strategy-notes.md
                              |
  Strategy notes --> analyze --> pool.json (entries added/updated)
                              |
  Pool entries --> challenge --> pool.json (verdicts applied)
                              |
  Approved entries --> implement --> changed files + undo manifest
                              |
  Changed files --> validate --> pool.json (pass/fail)
                              |
  Validated entries --> finalize --> pool.json (terminal states)
                              |                   |
                              v                   v
                        memory/changelog    resume-context/
                              |
  Settled entries --> metrics --> memory/metrics.jsonl
```

### Phase Isolation

The challenge phase operates under strict information isolation. It cannot read strategy notes or proposal rationale -- only the pool entries and affected files. This prevents confirmation bias.

### Resource Gates

Before every phase, the orchestrator checks RAM and disk gates. If either gate fails, the phase returns exit code 2 and the pipeline halts gracefully (releasing the lock and skipping further phases).

## Configuration Reference

The configuration file `config/evolve.yaml` is generated by `evolve init`. All values can be edited manually after initialization.

### Top-Level Keys

```yaml
version: "1.0.0"          # Config schema version
created: "2026-04-06"     # Date of init

targets:                   # What to evolve
  - genome: "infrastructure" # Genome name (matches genomes/ directory)
    root: "/home/user"     # Root directory of the target system
    weight: 1              # Relative priority weight

provider:
  type: "claude-max"       # LLM provider: claude-max, claude-api, openai

notifications:             # Where to send results
  - type: "stdout"         # Provider: stdout, telegram, slack, discord
```

### Schedule

```yaml
schedule:
  autonomous: "0 13 * * *"      # Cron expression for autonomous runs
  inbox_poll_seconds: 300        # Inbox polling interval
  meta_agent: "0 13 * * 0"      # Cron expression for meta-agent
```

### Resources

```yaml
resources:
  min_free_ram_mb: 1500          # Minimum free RAM (MB) before running
  max_disk_usage_pct: 85         # Maximum disk usage (%) before running
```

### Circuit Breaker

```yaml
circuit_breaker:
  negative_impact_threshold: 3   # Negative signals before tripping
  window_days: 7                 # Rolling window
  action: "pause"                # What to do: pause
  resume: "manual"               # How to resume: manual, auto
```

### Retention

```yaml
retention:
  workspace_days: 14             # Delete workspaces older than N days
  git_tag_days: 30               # Delete evolve-* tags older than N days
  changelog_archive_days: 90     # Move old changelog entries to archive
```

### Convergence

```yaml
convergence:
  max_stalls: 3                  # Consecutive stalls before stopping
  max_iterations: 10             # Hard upper bound on impl loop iterations
```

### Validation

```yaml
validation:
  tier3_min_free_ram_mb: 1500    # RAM threshold for tier-3 validation
  sub_invocation_timeout_seconds: 300  # Timeout for sub-invocations
  regression_check_count: 20     # Number of regression checks
  regression_lookback_days: 30   # How far back to look for regressions
```

### Challenge

```yaml
challenge:
  approval_floor_pct: 50         # Minimum approval rate (%)
```

### Meta-Agent

```yaml
meta_agent:
  enabled: false                 # Set to true to enable meta evaluations
```

### Pipeline

```yaml
pipeline:
  phases:                        # Phase execution order
    - "digest"
    - "strategize"
    - "analyze"
    - "challenge"
    - "implement"
    - "validate"
    - "finalize"
    - "metrics"
```

## Crash Recovery

If the pipeline crashes (ERR, INT, or TERM signal), the orchestrator's trap handler:

1. Restores files from the pre-run git snapshot tag (`evolve-YYYY-MM-DD-pre`)
2. Restores the crontab from `crontab.bak`
3. Executes the rollback manifest (undo commands for each change)
4. Sends a crash notification
5. Releases the global lock

This ensures the system returns to its pre-run state after any failure.
