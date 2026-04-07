#!/usr/bin/env bash
# core/inbox/sources/command.sh — delegates to shared adapter
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/command.sh"
