#!/bin/bash
# ============================================================================
# token-report.sh — how much has this project consumed?
#
# Sums the token usage and AI credits recorded in GitHub Copilot CLI's local
# session logs (~/.copilot/session-state/<session>/events.jsonl) for every
# session that ran in THIS project.
#
# Usage (from the project root):
#   ./scripts/token-report.sh            # today
#   ./scripts/token-report.sh --days 7   # the last 7 days
#
# Honest notes:
#   - this is a LOCAL measurement, useful for spotting drift; your plan's
#     official quota and billing are shown by /usage inside Copilot CLI and
#     on github.com (Settings → Billing);
#   - AI credits are read from the session's own accounting events.
# ============================================================================
set -euo pipefail

DAYS=1
[ "${1:-}" = "--days" ] && DAYS="${2:-7}"

HERE="$(cd "$(dirname "$0")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$HERE/copilot_sessions.py" report "$(pwd)" "$DAYS"
