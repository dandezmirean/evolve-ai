#!/usr/bin/env bash
# core/inbox/sources/rss.sh — delegates to shared adapter
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/rss.sh"
