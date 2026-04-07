#!/usr/bin/env bash
# core/inbox/source-runner.sh — Compatibility shim
# The feed runner has moved to core/lens/feed-runner.sh as part of the
# lens system. This file sources the new location for backwards compatibility.

SCRIPT_DIR_RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CORE_DIR_RUNNER="$(cd "$SCRIPT_DIR_RUNNER/.." && pwd)"

source "$_CORE_DIR_RUNNER/lens/feed-runner.sh"

# Legacy alias: run_sources calls run_feeds
run_sources() {
    run_feeds "$@"
}
