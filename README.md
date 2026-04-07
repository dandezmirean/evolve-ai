# evolve-ai

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests: 289 passing](https://img.shields.io/badge/tests-289%20passing-brightgreen.svg)](tests/)
[![Bash 4+](https://img.shields.io/badge/bash-4%2B-orange.svg)](#requirements)

Your test coverage is slipping. A config file drifted three weeks ago and nobody noticed. Your agent prompts could be tighter but there are forty of them and who has time. The security advisory RSS feed has been piling up unread.

You could audit, plan, implement, test, and rollback — every day — for every system you run. Or you could point evolve-ai at it and go do something else.

**evolve-ai is an autonomous improvement loop for anything you can describe.** Infrastructure, codebases, LLM agent systems, homelabs — define what "better" looks like and it handles the rest: scanning for gaps, proposing changes, adversarially challenging its own ideas, implementing the survivors, validating them, rolling back failures, and measuring impact. Daily, event-triggered, or both. Unattended, with full rollback safety and human re-entry at every decision point.

---

## See it work

Here is what a typical `evolve run` looks like against an infrastructure target:

```
$ ./bin/evolve run

[housekeeping] Cleaning workspaces older than 14 days... removed 2
[housekeeping] Git snapshot: evolve-2026-04-06-pre

[strategize] Reading memory + scanning target system...
[strategize] 3 improvement opportunities identified
  S01  (ambition 4) Harden SSH config: disable root login, add fail2ban
  S02  (ambition 2) Rotate expired TLS cert on reverse proxy
  S03  (ambition 1) Clean 4.2GB of stale Docker images

[analyze] Capturing KPI baselines...
  S01  baseline: ssh_audit_score=62/100, open_ports=7
  S02  baseline: cert_days_remaining=-3 (EXPIRED)
  S03  baseline: disk_used_pct=87%

[challenge] Adversarial review (7 vectors per proposal)
  S01  APPROVED  — attack surface reduction is clear, rollback via sshd_config backup
  S02  APPROVED  — cert renewal is low-risk, automated validation available
  S03  WEAKENED  — reduced scope: only prune images older than 30 days (was "all unused")

[implement] Executing 3 approved changes...
  S01  Registered undo: restore /etc/ssh/sshd_config from snapshot
        Applied hardened SSH config, installed fail2ban
  S02  Registered undo: restore previous cert files
        Renewed cert via certbot, reloaded nginx
  S03  Registered undo: n/a (Docker image prune is safe)
        Pruned 3.8GB of images older than 30 days

[validate] Running health checks + scoring...
  S01  PASS  ssh_audit_score=91/100 (+29), all services reachable
  S02  PASS  cert_days_remaining=89, HTTPS probe clean
  S03  PASS  disk_used_pct=72% (-15%)

[finalize] All 3 changes landed. Updating memory + changelog.
[metrics] Recorded 3 entries. Net impact: positive.

Resume contexts saved. Run `evolve resume` to review any decision.
Notification sent via Telegram.
```

Three problems found, challenged, fixed, validated, and documented — without you touching a terminal.

---

## Why evolve-ai?

"How is this different from a cron script? Or Dependabot? Or a linter?"

**It reasons about whether to act.** Every proposal goes through an adversarial challenge phase that tries to kill it with 7+ attack vectors before any code runs. Bad ideas die before they touch your system.

**It lets you re-enter any decision.** Every choice the pipeline makes produces a resume context. Disagree with something? Run `evolve resume <id>` and steer it interactively.

**It measures actual impact.** Four-layer scoring — automated metrics, LLM evaluation, KPI baselines, and your own custom checks — means every change is measured before and after. Negative impact triggers automatic rollback.

**It improves itself.** A meta-agent (outer loop) evaluates the pipeline's own performance weekly and tunes prompts, scoring weights, and source credibility. The system that improves your systems also improves itself.

**It rolls back first, asks questions later.** Every change must register its undo command before executing. If validation fails, the rollback is already staged.

This is not a linter, a dependency updater, or an alert system. It is an autonomous loop that observes, reasons, acts, validates, and learns — across any target you can describe.

---

## Quick start

```bash
git clone https://github.com/dandezmirean/evolve-ai.git
cd evolve-ai
./bin/evolve init
```

The init wizard walks you through target selection, LLM provider, notifications, safety rules, and scheduling. Then:

```bash
./bin/evolve run
```

That's it. Your first autonomous improvement cycle runs immediately.

### Requirements

- Bash 4+
- jq
- curl
- md5sum (coreutils)
- An LLM provider (Claude recommended)

---

## Who is this for

- **Homelab operators** who want their infrastructure audited and hardened while they sleep
- **Solo devs** maintaining services and codebases with no time for daily hygiene
- **Teams** that want autonomous code quality, test coverage, and dependency health
- **Anyone running LLM agent systems** who wants prompts, tools, and evaluations continuously tuned

---

## Architecture

evolve-ai runs two loops:

- **Inner loop** — the 8-phase pipeline runs daily (or on-demand), producing concrete changes
- **Outer loop** — the meta-agent runs weekly, evaluating pipeline health and tuning its own parameters

```
                        +---------------------------+
                        |       Meta-Agent          |
                        |  (weekly outer loop)      |
                        |  evaluates + tunes        |
                        +---------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------+
|                     Inner Pipeline (daily)                             |
|                                                                       |
|  [digest] -> [strategize] -> [analyze] -> [challenge]                 |
|                                               |                       |
|                                     +---------+---------+             |
|                                     |                   |             |
|                                  approved            killed           |
|                                     |                                 |
|                              +------v------+                          |
|                              | implement   |<--+                      |
|                              +------+------+   |                      |
|                                     |          |                      |
|                              +------v------+   |                      |
|                              |  validate   |---+ (fix cycle)          |
|                              +------+------+                          |
|                                     |                                 |
|                              +------v------+                          |
|                              |  finalize   |                          |
|                              +------+------+                          |
|                                     |                                 |
|                              +------v------+                          |
|                              |   metrics   |                          |
|                              +-------------+                          |
+-----------------------------------------------------------------------+
```

### Project structure

```
evolve-ai/
  bin/evolve                  CLI entry point
  core/
    orchestrator.sh           Pipeline sequencing + crash recovery
    pool.sh                   Pool state machine (JSON via jq)
    phases/                   8 phase prompt templates
    scoring/                  Four-layer scoring engine
    memory/                   Persistent cross-run state (7 memory files)
    lens/                     Lens engine + concern-based feed adapters (rss, command, manual, webhook)
    inbox/                    Reactive inbox watcher + manifest tracking
    resume/                   Human re-entry context system
    notifications/            Telegram, Slack, Discord, stdout
    providers/                LLM provider abstraction (Claude, OpenAI)
    rollback/                 Reversibility engine + undo handlers
    meta/                     Outer loop evaluator
  genomes/                    Target genomes (infrastructure, codebase, agent-harness)
  config/evolve.yaml          Runtime configuration (generated by init)
  tests/                      Test suite (289 tests)
  docs/                       Full documentation
```

See [docs/architecture.md](docs/architecture.md) for the complete design breakdown.

---

## CLI commands

| Command | Description |
|---|---|
| `evolve init` | Interactive setup wizard |
| `evolve run` | Run the autonomous pipeline |
| `evolve run --directed` | Run in directed mode (process inbox items) |
| `evolve status` | Show pool stats, lock status, next scheduled run |
| `evolve history` | Print the changelog |
| `evolve resume` | List available resume contexts |
| `evolve resume <id>` | Resume an interrupted run interactively |
| `evolve genome list` | List available genomes |
| `evolve genome create <name>` | Create a new genome conversationally |
| `evolve meta run` | Run the meta-agent evaluation |
| `evolve meta status` | Show last meta evaluation report |
| `evolve config` | Show current configuration |
| `evolve version` | Print version string |

---

## Genomes

A genome encodes the complete identity definition for a target system — scan commands, health checks, lens concerns (intelligence gathering), scoring rules, safety constraints, and rollback strategies. It is the DNA that tells evolve-ai how to evolve that target.

**Built-in genomes:**

- **infrastructure** — servers, homelabs, services, security, monitoring
- **agent-harness** — LLM agents, prompts, tools, evaluation harnesses
- **codebase** — software projects, code quality, test coverage, dependencies

**Custom genomes:** Run `evolve genome create my-target` and describe what you want to evolve in plain language. Or choose the `[+]` option during `evolve init`.

See [docs/creating-genomes.md](docs/creating-genomes.md) for the full genome authoring guide.

---

## Documentation

- [Getting Started](docs/getting-started.md) — installation, first run, scheduled runs
- [Architecture](docs/architecture.md) — two-loop design, phase flow, configuration reference
- [Creating Genomes](docs/creating-genomes.md) — custom genome authoring guide
- [Scoring Guide](docs/scoring-guide.md) — four-layer scoring system explained
- [Safety Model](docs/safety-model.md) — safety rules, directives, circuit breaker

---

## Contributing

evolve-ai is MIT-licensed and contributions are welcome.

- **Star the repo** if you find this useful — it helps others discover it
- **File an issue** for bugs, feature requests, or questions
- **Contribute a genome** — the best way to expand what evolve-ai can improve
- **Check the docs** — especially the [architecture](docs/architecture.md) and [genome creation](docs/creating-genomes.md) guides before diving in

---

## License

[MIT](LICENSE)
