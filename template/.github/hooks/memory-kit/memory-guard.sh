#!/bin/bash
# ============================================================================
# preToolUse hook — memory "permissions" guardrail
# (Lamis Mukta's recommendation: the organization's shared memory is
#  READ-ONLY for the agent; a mistake that slipped in there would propagate
#  to every session.)
#
# Copilot CLI runs this script BEFORE every tool call. It DENIES:
#   - any write to memory/organization/  (read-only),
#   - any direct write to the error log, except appending a
#     "[handled → …]" note to an existing line,
#   - deleting/moving files in memory/ (except memory/scratchpad/, and
#     renaming in memory/proposals/), via file tools OR via the shell,
#   - reading obvious secret files (.env, *.pem, SSH private keys) with the
#     file viewer.
#
# Copilot treats a crashing preToolUse hook as "deny" (fail-closed), so this
# script never crashes: on an internal error it only denies when the call
# visibly targets memory/organization/, and lets everything else through.
# ============================================================================
command -v python3 >/dev/null 2>&1 || exit 0
HERE="$(cd "$(dirname "$0")" && pwd)"

# The Python code comes in on fd 3, so stdin stays the hook's JSON payload
python3 /dev/fd/3 "$HERE" 3<<'PYTHON'
import json, re, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
raw = ""

def decide(decision, reason=""):
    out = {"permissionDecision": decision, "permissionDecisionReason": reason}
    # Also understood by Claude-style (PascalCase) hook configurations
    out["hookSpecificOutput"] = {"hookEventName": "PreToolUse", **out}
    print(json.dumps(out))
    sys.exit(0)

ORG_MSG = ("Memory guardrail: memory/organization/ is READ-ONLY for the agent "
           "(shared memory). Write your suggestion in memory/proposals/; "
           "a human will review it.")
LOG_MSG = ("Memory guardrail: memory/errors/log.md is filled automatically by a "
           "hook. Only allowed change: append ' [handled → lessons/<file>]' to "
           "an existing line with the edit tool, without removing any text.")
DEL_MSG = ("Memory guardrail: deleting/moving is forbidden in memory/ (except "
           "memory/scratchpad/). Cleanup goes through the dreaming pass, "
           "approved by a human.")

def is_org(rel):  return rel == "memory/organization" or rel.startswith("memory/organization/")
def is_log(rel):  return rel == "memory/errors/log.md"
def in_mem(rel):  return rel == "memory" or rel.startswith("memory/")

def pure_annotation(old, new):
    """True if `new` only appends [handled …] notes to `old`, removing nothing."""
    if "[handled" not in new or not old.strip():
        return False
    old_lines, new_lines = old.splitlines(), new.splitlines()
    if len(old_lines) != len(new_lines):
        return False
    changed = False
    for o, n in zip(old_lines, new_lines):
        if o == n:
            continue
        if not n.startswith(o) or "[handled" not in n[len(o):]:
            return False
        changed = True
    return changed

def check_file_ops(ev):
    for op in ev.file_ops():
        rels = [op.rel] + ([payload.relative(op.move_to)] if op.move_to else [])
        if any(is_org(r) for r in rels):
            decide("deny", ORG_MSG)
        if is_log(op.rel):
            if op.kind == "update" and op.replacements:
                ok = all(pure_annotation(o, n) for o, n in op.replacements)
            elif op.kind == "update" and not op.move_to:
                ok = pure_annotation("\n".join(op.removed), "\n".join(op.added))
            else:
                ok = False
            if not ok:
                decide("deny", LOG_MSG)
        if op.kind == "delete" and in_mem(op.rel) and not op.rel.startswith("memory/scratchpad/"):
            decide("deny", DEL_MSG)
        if op.move_to and in_mem(op.rel):
            allowed = ("memory/scratchpad/", "memory/proposals/")
            if not all(r.startswith(allowed) for r in rels):
                decide("deny", DEL_MSG)

SECRET_MSG = ("Security guardrail: reading secret files (.env, *.pem, SSH keys) "
              "is denied. Ask the user for the specific value you need.")
SECRET_FILE = re.compile(r"^(\.env(\..+)?|.*\.pem|id_(rsa|dsa|ecdsa|ed25519)(?!\.pub$).*)$")

def check_read(ev):
    path = ev.args.get("path") or ev.args.get("file_path") if isinstance(ev.args, dict) else ""
    name = str(path or "").rstrip("/").rsplit("/", 1)[-1]
    if name and name not in (".env.example", ".env.sample", ".env.template") and SECRET_FILE.match(name):
        decide("deny", SECRET_MSG)

WRITE_CMDS = r"(\btee\b|\bsed\s+-\w*i|\bperl\s+-\w*i|\bcp\b|\bmv\b|\btouch\b|\btruncate\b|\binstall\b|\bln\b|\bdd\b|\brsync\b|Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Move-Item|Copy-Item)"

DELETE_VERBS = r"\b(rm|rmdir|mv|unlink|shred|git\s+rm|git\s+mv|Remove-Item|Move-Item)\b"

def check_shell(cmd):
    # "cd memory/lessons && rm x.md": paths no longer contain memory/
    if re.search(r"\b(cd|pushd|Set-Location)\s+['\"]?[^\s;|&]*memory\b", cmd) \
            and re.search(DELETE_VERBS, cmd) and "scratchpad" not in cmd:
        decide("deny", DEL_MSG)
    if not re.search(r"memory/", cmd):
        return
    # 1. Writes into memory/organization/ (redirections, tee, sed -i, cp, …)
    if re.search(r">>?\s*['\"]?[^\s;|&'\"]*memory/organization(/|\b)", cmd):
        decide("deny", ORG_MSG + " (including via the shell)")
    if "memory/organization" in cmd and re.search(WRITE_CMDS + r".*memory/organization", cmd):
        decide("deny", ORG_MSG + " (including via the shell)")
    # 2. Writes into the error log through the shell
    if re.search(r"(>>?\s*['\"]?[^\s;|&'\"]*memory/errors/log\.md|" + WRITE_CMDS + r".*memory/errors/log\.md)", cmd):
        decide("deny", LOG_MSG)
    # 3. Deleting / moving inside memory/
    if re.search(DELETE_VERBS, cmd):
        targets = [re.sub(r"^.*?(memory/)", r"\1", t)
                   for t in re.findall(r"[^\s'\"]*memory/[^\s'\";|&]*", cmd)]
        targets = [t for t in targets if t.startswith("memory/")]
        is_move = re.search(r"\b(mv|git\s+mv|Move-Item)\b", cmd) and not re.search(r"\b(rm|rmdir|unlink|shred|Remove-Item)\b", cmd)
        allowed = targets and (
            all(t.startswith("memory/scratchpad/") for t in targets)
            or (is_move and all(t.startswith(("memory/scratchpad/", "memory/proposals/")) for t in targets))
        )
        if not allowed:
            decide("deny", DEL_MSG)

try:
    import payload
    raw, data = payload.read_input()
    if not data and "memory/organization" in raw:
        raise ValueError("unparseable payload")
    ev = payload.Event(data)
    if ev.kind == "write":
        check_file_ops(ev)
    elif ev.kind == "shell":
        check_shell(ev.command())
    elif ev.tool.lower() in ("view", "read"):
        check_read(ev)
except SystemExit:
    raise
except Exception:
    # Never crash (Copilot would deny EVERY tool call). Stay safe on the
    # one rule that matters most: the shared organization memory.
    if "memory/organization" in raw:
        decide("deny", ORG_MSG)
sys.exit(0)   # nothing to say: the call goes through the normal permission flow
PYTHON
exit 0
