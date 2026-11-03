#!/bin/bash
# ============================================================================
# token-report.sh — how much has this project consumed?
#
# Sums the tokens recorded in Claude Code's local transcripts
# (~/.claude/projects/…) for THIS project.
#
# Usage:
#   ./scripts/token-report.sh            # today
#   ./scripts/token-report.sh --days 7   # the last 7 days
#
# Honest notes:
#   - this is a LOCAL measurement (tokens seen in transcripts), useful for
#     spotting drift; your subscription's official quota is shown by the
#     /usage command in Claude Code;
#   - for a detailed multi-project cost report: `npx ccusage`
#     (independent open-source tool).
# ============================================================================
set -euo pipefail

DAYS=1
[ "${1:-}" = "--days" ] && DAYS="${2:-7}"

PROJECT="$(pwd)"
ENCODED_DIR=$(printf '%s' "$PROJECT" | sed 's/[^a-zA-Z0-9]/-/g')
TRANSCRIPTS="$HOME/.claude/projects/$ENCODED_DIR"

if [ ! -d "$TRANSCRIPTS" ]; then
  echo "No transcripts for this project ($TRANSCRIPTS)."
  exit 0
fi

# Python walks the transcripts itself (potentially large files:
# we don't push them through variables or unnecessary pipes).
python3 - "$TRANSCRIPTS" "$DAYS" <<'PYTHON'
import json, os, sys, time
from collections import defaultdict

folder, days = sys.argv[1], int(sys.argv[2])
cutoff = time.time() - days * 86400
totals = defaultdict(int)
by_model = defaultdict(int)

for name in os.listdir(folder):
    if not name.endswith(".jsonl"):
        continue
    path = os.path.join(folder, name)
    if os.path.getmtime(path) < cutoff:
        continue
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            message = obj.get("message") or {}
            usage = message.get("usage") or {}
            if not usage:
                continue
            totals["input (uncached)"] += usage.get("input_tokens") or 0
            totals["input (cache read)"] += usage.get("cache_read_input_tokens") or 0
            totals["input (cache write)"] += usage.get("cache_creation_input_tokens") or 0
            totals["output"] += usage.get("output_tokens") or 0
            by_model[message.get("model") or "?"] += usage.get("output_tokens") or 0

print(f"📊 Project tokens — last {days} day(s)")
for key, value in totals.items():
    print(f"   {key:22s} : {value:>12,} tokens")
if by_model:
    print("   By model (output tokens):")
    for model, value in sorted(by_model.items(), key=lambda x: -x[1]):
        print(f"     {model:35s} {value:>10,}")
print()
print("ℹ️  Official subscription quota: type /usage in Claude Code.")
print("ℹ️  Detailed cost report (all projects): npx ccusage")
PYTHON
