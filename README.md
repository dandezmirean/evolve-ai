# evolve-ai

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests: 317 passing](https://img.shields.io/badge/tests-317%20passing-brightgreen.svg)](tests/)
[![Bash 4+](https://img.shields.io/badge/bash-4%2B-orange.svg)](#requirements)

Your test coverage is slipping. A config file drifted three weeks ago and nobody noticed. Your agent prompts could be tighter but there are forty of them and who has time. The security advisory RSS feed has been piling up unread.

You could audit, plan, implement, test, and rollback — every day — for every system you run. Or you could point evolve-ai at it and go do something else.

**evolve-ai is an autonomous improvement loop for anything you can describe.** Infrastructure, codebases, LLM agent systems, homelabs — define what "better" looks like and it handles the rest: scanning for gaps, proposing changes, adversarially challenging its own ideas, implementing the survivors, validating them, rolling back failures, and measuring impact. Daily, event-triggered, or both. Unattended, with full rollback safety and human re-entry at every decision point.

---

## The organism

evolve-ai is modeled after a living organism. Each component has a biological analog — understanding the metaphor is understanding the system.

**Genome** — The DNA. A genome encodes everything evolve-ai needs to know about a target system: how to scan it, what healthy looks like, what's off-limits, how to measure improvement, and how to undo mistakes. You don't tell evolve-ai *what to do* — you give it a genome and it figures out the rest. Ships with three: infrastructure, codebase, and agent-harness. You can breed your own by describing a target in plain language.

**Lens** — The sensory organs. Each genome has a lens that defines how the organism perceives the outside world. A lens is organized by **concerns** — security posture, dependency health, resource drift — not by what protocol delivers the data. A single concern can see through multiple channels simultaneously: RSS feeds, shell commands, human file drops, agent pushes. The concern is the sense; the feed is just the nerve ending.

**Pool** — The bloodstream. Every proposed change enters the pool and flows through the pipeline. The pool is a JSON state machine that tracks each proposal from birth (`pending`) through trial (`implemented`, `validated`) to fate (`landed`, `reverted`, or `killed`). Nothing happens outside the pool. Nothing is forgotten. Pool state is validated (jq) before each convergence loop iteration — malformed JSON halts the pipeline.

**Challenge** — The immune system. Before any proposal touches the target system, it faces an adversarial review. The challenge phase operates in isolation — it cannot see the reasoning that created the proposal. It attacks with 7+ vectors: speculative benefit, blast radius, scope creep, resource feasibility, track record. Bad ideas are killed before they infect the host.

**Finalize** — Natural selection. After implementation and validation, finalize decides what survives. Changes with positive impact land. Changes that cause harm are reverted. Changes that fail repeatedly are killed. The strong persist; the weak are culled.

**Memory** — Long-term memory. The organism remembers what it learned across runs: what landed, what failed, what patterns repeat, what strategic direction it's heading. Seven memory files persist facts, changelog, vision, strategy history, impact observations, and structured metrics. Phases read memory before acting — the organism learns from its past.

**Resume context** — Consciousness. Every decision the pipeline makes produces a re-enterable context file. A human can inhabit any decision point after the fact: override a kill, redirect a proposal, expand research, or inject a new rule. The organism acts autonomously, but a human can always step inside its mind.

**Directives** — Instincts. Persistent rules encoded from experience. A resume session might produce a directive: "never touch auth files," "prioritize security for the next 5 runs," "this category requires approval." Directives shape future behavior without requiring the human to be present when they fire.

**Circuit breaker** — The pain reflex. If three or more changes produce negative impact within seven days, the organism halts. It stops proposing, sends a diagnostic report, and waits for a human to investigate. Evolution is relentless, but self-destruction is not evolution.

**Meta-agent** — The evolutionary pressure on the organism itself. A weekly outer loop that evaluates the pipeline's own fitness: Are phases spending turns well? Is scoring calibrated? Are intelligence sources credible? Is the system avoiding hard problems? The meta-agent tunes the inner loop's parameters — the organism that improves your systems also improves itself.

**Scoring** — The nervous system. Four layers of feedback measure every change: heuristic metrics (automated numbers), LLM-as-judge (qualitative evaluation), KPI baselines (before/after measurement), and user-defined checks. Signals propagate back through every phase — strategize learns what categories succeed, challenge learns what to doubt, finalize learns when to trust.

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

A directed run works the same way, but starts with the lens gathering intelligence from your concerns:

```
$ echo "CVE-2026-1234 affects openssl 3.x" > inbox/security-posture/pending/cve-note.txt
$ ./bin/evolve run --directed

[lens] Gathering intelligence from 3 concerns...
  security-posture:  1 new item (human drop), 2 feed items (RSS + error log)
  resource-drift:    1 feed item (daily snapshot)
  service-health:    0 new items

[digest] Processing 4 items across 2 concerns...
  I-001  RESEARCH_PASS  (security-posture) OpenSSL CVE — upgrade path available
  I-002  RESEARCH_DROP  (security-posture) Error log noise — no actionable pattern
  I-003  RESEARCH_PASS  (resource-drift)   Disk at 88% — cleanup candidate

[strategize] ...
```

---

## Why evolve-ai?

"How is this different from a cron script? Or Dependabot? Or a linter?"

**It reasons about whether to act.** Every proposal goes through an adversarial challenge phase that tries to kill it with 7+ attack vectors before any code runs. Bad ideas die before they touch your system.

**It lets you re-enter any decision.** Every choice the pipeline makes produces a resume context. Disagree with something? Run `evolve resume <id>` and steer it interactively.

**It measures actual impact.** Four-layer scoring — automated metrics, LLM evaluation, KPI baselines, and your own custom checks — means every change is measured before and after. Negative impact triggers automatic rollback. Validation uses a 3-tier model: static checks, functional verification, and resource-gated intelligent adversarial review.

**It improves itself.** A meta-agent (outer loop) evaluates the pipeline's own performance weekly and tunes prompts, scoring weights, and source credibility. The system that improves your systems also improves itself.

**It perceives through lenses, not dumb feeds.** Each genome defines a lens — a set of concerns it watches for (security posture, dependency health, resource drift). A concern can pull from multiple feeds, accept human file drops, receive agent pushes, and trigger deep web research. Intelligence is organized by *what matters*, not by what protocol delivered it.

**It rolls back first, asks questions later.** Every change must register its undo command before executing. If validation fails, the rollback is already staged.

This is not a linter, a dependency updater, or an alert system. It is an autonomous loop that perceives, reasons, acts, validates, and learns — across any target you can describe.

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
- An LLM provider

### LLM provider

evolve-ai is LLM-agnostic — it works with any provider that can take a prompt and return structured text. That said, the pipeline is compute-hungry. Each run invokes the LLM 8+ times across phases, and complex targets can run 20+ invocations per cycle with sub-invocations for validation and scoring. The more capable the model and the more generous the rate limits, the better the results.

The recommended setup is **Claude with a Max plan** — unlimited use on the most capable model, no per-token billing, and rate limits that comfortably handle daily autonomous runs. During `evolve init`, select "Claude via claude.ai (Max plan)" as your provider and authenticate via `claude.ai` OAuth. No API key needed.

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
|  +-------+                                                            |
|  | LENS  |  RSS feeds, commands, agent pushes, human drops            |
|  | per-  |  organized by concern (security, deps, drift...)           |
|  | genome|---> inbox-diff.txt                                         |
|  +-------+          |                                                 |
|                     v                                                 |
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
    lens/                     Concern-based intelligence gathering (pre-digest)
      engine.sh               Lens orchestration — run concerns, gather pending items
      feed-runner.sh          Feed dispatch (RSS, command, webhook, manual)
      adapters/               Pluggable feed adapters
    scoring/                  Four-layer scoring engine
    memory/                   Persistent cross-run state (7 memory files)
    inbox/                    Per-concern inbox watcher + manifest tracking
    resume/                   Human re-entry context system
    directives/               Persistent rules (lock, priority, constraint, override); lock files include timestamps for automatic stale detection (cleared after 2 hours)
    notifications/            Telegram, Slack, Discord, stdout
    providers/                LLM provider abstraction (Claude, OpenAI)
    meta/                     Outer loop evaluator
  genomes/                    Target genomes (infrastructure, codebase, agent-harness)
  config/evolve.yaml          Runtime configuration (generated by init)
  tests/                      Test suite (317 tests)
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

## Lenses

A lens is how a genome perceives the outside world. Instead of configuring a flat list of RSS feeds and shell commands, you define **concerns** — the things your genome needs to watch for. Each concern can pull intelligence from multiple channels simultaneously.

```yaml
lens:
  concerns:
    - name: "security-posture"
      description: "Vulnerabilities, advisories, exposure changes"
      feeds:
        - type: "rss"
          url: "https://security-tracker.debian.org/..."
          schedule: "daily"
        - type: "command"
          command: "journalctl --priority=err --since='24h ago' -q"
          schedule: "daily"
      accepts_inbox: true       # humans can drop files here
      accepts_agents: true      # other systems can push here
      research_on_arrival: true # new items trigger deep web research
```

**Why concerns instead of source types?** A security advisory could arrive via RSS, via a webhook from a scanner, via a human pasting a CVE, or via another agent. Four protocols, same intelligence need. The concern is what matters — the delivery mechanism is just plumbing.

Each concern gets its own inbox directory (`inbox/security-posture/pending/`). Drop a file in and the lens routes it to the right context automatically. The directory is the tag.

The infrastructure genome ships with concerns for security posture, resource drift, and service health. The codebase genome watches for dependency health, code quality, and ecosystem changes. Or define your own — every genome gets its own lens.

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
