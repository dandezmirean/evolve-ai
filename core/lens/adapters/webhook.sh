#!/usr/bin/env bash
# core/lens/adapters/webhook.sh — delegates to shared adapter
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/webhook.sh"
