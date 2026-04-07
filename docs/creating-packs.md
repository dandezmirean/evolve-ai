# Creating Target Packs

A target pack tells evolve-ai what system it is evolving and how to interact with it. This guide covers the pack manifest schema, creating packs from scratch, and using conversational generation.

## Pack Manifest Schema

Every pack is a directory under `packs/` containing a `pack.yaml` file. Here is the complete schema with all fields explained:

### name (required)

Short identifier for the pack. Lowercase, hyphens allowed.

```yaml
name: "my-homelab"
```

### description (required)

One-line summary of what this pack evolves.

```yaml
description: "Evolve a Proxmox-based homelab with 5 VMs and a NAS"
```

### scan_commands (required)

Shell commands that gather current state about the target system. These run during the digest and strategize phases to build situational awareness.

```yaml
scan_commands:
  - "free -h"
  - "df -h /"
  - "docker ps --format json 2>/dev/null || true"
  - "systemctl list-units --state=running --type=service --no-pager"
```

Guidelines:
- Commands should be read-only (no side effects)
- Use `2>/dev/null || true` for commands that might not exist on all systems
- Keep the list focused -- 4-8 commands is typical

### health_checks (required)

Commands that verify the target is in a good state. Run before and after changes to detect regressions.

```yaml
health_checks:
  - name: "system_responsive"
    command: "uptime"
    expect: "exit_code_0"
  - name: "disk_ok"
    command: "df / --output=pcent | tail -1 | tr -d ' %'"
    expect: "output_matches"
    value: "^[0-8][0-9]?$"
```

Fields per check:
- `name` -- identifier for the check
- `command` -- shell command to run
- `expect` -- validation mode: `exit_code_0` (command must succeed) or `output_matches` (output must match regex)
- `value` -- regex pattern (only used with `output_matches`)

### sources

Intelligence feeds that inform the strategize and digest phases. Each source has a type that determines which adapter processes it.

```yaml
sources:
  - name: "security-advisories"
    type: "rss"
    schedule: "daily"
    url: "https://example.com/feed.xml"
    description: "OS security advisories"
  - name: "error-log-review"
    type: "command"
    schedule: "daily"
    command: "journalctl --since='24 hours ago' --priority=err --no-pager -q"
    description: "System error log review"
  - name: "manual-inbox"
    type: "manual"
    schedule: "hourly"
    watch_dir: "/path/to/inbox"
    description: "Manual file drops"
```

Source types:
- `rss` -- fetches an RSS/Atom feed URL; requires `url`
- `command` -- runs a shell command; requires `command`
- `manual` -- watches a directory for new files; requires `watch_dir`
- `webhook` -- listens for HTTP POST requests (runs as a separate process)

Schedule values: `hourly`, `daily`, `weekly`

### gap_framework

Dimensions the agent evaluates for improvement opportunities. These guide the strategize phase's search for gaps.

```yaml
gap_framework:
  - "monitored_conditions"
  - "automated_responses"
  - "failure_recovery"
  - "security_posture"
  - "resource_efficiency"
```

### observation_types

Categories of issues the agent looks for during analysis.

```yaml
observation_types:
  - "service_failures"
  - "resource_spikes"
  - "cron_errors"
  - "stale_configs"
```

### scorers (required via heuristic section)

Metrics that quantify target health before and after changes.

```yaml
scorers:
  heuristic:
    - name: "memory_available_pct"
      command: "free | awk '/Mem:/ {printf \"%.0f\", $7/$2*100}'"
      weight: 3
      direction: "higher_is_better"
    - name: "failed_services"
      command: "systemctl --failed --no-pager --no-legend | wc -l"
      weight: 3
      direction: "lower_is_better"
  llm_judge:
    enabled: true
    prompt: "Evaluate whether this change improves reliability and efficiency. Score 0.0-1.0."
```

Heuristic scorer fields:
- `name` -- identifier
- `command` -- must output a single number to stdout
- `weight` -- relative importance (integer, typically 1-5)
- `direction` -- `higher_is_better` or `lower_is_better`

LLM judge fields:
- `enabled` -- `true` or `false`
- `prompt` -- the evaluation prompt sent to the LLM along with the change diff

See [Scoring Guide](scoring-guide.md) for full scoring system documentation.

### safety_rules (required)

Hard constraints on what the agent must never do.

```yaml
safety_rules:
  never:
    - "expose ports to public internet"
    - "disable firewall or security services"
    - "delete data volumes or databases"
    - "store credentials in plain text"
  require_approval:
    - condition: "category == 'security-config'"
    - condition: "ambition >= 5"
```

The `never` list contains absolute prohibitions. The challenge phase will kill any proposal that violates these. The `require_approval` list triggers human review via resume contexts.

### reversibility (required)

How changes can be undone.

```yaml
reversibility:
  primary: "git"
  side_effects:
    - type: "apt"
      undo: "apt remove -y {package}"
    - type: "systemd"
      undo: "systemctl stop {service} && systemctl disable {service}"
    - type: "docker"
      undo: "docker compose -f {compose_file} down {service}"
```

- `primary` -- the main undo mechanism: `git` (git revert), `snapshot`, or `state-capture`
- `side_effects` -- non-git changes and their undo command templates; `{placeholder}` values are filled in at runtime

### commit_categories (required)

Allowed category tags for changes from this pack. Used for metrics tracking and strategic analysis.

```yaml
commit_categories:
  - "service-add"
  - "security"
  - "monitoring"
  - "automation"
```

### challenge_vectors (required)

Additional adversarial questions the challenge phase asks about proposals, beyond the 7 built-in vectors.

```yaml
challenge_vectors:
  - "Could this cause service downtime?"
  - "Does this create a single point of failure?"
  - "What happens if this runs on a system with different specs?"
  - "Is this change idempotent? What if it runs twice?"
```

## Walkthrough: Creating a Pack From Scratch

### 1. Copy the template

```bash
cp -r packs/_template packs/my-target
```

### 2. Edit pack.yaml

Open `packs/my-target/pack.yaml` and fill in every field:

```bash
$EDITOR packs/my-target/pack.yaml
```

Start with `name` and `description`, then work through each section. The template file contains comments explaining every field.

### 3. Add custom scorers (optional)

If your heuristic scorers need helper scripts, place them in `packs/my-target/scorers/`:

```bash
# packs/my-target/scorers/check-response-time.sh
#!/usr/bin/env bash
curl -so /dev/null -w '%{time_total}' http://localhost:8080/health | awk '{printf "%.0f", $1 * 1000}'
```

Then reference them in your pack.yaml:

```yaml
scorers:
  heuristic:
    - name: "response_time_ms"
      command: "bash packs/my-target/scorers/check-response-time.sh"
      weight: 2
      direction: "lower_is_better"
```

### 4. Validate the pack

```bash
./bin/evolve pack list
```

If your pack appears in the list, it passed validation. If not, check for missing required fields.

### 5. Add to your config

Edit `config/evolve.yaml` and add your pack to the targets list:

```yaml
targets:
  - pack: "my-target"
    root: "/path/to/target/system"
    weight: 1
```

Or re-run `evolve init` to reconfigure.

## Walkthrough: Using Conversational Generation

If you prefer not to write YAML manually, evolve-ai can generate a pack from a plain-language description.

### During init

When the init wizard asks "What are you evolving?", choose `[+]`:

```
What are you evolving?
  [1] Infrastructure
  [2] Agent harness
  [3] Codebase
  [+] Describe something else...

Selection: +
Describe what you want to evolve: A Python Flask API with PostgreSQL database, deployed on AWS ECS
```

evolve-ai generates a pack named from your description (e.g., `python-flask-api-with-postgresql`) using the template and filling in name and description fields. You then customize the remaining fields post-init.

### Standalone creation

```bash
./bin/evolve pack create "my Kubernetes cluster with Helm charts"
```

This creates the pack directory with a pre-filled pack.yaml that you can refine.

## Built-in Packs as Reference

The three built-in packs are good references for different target types:

### infrastructure

- Focus: servers, services, security, monitoring
- Scan commands: system resources, Docker containers, running services, crontab
- Scorers: uptime, memory availability, disk space, failed service count
- Safety: no public port exposure, no firewall disabling, no credential storage
- Challenge vectors: downtime risk, single points of failure, idempotency

### agent-harness

- Focus: LLM agents, prompts, tools, evaluation
- Scan commands: agent configs, prompt files, evaluation results
- Scorers: evaluation pass rate, response quality, token efficiency
- Safety: no production deployments, no API key exposure
- Challenge vectors: prompt regression, hallucination risk, cost impact

### codebase

- Focus: software projects, code quality, test coverage
- Scan commands: git log, test results, linting output
- Scorers: test pass rate, code coverage, lint warnings
- Safety: no force pushes, no credential commits
- Challenge vectors: test coverage impact, API compatibility, dependency risks

## Testing Your Pack

After creating a pack, verify it works:

1. **Validate schema:**
   ```bash
   ./bin/evolve pack list
   ```
   Your pack should appear with its name and description.

2. **Test scan commands manually:**
   Run each scan command from your pack.yaml to verify they produce output and do not error.

3. **Test health checks manually:**
   Run each health check command and verify the expected behavior (exit code 0 or output matching the regex).

4. **Test scorers manually:**
   Run each scorer command and verify it outputs a single number.

5. **Dry run:**
   Configure the pack in evolve.yaml and run:
   ```bash
   ./bin/evolve run
   ```
   Monitor the output for phase errors related to your pack configuration.
