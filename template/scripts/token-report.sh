#!/usr/bin/env bash
# shfmt -i 2 -ci -w
set -Eeuo pipefail

trap exit SIGINT SIGTERM

################################################################################
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

################################################################################
# Default configuration
REPORT_DAYS=${REPORT_DAYS:-1}
DEFAULT_DAYS="$REPORT_DAYS"
################################################################################

usage() {
  echo "usage: ${0##*/} [--days N]"
  echo "    --days N   report the last N days (default ${DEFAULT_DAYS})"
  exit 1
}

main() {
  case "${1:-}" in
    "") ;;
    --days) REPORT_DAYS="${2:-}" ;;
    *) usage ;;
  esac
  [[ "$REPORT_DAYS" =~ ^[0-9]+$ ]] || usage
  command -v python3 >/dev/null 2>&1 || {
    echo "❌ python3 not found in PATH." >&2
    exit 1
  }
  local _here
  _here="$(cd "$(dirname "$0")" && pwd)"
  PYTHONDONTWRITEBYTECODE=1 python3 "$_here/copilot_sessions.py" report "$(pwd)" "$REPORT_DAYS"
}

main "$@"
exit 0
