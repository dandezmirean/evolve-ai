# Scoring Guide

evolve-ai uses a four-layer scoring system to measure the impact of every change. This guide explains each layer, how aggregation works, and how to configure scorers.

## Overview

The four scoring layers, in order of evaluation:

1. **Heuristic** -- genome-defined commands that output numeric metrics
2. **LLM Judge** -- an LLM evaluates the change diff and assigns a 0.0-1.0 score
3. **KPI Baselines** -- before/after comparison of key performance indicators
4. **User-Defined** -- additional custom scorers with the same format as heuristic

Each layer is optional. If a layer is not configured or not available, it is skipped. The aggregation engine combines whatever data is present into a final **impact signal**.

## Impact Signals

The final output of scoring is an impact signal, one of:

- **positive** -- the change improved the target system
- **negative** -- the change degraded the target system
- **neutral** -- no measurable difference
- **unmeasured** -- no scoring data available

Impact signals feed into:
- The finalize phase (land/revert decisions)
- The metrics recorder (tracked per entry)
- The circuit breaker (negative signals contribute to trip threshold)
- The meta-agent (aggregate signal trends inform pipeline tuning)

## Layer 1: Heuristic Scorers

Heuristic scorers are shell commands defined in your genome's `genome.yaml` that output a single number to stdout. They run **before** and **after** a change, and the weighted delta determines the heuristic component of the impact signal.

### Configuration

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
    - name: "disk_available_pct"
      command: "df / --output=avail,size | tail -1 | awk '{printf \"%.0f\", $1/$2*100}'"
      weight: 2
      direction: "higher_is_better"
```

### Fields

| Field | Type | Description |
|---|---|---|
| `name` | string | Identifier for the scorer |
| `command` | string | Shell command that outputs a single number |
| `weight` | integer | Relative importance (1-5 typical) |
| `direction` | string | `higher_is_better` or `lower_is_better` |

### How It Works

1. Before implementation, `scoring_run_heuristic` runs all scorers and saves results to `scores/{change_id}-heuristic-before.json`
2. After implementation, the same scorers run again, saving to `scores/{change_id}-heuristic-after.json`
3. `scoring_compute_weighted_delta` computes the weighted average delta:
   - For `higher_is_better`: delta = after - before (positive is good)
   - For `lower_is_better`: delta = -(after - before) (decrease is good)
   - Each delta is multiplied by its weight
   - The weighted average is: sum(delta * weight) / sum(weight)

### Writing Good Heuristic Scorers

- The command must output exactly one number (integer or decimal)
- If the command fails, it defaults to 0
- Non-numeric output is treated as 0
- Commands should be fast (< 5 seconds) since they run twice per change
- Use `2>/dev/null` to suppress stderr noise

## Layer 2: LLM Judge

The LLM judge sends the change diff to the configured LLM provider with an evaluation prompt and expects a JSON response with a score from 0.0 to 1.0.

### Configuration

```yaml
scorers:
  llm_judge:
    enabled: true
    prompt: "Evaluate whether this change improves reliability and efficiency. Score 0.0-1.0."
```

### Fields

| Field | Type | Description |
|---|---|---|
| `enabled` | boolean | Whether to run the LLM judge |
| `prompt` | string | The evaluation prompt sent with the diff |

### How It Works

1. `scoring_run_llm_judge` builds a prompt combining your evaluation prompt + the change diff
2. The LLM responds with: `{"score": 0.7, "reasoning": "brief explanation"}`
3. The score is clamped to the 0.0-1.0 range
4. If the LLM is not available or fails, the score defaults to 0.5 (neutral)

### Writing Good Judge Prompts

- Be specific about what "good" means for your domain
- Mention concrete criteria: reliability, security, performance, maintainability
- The prompt sees the raw diff, so reference "this change" rather than abstract concepts
- Keep the prompt under 200 words -- the diff itself will be long

## Layer 3: KPI Baselines

KPI checks compare specific metrics against baseline values with a threshold. They are defined per-pool-entry (not in the genome) because each change targets different KPIs.

### How KPIs Are Set

During the analyze phase, each pool entry can include a `kpi_checks` array:

```json
{
  "id": "S-001",
  "kpi_checks": [
    {
      "name": "api_response_time_ms",
      "command": "curl -so /dev/null -w '%{time_total}' http://localhost:8080/health | awk '{printf \"%.0f\", $1*1000}'",
      "baseline": 150,
      "threshold": 20
    }
  ]
}
```

### Fields

| Field | Type | Description |
|---|---|---|
| `name` | string | KPI identifier |
| `command` | string | Shell command that outputs the current value |
| `baseline` | number | The pre-change baseline value |
| `threshold` | number | Acceptable regression tolerance |

### How It Works

1. `scoring_run_kpi` runs each KPI command and gets the current value
2. If `actual < baseline - threshold`, the KPI is flagged as **regressed**
3. KPI regression is a **hard gate** -- any KPI regression forces the impact signal to `negative`, regardless of other layers

### KPI vs Heuristic

- Heuristic scorers measure the target system's general health
- KPI checks measure the specific expected impact of a particular change
- KPI regression overrides positive heuristic/LLM signals

## Layer 4: User-Defined Scorers

User-defined scorers follow the exact same format as heuristic scorers but live in a separate section. They exist for scorers that are not part of the genome's core health metrics but are relevant for specific evaluation scenarios.

### Configuration

```yaml
scorers:
  user_defined:
    - name: "custom_metric"
      command: "my-custom-check.sh"
      weight: 2
      direction: "higher_is_better"
```

The execution and delta computation are identical to heuristic scorers.

## How Aggregation Works

The `scoring_aggregate` function reads all available score files and produces a final impact signal:

```
Input files:
  scores/{id}-heuristic-before.json
  scores/{id}-heuristic-after.json
  scores/{id}-llm-judge.json
  scores/{id}-kpi.json

Output:
  scores/{id}-aggregate.json
```

### Aggregation Logic

```
1. If KPI result is "regress":
   -> impact_signal = "negative" (hard gate, overrides everything)

2. If no layers produced data:
   -> impact_signal = "unmeasured"

3. If both heuristic and LLM data available:
   - Both positive -> "positive"
   - Both negative -> "negative"
   - Disagree -> "neutral"

4. If only heuristic data:
   - Delta > 0 -> "positive"
   - Delta < 0 -> "negative"
   - Delta == 0 -> "neutral"

5. If only LLM data:
   - Score >= 0.5 -> "positive"
   - Score < 0.5 -> "negative"

6. If only KPI data (passed, not regressed):
   -> "positive"
```

### Aggregate Output Format

```json
{
  "impact_signal": "positive",
  "heuristic_delta": 2.5,
  "llm_score": 0.8,
  "kpi_result": "pass",
  "details": {
    "has_heuristic": true,
    "has_llm": true,
    "has_kpi": true
  }
}
```

## How Impact Signals Feed Back

Impact signals influence multiple parts of the system:

### Finalize Phase
- `positive` + validation passing -> land the change
- `negative` -> revert the change
- `neutral` -> land with caution (lower confidence)
- `unmeasured` -> land if validation passes, flag for KPI follow-up

### Circuit Breaker
- Each `negative` impact signal increments the circuit breaker counter
- When the counter reaches `negative_impact_threshold` within `window_days`, autonomous runs are paused

### Meta-Agent
- The meta-agent analyzes aggregate impact signal trends
- Consistent `negative` signals trigger proposals to adjust scoring weights or challenge floor
- Consistent `unmeasured` signals trigger proposals to add more scorers

### Metrics
- Every settled pool entry records its impact signal in `metrics.jsonl`
- The weekly digest reports positive/negative/neutral/unmeasured counts
- Category-level stats break down impact signals by change category

## Configuring the Scoring Pipeline

### Minimal Setup (Heuristic Only)

The simplest scoring setup uses only heuristic scorers:

```yaml
scorers:
  heuristic:
    - name: "my_metric"
      command: "echo 42"
      weight: 1
      direction: "higher_is_better"
  llm_judge:
    enabled: false
```

### Full Setup (All Four Layers)

```yaml
scorers:
  heuristic:
    - name: "metric_a"
      command: "measure-a.sh"
      weight: 3
      direction: "higher_is_better"
    - name: "metric_b"
      command: "measure-b.sh"
      weight: 2
      direction: "lower_is_better"
  llm_judge:
    enabled: true
    prompt: "Evaluate this change for quality and impact. Score 0.0-1.0."
  user_defined:
    - name: "special_check"
      command: "special-check.sh"
      weight: 1
      direction: "higher_is_better"
```

KPI baselines are set per-entry during the analyze phase, not in genome configuration.

### No Scoring

If no scorers are configured and the LLM judge is disabled, all changes receive the `unmeasured` impact signal. The pipeline still works -- changes are landed or reverted based on validation (health checks) alone.
