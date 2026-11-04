#!/bin/bash
# ============================================================================
# sessionStart hook — "progressive disclosure" of the memory
# (Lamis Mukta's recommendation: inject a lightweight INDEX, never the whole store)
#
# Copilot CLI adds the "additionalContext" field of this script's JSON output
# to the agent's context when the session starts. We only inject:
#   1. the memory index (one line per memory),
#   2. the 10 most recent unhandled errors (so they aren't repeated),
#   3. an alert if dreaming proposals are pending.
# ============================================================================
command -v python3 >/dev/null 2>&1 || exit 0
cat >/dev/null   # the payload isn't needed here
HERE="$(cd "$(dirname "$0")" && pwd)"

# The Python code comes in on fd 3, so stdin stays the hook's JSON payload
python3 /dev/fd/3 "$HERE" 3<<'PYTHON'
import glob, json, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from payload import MEMORY

parts = []

# 1. The index (the library catalog, not the books) — HTML comments stripped
index = os.path.join(MEMORY, "MEMORY.md")
if os.path.isfile(index):
    lines, in_comment = [], False
    for line in open(index, encoding="utf-8"):
        if line.lstrip().startswith("<!--"):
            in_comment = True
        if not in_comment:
            lines.append(line.rstrip("\n"))
        if in_comment and "-->" in line:
            in_comment = False
    parts.append("## Project memory (index — open files only when relevant)\n"
                 + "\n".join(lines).strip())

# 2. Recent unhandled errors (lines annotated [handled …] are excluded)
log = os.path.join(MEMORY, "errors", "log.md")
if os.path.isfile(log):
    recent = [l.rstrip("\n") for l in open(log, encoding="utf-8")
              if l.startswith("- ") and "[handled" not in l][-10:]
    if recent:
        parts.append("## Recently logged errors (do not repeat — see memory/errors/log.md)\n"
                     + "\n".join(recent))

# 3. Dreaming proposals awaiting human approval?
pending = [p for p in glob.glob(os.path.join(MEMORY, "proposals", "*dreaming*.md"))
           if not p.endswith("-done.md")]
if pending:
    parts.append("⚠️ Dreaming proposals are awaiting human approval in "
                 "memory/proposals/. Let the user know.")

if parts:
    print(json.dumps({"additionalContext": "\n\n".join(parts)}))
PYTHON
exit 0
