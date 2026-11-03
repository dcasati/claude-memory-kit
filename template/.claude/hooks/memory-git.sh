#!/bin/bash
# ============================================================================
# PostToolUse hook — memory "versioning" guardrail
# (Lamis Mukta's recommendation: every memory write must be attributed
#  — author, session, timestamp — with a full history to inspect
#  and roll back.)
#
# This script runs AFTER every successful file write.
# If the written file is in memory/, it creates an automatic git commit:
#   "memory: <file> (agent, session abc12345)"
# Result: `git log -- memory/` = the full memory history,
# and `git checkout <commit> -- memory/` = rollback.
# ============================================================================

INPUT=$(cat)   # the JSON sent by Claude Code on standard input

# Extract the written file path and the session id (2 lines)
INFO=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print((d.get("tool_input") or {}).get("file_path") or "")
print((d.get("session_id") or "")[:8])
' 2>/dev/null)

FILE=$(printf '%s' "$INFO" | sed -n 1p)
SESSION=$(printf '%s' "$INFO" | sed -n 2p)

# Only handle writes inside the project's memory/ folder
case "$FILE" in
  "$CLAUDE_PROJECT_DIR"/memory/*) ;;   # yes → continue
  *) exit 0 ;;                         # no → nothing to do
esac

cd "$CLAUDE_PROJECT_DIR" || exit 0
# No git repo? Versioning is impossible: exit without blocking.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

git add -A memory >/dev/null 2>&1
# --no-verify: don't trigger any of the project's own git hooks
# the commit ONLY covers memory/ so no other files get swept in
git commit --quiet --no-verify \
  -m "memory: ${FILE#"$CLAUDE_PROJECT_DIR"/} (agent, session ${SESSION:-unknown})" \
  -- memory >/dev/null 2>&1

exit 0
