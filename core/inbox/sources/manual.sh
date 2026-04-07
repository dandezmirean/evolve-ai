#!/usr/bin/env bash
# core/inbox/sources/manual.sh — delegates to shared adapter
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/manual.sh"
