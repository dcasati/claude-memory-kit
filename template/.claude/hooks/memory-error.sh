#!/bin/bash
# ============================================================================
# PostToolUseFailure hook — the raw material for learning
# (Lamis Mukta's recommendation: agents must learn from their mistakes;
#  dreaming then analyzes these failures to spot recurring patterns.)
#
# This script runs automatically on EVERY tool failure (bash command that
# crashes, impossible edit, etc.). It appends a dated line to
# memory/errors/log.md:
#   - 2026-07-17 14:02 · Bash · "npm run dev" → EADDRINUSE… · session ab12cd34
# The log is capped at 400 lines (rotation): it is an analysis buffer,
# not an infinite archive.
# ============================================================================

LOG="$CLAUDE_PROJECT_DIR/memory/errors/log.md"
[ -d "$(dirname "$LOG")" ] || exit 0   # kit not installed here: do nothing

# Claude Code's JSON arrives on stdin; we store it in an environment
# variable because the heredoc below already occupies python's stdin.
KITMEM_HOOK_INPUT=$(cat)
export KITMEM_HOOK_INPUT

python3 - "$LOG" <<'PYTHON'
import datetime, json, os, re, sys

log = sys.argv[1]
d = json.loads(os.environ.get("KITMEM_HOOK_INPUT") or "{}")

tool = d.get("tool_name", "?")
tool_input = d.get("tool_input") or {}
response = d.get("tool_response") or {}
session = (d.get("session_id") or "")[:8]

# A short summary of what was attempted (compact: the log must stay light)
if tool == "Bash":
    attempt = (tool_input.get("command") or "")[:80]
else:
    attempt = (tool_input.get("file_path") or "")[:80]

# The error message, flattened and truncated
message = str(response.get("message") or response.get("text") or response)
message = re.sub(r"\s+", " ", message).strip()[:200]

# Some "failures" are just the user denying a permission:
# that's not an agent error, so we don't log it.
if re.search(r"(user doesn.?t want|permission den|rejected|user chose)", message, re.I):
    sys.exit(0)

when = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
line = f"- {when} · {tool} · \"{attempt}\" → {message} · session {session or '?'}\n"

# Read the existing log + rotate at 400 entries
try:
    with open(log, encoding="utf-8") as f:
        content = f.readlines()
except FileNotFoundError:
    content = ["# Error log (filled automatically)\n", "\n"]

headers = [l for l in content if not l.startswith("- ")]
entries = [l for l in content if l.startswith("- ")]
entries.append(line)
entries = entries[-400:]          # rotation: keep the 400 most recent

with open(log, "w", encoding="utf-8") as f:
    f.writelines(headers + entries)
PYTHON

exit 0   # always non-blocking: a tool error must not be made worse
