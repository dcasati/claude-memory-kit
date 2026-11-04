#!/usr/bin/env bash
# shfmt -i 2 -ci -w
# No `set -e` on purpose: a preToolUse hook that exits non-zero DENIES the
# tool call, so this script must always reach `exit 0`.
# ============================================================================
# preToolUse hook — memory "permissions" guardrail (first line of defense)
# (Lamis Mukta's recommendation: the organization's shared memory is
#  READ-ONLY for the agent; a mistake that slipped in there would propagate
#  to every session.)
#
# Copilot CLI runs this script BEFORE every tool call. It DENIES:
#   - any write to memory/organization/ and to the kit's own hooks and
#     skills (an agent must not be able to switch its guardrails off),
#   - any direct write to the error log, except appending a
#     "[handled → …]" note to an existing line,
#   - deleting/moving files in memory/ (except memory/scratchpad/, and
#     renaming in memory/proposals/),
#   - reading obvious secret files (.env, .netrc, *.pem, *.key, SSH keys…).
#
# Shell commands are checked on a best-effort basis: every path argument is
# resolved (following `cd`) and compared with the protected paths, but a
# program can always write a file in a way no pattern can see. The real
# enforcement is AFTER the call: memory-git.sh reverts any change to the
# protected paths. This hook exists to stop mistakes early, with a clear
# message.
#
# Copilot treats a crashing preToolUse hook as "deny", which would block all
# work, so this script never crashes: on an internal error it only denies
# calls that visibly mention a protected path. Without python3 the hooks are
# inactive (install.sh warns about it).
# ============================================================================
command -v python3 >/dev/null 2>&1 || exit 0
HERE="$(cd "$(dirname "$0")" && pwd)"

# The Python code comes in on fd 3, so stdin stays the hook's JSON payload
python3 /dev/fd/3 "$HERE" 3<<'PYTHON'
import json, os, re, sys
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
KIT_MSG = ("Memory guardrail: the memory kit's hooks and skills "
           "(.github/hooks/memory-kit*, .github/skills/{dreaming,lesson,memorize}) "
           "are READ-ONLY for the agent. Ask the user to change them.")
LOG_MSG = ("Memory guardrail: memory/errors/log.md is filled automatically by a "
           "hook. Only allowed change: append ' [handled → lessons/<file>]' to "
           "an existing line with the edit tool, without removing any text.")
DEL_MSG = ("Memory guardrail: deleting/moving is forbidden in memory/ (except "
           "memory/scratchpad/). Cleanup goes through the dreaming pass, "
           "approved by a human.")
SECRET_MSG = ("Security guardrail: reading secret files (.env, .netrc, keys, "
              "credentials) is denied. Ask the user for the specific value you need.")

MAY_DELETE = ("memory/scratchpad",)
MAY_MOVE = ("memory/scratchpad", "memory/proposals")

def is_log(rel):  return rel.lower() == "memory/errors/log.md"
def in_mem(rel):  return payload.under(rel, "memory")
def within(rel, prefixes):  return any(payload.under(rel, p) for p in prefixes)

def deny_protected(rel, suffix=""):
    decide("deny", (ORG_MSG if payload.under(rel, payload.ORG) else KIT_MSG) + suffix)

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

# --- File tools (create / edit / apply_patch) -------------------------------
def check_file_ops(ev):
    if isinstance(ev.args, str) and not ev.patch_text():
        raise ValueError("unparseable write arguments")   # → raw-text check below
    for op in ev.file_ops():
        rels = [op.rel] + ([payload.relative(op.move_to)] if op.move_to else [])
        for rel in rels:
            if payload.is_protected(rel):
                deny_protected(rel)
        if is_log(op.rel):
            if op.kind == "update" and op.replacements:
                ok = all(pure_annotation(o, n) for o, n in op.replacements)
            elif op.kind == "update" and not op.move_to:
                ok = pure_annotation("\n".join(op.removed), "\n".join(op.added))
            else:
                ok = False
            if not ok:
                decide("deny", LOG_MSG)
        if op.kind == "delete" and in_mem(op.rel) and not within(op.rel, MAY_DELETE):
            decide("deny", DEL_MSG)
        if op.move_to and any(in_mem(r) for r in rels) and not all(within(r, MAY_MOVE) for r in rels):
            decide("deny", DEL_MSG)

# --- Secret files -------------------------------------------------------------
SECRET_FILE = re.compile(
    r"^(\.env(\..+)?|\.envrc|\.netrc|\.pgpass|\.git-credentials|\.npmrc|\.pypirc"
    r"|credentials(\.json)?|.*\.(pem|key|p12|pfx|jks|keystore|kdbx)"
    r"|id_(rsa|dsa|ecdsa|ed25519)(?!\.pub$).*)$", re.I)
NOT_SECRET = {".env.example", ".env.sample", ".env.template", ".env.dist"}

def is_secret(path):
    name = str(path).strip().strip("'\"").rstrip("/").replace("\\", "/").rsplit("/", 1)[-1]
    return bool(name) and name.lower() not in NOT_SECRET and bool(SECRET_FILE.match(name))

def check_read(ev):
    if isinstance(ev.args, dict):
        candidates = [ev.args.get(k) for k in ("path", "file_path", "glob", "include")]
    else:
        candidates = re.split(r"[\s\"',]+", str(ev.args))
    if any(c and is_secret(c) for c in candidates):
        decide("deny", SECRET_MSG)

# --- Shell commands (best effort) ---------------------------------------------
WRITE_CMDS = re.compile(
    r"(\btee\b|\bsed\s+-\w*i|\bperl\s+-\w*i|\bcp\b|\bmv\b|\btouch\b|\btruncate\b"
    r"|\binstall\b|\bln\b|\bdd\b|\brsync\b|\bchmod\b|\bchown\b|\bpatch\b"
    r"|\b(python3?|perl|ruby|node|php)\b|\bgit\s+(checkout|restore|reset|apply|stash|rm|mv|clean)\b"
    r"|\brm\b|\brmdir\b|\bunlink\b|\bshred\b|-delete\b|-exec\b"
    r"|set-content|add-content|out-file|new-item|remove-item|move-item|copy-item)", re.I)
DELETE_VERBS = re.compile(
    r"(\b(rm|rmdir|mv|unlink|shred)\b|\bgit\s+(rm|mv|clean)\b|-delete\b"
    r"|remove-item|move-item)", re.I)
MOVE_ONLY = re.compile(r"\b(mv|git\s+mv|move-item)\b", re.I)
SEGMENT_SPLIT = re.compile(r"&&|\|\||;|\n|(?<![>&<])&(?![>&])|\|")
REDIRECT = re.compile(r"\d*>>?\s*([^\s;|&<>]+)")
CD = re.compile(r"^\s*(cd|pushd|set-location)\s+(\S+)\s*$", re.I)

def tokens(segment):
    """Path-like words, also inside quotes and code (python -c "open('x')")
    and after '=' (dd of=x). Options (-rf) are skipped."""
    return [t for t in re.findall(r"[^\s'\"();,|&<>`=]+", segment) if not t.startswith("-")]

def check_shell(cmd, cwd):
    # Normalize: ">|" is a redirection; "a//b" and "a/./b" are "a/b"
    cmd = cmd.replace(">|", ">")
    cmd = re.sub(r"\$\{?PWD\}?|\$\(pwd\)", lambda _: cwd, cmd)
    cmd = re.sub(r"/+", "/", cmd)
    while "/./" in cmd:
        cmd = cmd.replace("/./", "/")

    for tok in re.findall(r"[^\s'\";|&<>()`]+", cmd):
        if is_secret(tok):
            decide("deny", SECRET_MSG + " (including via the shell)")

    here = cwd
    for segment in SEGMENT_SPLIT.split(cmd):
        if not segment.strip():
            continue
        m = CD.match(segment)
        if m:
            here = payload.resolve(m.group(2), here)
            continue
        redirected = [payload.relative(payload.resolve(t, here)) for t in REDIRECT.findall(segment)]
        writes = bool(redirected) or bool(WRITE_CMDS.search(segment))
        mentioned = [payload.relative(payload.resolve(t, here)) for t in tokens(segment)]
        targets = redirected + (mentioned if WRITE_CMDS.search(segment) else [])
        for rel in targets:
            if payload.is_protected(rel):
                deny_protected(rel, " (via the shell)")
            if is_log(rel):
                decide("deny", LOG_MSG)
        if DELETE_VERBS.search(segment):
            in_memory = [r for r in mentioned if in_mem(r)]
            if not in_memory:
                continue
            is_move = MOVE_ONLY.search(segment) and not re.search(
                r"\b(rm|rmdir|unlink|shred)\b|-delete\b|remove-item", segment, re.I)
            allowed = all(within(r, MAY_DELETE) for r in in_memory) or (
                is_move and all(within(r, MAY_MOVE) for r in in_memory))
            if not allowed:
                decide("deny", DEL_MSG)

try:
    import payload
    raw, data = payload.read_input()
    if not data and raw.strip():
        raise ValueError("unparseable payload")
    ev = payload.Event(data)
    if ev.kind == "write":
        check_file_ops(ev)
    elif ev.kind == "shell":
        check_shell(ev.command(), ev.cwd)
    elif ev.tool.lower() in ("view", "read", "grep", "rg"):
        check_read(ev)
except SystemExit:
    raise
except Exception:
    # Never crash (Copilot would deny EVERY tool call). Stay safe on the
    # rules that matter most: protected paths and secret files.
    low = raw.lower()
    for path in ("memory/organization", ".github/hooks/memory-kit", ".github/skills/dreaming",
                 ".github/skills/lesson", ".github/skills/memorize"):
        if path in low:
            decide("deny", ORG_MSG if path.startswith("memory") else KIT_MSG)
    if re.search(r"(^|[/\s\"'])(\.env|\.envrc|\.netrc|id_rsa|id_ed25519)([\s\"']|$)|\.pem\b", low):
        decide("deny", SECRET_MSG)
sys.exit(0)   # nothing to say: the call goes through the normal permission flow
PYTHON
exit 0
