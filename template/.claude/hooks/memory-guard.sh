#!/bin/bash
# ============================================================================
# PreToolUse hook — memory "permissions" guardrail
# (Lamis Mukta's recommendation: the organization's shared memory is
#  READ-ONLY for the agent; a mistake that slipped in there would propagate
#  to every session.)
#
# This script runs BEFORE every Write/Edit/Bash tool call made by the agent.
# It BLOCKS:
#   - any write to memory/organization/  (read-only),
#   - any direct write to the error log (reserved for the hook),
#   - any destructive bash command (rm, mv…) targeting the memory/ folder.
# This is a second lock: the "deny" rules in settings.json already do the
# same job — the defense in depth is intentional.
# ============================================================================

# Claude Code's JSON arrives on stdin; we store it in an environment
# variable because the heredoc below already occupies python's stdin.
KITMEM_HOOK_INPUT=$(cat)
export KITMEM_HOOK_INPUT

python3 - <<'PYTHON'
import json, os, re, sys

data = json.loads(os.environ.get("KITMEM_HOOK_INPUT") or "{}")
tool = data.get("tool_name", "")
tool_input = data.get("tool_input") or {}

def block(reason):
    """Reply to Claude Code: call denied, with the explanation given to the agent."""
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)

# --- Case 1: file write (Write / Edit / MultiEdit) ---------------------------
if tool in ("Write", "Edit", "MultiEdit"):
    path = tool_input.get("file_path") or ""
    if "memory/organization/" in path:
        block("Memory guardrail: memory/organization/ is READ-ONLY for the "
              "agent (shared memory). Write your suggestion in "
              "memory/proposals/; a human will review it.")
    if path.endswith("memory/errors/log.md"):
        # The only tolerated change to the log: ANNOTATE a line with [handled …]
        # without removing anything (the old text must appear intact in the
        # new text). Everything else is blocked: the log is filled by a hook.
        old = tool_input.get("old_string") or ""
        new = tool_input.get("new_string") or ""
        pure_annotation = (
            tool == "Edit"
            and "[handled" in new
            and old != ""
            and old.replace("\n", "") in new.replace("\n", "")
        )
        if not pure_annotation:
            block("Memory guardrail: the error log is filled automatically "
                  "by a hook. Only allowed change: append a "
                  "[handled → lessons/<file>] note to an existing line via Edit, "
                  "without removing the original text.")

# --- Case 2: bash command ----------------------------------------------------
if tool == "Bash":
    command = tool_input.get("command") or ""
    # Destructive or write commands targeting the memory
    if re.search(r"\bmemory/", command):
        if re.search(r"\b(rm|rmdir|mv|unlink|shred)\b", command):
            # Exceptions: the scratchpad is disposable (purging allowed), and
            # dreaming may rename (mv) a proposals file to -done.md.
            targets = re.findall(r"memory/[^\s'\"]*", command)
            allowed = targets and (
                all(t.startswith("memory/scratchpad/") for t in targets)
                or (
                    re.search(r"\bmv\b", command)
                    and all(t.startswith(("memory/scratchpad/",
                                          "memory/proposals/")) for t in targets)
                )
            )
            if not allowed:
                block("Memory guardrail: deleting/moving is forbidden in "
                      "memory/ (except memory/scratchpad/). Cleanup goes "
                      "through the dreaming pass, approved by a human.")
        if re.search(r"(>>?|\btee\b|\bsed\s+-i)\s*\S*memory/organization/", command):
            block("Memory guardrail: memory/organization/ is read-only "
                  "for the agent, including via bash.")

sys.exit(0)   # no problem: the tool call proceeds normally
PYTHON
