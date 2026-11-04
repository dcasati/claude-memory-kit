#!/usr/bin/env bash
# shfmt -i 2 -ci -w
# No `set -e` on purpose: a hook must never fail the tool call it follows.
# ============================================================================
# postToolUse hook — memory integrity + "versioning" guardrail
# (Lamis Mukta's recommendations: the shared memory is read-only for the
#  agent, and every memory write is attributed — session, timestamp — with a
#  full history to inspect and roll back.)
#
# Runs AFTER every tool call, whatever the tool (file tools, shell, sub-agents,
# MCP servers…). It checks the RESULT, not the command, so it also catches
# writes the preToolUse guard could not predict:
#   1. any uncommitted change to a protected path — memory/organization/ and
#      the kit's own hooks and skills — is REVERTED to the last commit;
#   2. any committed file deleted under memory/ (except scratchpad/ and
#      proposals/) is RESTORED;
#   3. everything else that changed under memory/ is committed:
#      "memory: lessons/foo.md (auto-commit, session abc12345)".
# Reverted content is kept in .git/memory-kit/reverted/<timestamp>/ so a
# human edit made during a session is never lost: edit protected files
# between sessions, and commit them.
# The commit runs the project's own git hooks (no --no-verify), so a
# pre-commit secret scanner also sees what the agent wrote. If a hook
# rejects the commit, the changes stay uncommitted and the agent is told.
# ============================================================================
command -v python3 >/dev/null 2>&1 || exit 0
HERE="$(cd "$(dirname "$0")" && pwd)"

# The Python code comes in on fd 3, so stdin stays the hook's JSON payload
python3 /dev/fd/3 "$HERE" 3<<'PYTHON'
import fcntl, json, os, shutil, subprocess, sys, time
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import payload

ROOT = payload.ROOT
if not os.path.isdir(os.path.join(ROOT, "memory")):
    sys.exit(0)

def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True)

if git("rev-parse", "--is-inside-work-tree").returncode != 0:
    sys.exit(0)   # no git repo: versioning is impossible, don't block
git_dir = git("rev-parse", "--absolute-git-dir").stdout.strip()
state = os.path.join(git_dir, "memory-kit")
os.makedirs(state, exist_ok=True)

ev = payload.Event(payload.read_input()[1])
notes = []

# Parallel tool calls run this hook concurrently: serialize git operations
with open(os.path.join(state, "lock"), "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)

    def changed(*paths):
        """[(status, path)] of uncommitted changes under `paths`."""
        out = git("status", "--porcelain=v1", "-z", "--untracked-files=all", "--", *paths).stdout
        items, parts = [], out.split("\0")
        i = 0
        while i < len(parts):
            entry = parts[i]
            i += 1
            if len(entry) < 4:
                continue
            code, path = entry[:2], entry[3:]
            items.append((code, path))
            if "R" in code or "C" in code:     # renames: the next field is the source
                items.append(("D ", parts[i]))
                i += 1
        return items

    def in_head(path):
        return git("cat-file", "-e", f"HEAD:{path}").returncode == 0

    backup = os.path.join(state, "reverted", time.strftime("%Y%m%d-%H%M%S"))

    def revert(path):
        full = os.path.join(ROOT, path)
        if os.path.lexists(full) and not os.path.isdir(full):
            dest = os.path.join(backup, path)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copy2(full, dest, follow_symlinks=False)
        if in_head(path):
            git("checkout", "HEAD", "--", path)
        else:
            git("rm", "-q", "--cached", "--ignore-unmatch", "--", path)
            if os.path.lexists(full) and not os.path.isdir(full):
                os.remove(full)

    has_head = git("rev-parse", "--verify", "-q", "HEAD").returncode == 0

    # 1. Protected paths must match the last commit. Only paths that ARE in
    #    the last commit are protected: an uncommitted kit has no baseline
    #    (reverting would delete it).
    baseline = [p for p in payload.PROTECTED
                if has_head and git("ls-tree", "-r", "--name-only", "HEAD", "--", p).stdout.strip()]
    if baseline:
        bad = sorted({p for _, p in changed(*baseline)})
        for path in bad:
            revert(path)
        if bad:
            notes.append("Memory guardrail: reverted changes to protected files "
                         f"({', '.join(bad[:5])}{'…' if len(bad) > 5 else ''}). "
                         "memory/organization/ and the memory kit's hooks and skills are "
                         "read-only for the agent; write a proposal in memory/proposals/ "
                         f"instead. Reverted content saved in {os.path.relpath(backup, ROOT)}.")

    # 2. No deletions in memory/ (except scratchpad/ and proposals/)
    if has_head:
        gone = sorted({p for code, p in changed("memory") if "D" in code
                       and not payload.under(p, "memory/scratchpad")
                       and not payload.under(p, "memory/proposals")})
        for path in gone:
            git("checkout", "HEAD", "--", path)
        if gone:
            notes.append("Memory guardrail: deleting or moving memory files is forbidden; "
                         f"restored {', '.join(gone[:5])}. Cleanup goes through a dreaming "
                         "proposal approved by a human.")

    # 3. Commit what's left under memory/ (organization/ is never auto-committed)
    spec = ["memory", f":(exclude){payload.ORG}"]
    rest = changed(*spec)
    if rest:
        files = [p[len("memory/"):] if p.startswith("memory/") else p for _, p in rest]
        label = ", ".join(files[:3]) + (f", +{len(files) - 3} more" if len(files) > 3 else "")
        git("add", "-A", "--", *spec)
        result = git("commit", "--quiet", "-m",
                     f"memory: {label} (auto-commit, session {ev.short_session})", "--", *spec)
        if result.returncode != 0:
            git("reset", "-q", "--", *spec)     # leave the user's index as it was
            reason = (result.stderr or result.stdout).strip().splitlines()
            notes.append("Memory kit: the automatic memory commit was rejected"
                         + (f" ({reason[-1][:200]})" if reason else "")
                         + ". The changes are still in memory/, uncommitted; tell the user.")

if notes:
    print(json.dumps({"additionalContext": "\n".join(notes)}))
PYTHON
exit 0
