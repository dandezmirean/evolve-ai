# Changelog

## [0.1.0] - 2026-04-06

### Added
- Core framework: orchestrator, pool state machine, config parser, lock management
- 8-phase pipeline prompt templates (digest, strategize, analyze, challenge, implement, validate, finalize, metrics)
- Three built-in genomes: infrastructure, agent-harness, codebase
- Genome template for creating custom genomes
- Interactive `evolve init` with conversational genome generation
- Four-layer scoring engine (heuristic, LLM-judge, KPI baselines, user-defined)
- Memory manager with 7 memory file types and changelog pruning
- Metrics recorder with 17-field entries and weekly digest
- Pluggable notification system (stdout, Telegram, Slack, Discord)
- LLM provider abstraction (Claude Max default, Claude API and OpenAI stubs)
- Inbox watcher with manifest-based MD5 change detection
- Source adapters: RSS, command, webhook, manual
- Resume context system with interactive re-entry and 6 action types
- Directives system: lock, priority, constraint, override with expiry
- Meta-agent outer loop evaluator with 4 evaluation dimensions
- Resource gates (RAM, disk) that halt phases when thresholds are breached
- Crash recovery with git snapshots, rollback manifests, and crontab restore
- Reversibility-first model requiring undo registration before execution
- Convergence detection via pool status hashing and stall counting
- Housekeeping: workspace retention, git tag pruning, pre-run snapshots
- CLI with 13 commands: init, run, status, history, resume, genome, meta, config, version
- Comprehensive test suite (218 tests across 12 test files)
- Integration test validating end-to-end component interaction
- Full documentation: README, getting started, architecture, genomes, scoring, safety model
