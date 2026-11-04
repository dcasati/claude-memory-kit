#!/bin/bash
# ============================================================================
# postToolUseFailure + postToolUse hook — the raw material for learning
# (Lamis Mukta's recommendation: agents must learn from their mistakes;
#  dreaming then analyzes these failures to spot recurring patterns.)
#
# Copilot CLI reports two kinds of failures differently:
#   - a tool error (missing file, impossible edit…) → postToolUseFailure,
#     with an "error" field;
#   - a shell command that exits non-zero → postToolUse "success" whose
#     output ends with "<… completed with exit code N>".
# Both end up as one dated line in memory/errors/log.md:
#   - 2026-07-17 14:02 · bash · "npm run dev" → EADDRINUSE… · session ab12cd34
# The log is capped at 400 lines (rotation): it is an analysis buffer,
# not an infinite archive.
# ============================================================================
command -v python3 >/dev/null 2>&1 || exit 0
HERE="$(cd "$(dirname "$0")" && pwd)"

# The Python code comes in on fd 3, so stdin stays the hook's JSON payload
python3 /dev/fd/3 "$HERE" 3<<'PYTHON'
import datetime, json, os, re, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import payload

log = os.path.join(payload.MEMORY, "errors", "log.md")
if not os.path.isdir(os.path.dirname(log)):
    sys.exit(0)   # kit not installed here: do nothing

ev = payload.Event(payload.read_input()[1])

if ev.error:
    message = ev.error if isinstance(ev.error, str) else json.dumps(ev.error)
elif ev.kind == "shell":
    m = re.search(r"exit code (\d+)>?\s*$", ev.result_text)
    if not m or m.group(1) == "0":
        sys.exit(0)
    # "no match" / "files differ" are answers, not errors
    if m.group(1) == "1" and re.match(r"\s*(grep|egrep|rg|test|\[|diff|cmp|git\s+diff)\b", ev.command()):
        sys.exit(0)
    output = ev.result_text[:m.start()]
    output = re.sub(r"<shellId:[^>]*$", "", output).strip()
    tail = " ".join(output.splitlines()[-3:])
    message = f"exit {m.group(1)}: {tail}" if tail else f"exit {m.group(1)}"
else:
    sys.exit(0)

message = payload.flatten(message, 200)
# A permission refusal (user or guardrail) is not an agent error.
if re.search(r"(denied|user doesn.?t want|rejected|user chose|not permitted by user)", message, re.I):
    sys.exit(0)

if ev.kind == "shell":
    attempt = ev.command()
else:
    ops = ev.file_ops()
    attempt = ops[0].rel or ops[0].path if ops else (
        ev.args.get("path") if isinstance(ev.args, dict) else "") or ""
attempt = payload.flatten(attempt, 80).replace('"', "'")

when = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
line = f"- {when} · {ev.tool or '?'} · \"{attempt}\" → {message} · session {ev.short_session}\n"

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
