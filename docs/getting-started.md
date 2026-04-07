# Getting Started

This guide walks you through installing evolve-ai, running the init wizard, executing your first pipeline run, and setting up recurring automation.

## Prerequisites

- **Bash 4+** -- check with `bash --version`
- **jq** -- JSON processor; install with `apt install jq` or `brew install jq`
- **curl** -- for RSS source fetching; usually pre-installed
- **md5sum** -- from coreutils; usually pre-installed
- **git** -- for snapshot/recovery; usually pre-installed
- **An LLM provider** -- Claude via claude.ai Max plan (recommended), Claude API, or OpenAI-compatible API

### Optional

- **cron** -- for scheduled autonomous runs
- **Telegram/Slack/Discord** -- for notifications

## Installation

```bash
git clone https://github.com/dandezmirean/evolve-ai.git
cd evolve-ai
```

No build step required. The entire framework is pure bash.

Optionally, add the bin directory to your PATH:

```bash
export PATH="$PATH:$(pwd)/bin"
```

## First Init Walkthrough

Run the init wizard:

```bash
./bin/evolve init
```

The wizard guides you through 9 configuration steps:

### Step 1: Select Genomes

```
What are you evolving? (select all that apply, or describe your own)
  [1] Infrastructure (server, homelab, services)
  [2] Agent harness (LLM agents, prompts, tools)
  [3] Codebase (software project)
  [+] Describe something else...
```

Pick a number, or choose `+` to describe your target in plain language. evolve-ai will generate a custom genome from your description using the genome template.

You can select multiple genomes by comma-separating: `1,3` for both infrastructure and codebase.

### Step 2: Target Root Directories

For each selected genome, specify the root directory of the system being evolved. For infrastructure this defaults to `$HOME`; for codebase it defaults to `.` (current directory).

### Step 3: LLM Provider

Choose which LLM powers the pipeline:
- **Claude via claude.ai** (recommended) -- uses your Max subscription, no API key needed
- **Claude via API key** -- metered billing
- **OpenAI-compatible API** -- any OpenAI-compatible endpoint
- **Custom provider** -- bring your own

### Step 4: Notifications

Where should results be sent?
- Terminal output (default)
- Telegram bot
- Slack webhook
- Discord webhook
- Multiple channels

### Step 5: Lens Concerns

Each genome comes with suggested lens concerns (security posture, resource drift, etc.), each with automated feeds (RSS, commands). Accept the defaults or defer customization to post-init editing.

### Step 6: Resource Constraints

evolve-ai detects your system's RAM and disk. You set thresholds:
- **Min free RAM** -- phases will not run if free RAM drops below this (default: 1500MB)
- **Max disk usage** -- phases will not run if disk usage exceeds this (default: 85%)

### Step 7: Safety Rules

Each genome defines safety rules (things the pipeline must never do). Review and accept them, or defer customization.

### Step 8: Schedule

Set cron expressions for:
- **Autonomous runs** -- when the pipeline runs unattended (default: daily at 1 PM)
- **Inbox polling** -- how often to check for new items (default: every 300 seconds)
- **Meta-agent** -- when the outer loop runs (default: weekly on Sunday)

### Step 9: Circuit Breaker

Configure the safety net that pauses autonomous runs if too many changes produce negative impacts:
- **Threshold** -- how many negative signals before tripping (default: 3)
- **Window** -- time window in days (default: 7)
- **Resume mode** -- `manual` (human must clear) or `auto` (clears after window expires)

After completing all steps, the wizard generates:
- `config/evolve.yaml` -- your configuration
- `memory/` -- initialized memory files from templates
- `inbox/` -- inbox directory structure

## Your First Manual Run

```bash
./bin/evolve run
```

This triggers a full autonomous pipeline cycle. On the first run with no lens feeds populated, the pipeline will likely:

1. Scan your system state
2. Identify a few improvement opportunities
3. Challenge them adversarially
4. Implement the approved ones
5. Validate the changes
6. Record metrics

Watch the terminal output for `[orchestrator]` messages showing phase progression.

## Understanding the Output

After a run completes, you will find:

- **`workspace/YYYY-MM-DD/`** -- the run's workspace directory containing:
  - `pool.json` -- all proposals and their final statuses
  - Phase artifacts (strategy notes, challenge reports, etc.)
  - Score files under `scores/`
- **`memory/changelog.md`** -- updated with landed/reverted changes
- **`memory/metrics.jsonl`** -- one JSON line per settled entry
- **`resume-context/YYYY-MM-DD/`** -- resume context files for each decision

Check the run status:

```bash
./bin/evolve status
```

View the changelog:

```bash
./bin/evolve history
```

Review decisions interactively:

```bash
./bin/evolve resume          # list available contexts
./bin/evolve resume <id>     # review a specific decision
```

## Setting Up Scheduled Runs

### Using cron

Add evolve-ai to your crontab:

```bash
crontab -e
```

Add a line matching your configured schedule (default: daily at 1 PM):

```
0 13 * * * /path/to/evolve-ai/bin/evolve run >> /path/to/evolve-ai/run.log 2>&1
```

For the meta-agent (weekly on Sunday at 1 PM):

```
0 13 * * 0 /path/to/evolve-ai/bin/evolve meta run >> /path/to/evolve-ai/meta.log 2>&1
```

### Using systemd timer

Create a service file at `/etc/systemd/system/evolve-ai.service`:

```ini
[Unit]
Description=evolve-ai autonomous pipeline run

[Service]
Type=oneshot
User=your-user
WorkingDirectory=/path/to/evolve-ai
ExecStart=/path/to/evolve-ai/bin/evolve run
```

And a timer at `/etc/systemd/system/evolve-ai.timer`:

```ini
[Unit]
Description=Run evolve-ai daily

[Timer]
OnCalendar=*-*-* 13:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable it:

```bash
sudo systemctl enable --now evolve-ai.timer
```

## Adding Lens Concerns

Lens concerns define what your genome watches for, organized by topic rather than delivery mechanism. Each concern can have multiple feeds.

### RSS Feeds

Add RSS feeds to a concern in your genome's `genome.yaml`:

```yaml
lens:
  concerns:
    - name: "security-posture"
      description: "Vulnerabilities and advisories"
      feeds:
        - type: "rss"
          url: "https://www.debian.org/security/dsa"
          schedule: "daily"
          description: "Debian security advisories"
      accepts_inbox: true
      research_on_arrival: true
```

### Command Output

Run shell commands as feeds within a concern:

```yaml
lens:
  concerns:
    - name: "service-health"
      description: "Service status and errors"
      feeds:
        - type: "command"
          command: "journalctl --since='24 hours ago' --priority=err --no-pager -q"
          schedule: "daily"
          description: "System error log review"
```

### Manual Drops

Drop files into a concern's inbox directory:

```bash
echo "Consider adding log rotation for nginx" > inbox/service-health/pending/nginx-logs.txt
```

The inbox watcher picks these up and triggers a directed run. Any concern with `accepts_inbox: true` accepts human drops.

### Webhooks

The webhook adapter listens for HTTP POST requests. Configure a concern with `accepts_agents: true` and start the webhook listener separately.

## Customizing Safety Rules

Safety rules live in each genome's `genome.yaml` under `safety_rules`:

```yaml
safety_rules:
  never:
    - "expose ports to public internet"
    - "delete data without backup"
  require_approval:
    - condition: "ambition >= 5"
```

The `never` list contains absolute prohibitions -- the pipeline will never execute changes that violate these.

The `require_approval` list contains conditions that trigger the creation of resume contexts for human review before execution.

You can also create runtime directives that add temporary safety constraints. See [Safety Model](safety-model.md) for details.

## Next Steps

- [Architecture](architecture.md) -- understand the two-loop design and phase interactions
- [Creating Genomes](creating-genomes.md) -- build a custom genome
- [Scoring Guide](scoring-guide.md) -- configure how changes are measured
- [Safety Model](safety-model.md) -- understand safety rules, directives, and circuit breaker
