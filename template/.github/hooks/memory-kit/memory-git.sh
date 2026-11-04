#!/bin/bash
# ============================================================================
# postToolUse hook — memory "versioning" guardrail
# (Lamis Mukta's recommendation: every memory write must be attributed
#  — author, session, timestamp — with a full history to inspect
#  and roll back.)
#
# Runs AFTER every tool call that can write (file tools AND shell, since
# agents sometimes write files with `printf > file`). If anything changed
# under memory/, it creates an automatic git commit:
#   "memory: lessons/foo.md (agent, session abc12345)"
# Result: `git log -- memory/` = the full memory history,
# and `git checkout <commit> -- memory/` = rollback.
# ============================================================================
INPUT=$(cat)
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT" || exit 0
[ -d memory ] || exit 0
# No git repo? Versioning is impossible: exit without blocking.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Fast path: nothing changed under memory/ (scratchpad is git-ignored)
CHANGED=$(git status --porcelain --untracked-files=all -- memory 2>/dev/null)
[ -n "$CHANGED" ] || exit 0

SESSION=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    d = {}
print(str(d.get("sessionId") or d.get("session_id") or "")[:8])
' 2>/dev/null)

# Up to 3 changed files in the message, paths relative to memory/
FILES=$(printf '%s\n' "$CHANGED" | sed -E 's/^.. //; s/^"//; s/"$//; s/.* -> //; s#^memory/##' \
  | head -n 3 | paste -sd ',' - | sed 's/,/, /g')
COUNT=$(printf '%s\n' "$CHANGED" | grep -c .)
[ "$COUNT" -gt 3 ] && FILES="$FILES, +$((COUNT - 3)) more"

git add -A -- memory >/dev/null 2>&1
# --no-verify: don't trigger any of the project's own git hooks;
# the pathspec makes the commit cover ONLY memory/ (nothing else swept in)
git commit --quiet --no-verify \
  -m "memory: $FILES (agent, session ${SESSION:-unknown})" \
  -- memory >/dev/null 2>&1

exit 0
