"""
copilot_sessions.py — find and measure this project's GitHub Copilot CLI sessions.

Copilot CLI keeps one folder per session in ~/.copilot/session-state/<id>/
(override with $COPILOT_HOME): workspace.yaml says where the session ran
(cwd, git_root), events.jsonl is the full event log (messages, tool calls,
token usage, AI credits).

Used by dream.sh and token-report.sh:
  python3 copilot_sessions.py list   <project> <days> <max>   → events.jsonl paths
  python3 copilot_sessions.py report <project> <days>         → token report
  python3 copilot_sessions.py usage  <usage-output-file>      → one-line bill
"""
import json
import os
import sys
import time
from collections import defaultdict

STATE = os.path.join(os.environ.get("COPILOT_HOME") or os.path.expanduser("~/.copilot"),
                     "session-state")
# First words of a dreaming session (dream.sh's prompt, /dreaming apply,
# and the prompt used by earlier versions of the kit)
DREAM_MARKERS = ("/dreaming", "Use the /dreaming skill")


def read_workspace(folder):
    info = {}
    try:
        with open(os.path.join(folder, "workspace.yaml"), encoding="utf-8") as f:
            for line in f:
                key, sep, value = line.partition(":")
                if sep and key in ("cwd", "git_root", "name"):
                    info[key] = value.strip().strip("'\"")
    except OSError:
        pass
    return info


def belongs(info, project):
    for key in ("git_root", "cwd"):
        path = info.get(key)
        if not path:
            continue
        path = os.path.realpath(path)
        if path == project or (key == "cwd" and path.startswith(project + os.sep)):
            return True
    return False


def find_sessions(project, days, include_dreams=False):
    """events.jsonl paths of this project's sessions, most recent first."""
    project = os.path.realpath(project)
    cutoff = time.time() - days * 86400
    found = []
    try:
        names = os.listdir(STATE)
    except OSError:
        return []
    for name in names:
        folder = os.path.join(STATE, name)
        events = os.path.join(folder, "events.jsonl")
        try:
            mtime = os.path.getmtime(events)
        except OSError:
            continue
        if mtime < cutoff:
            continue
        info = read_workspace(folder)
        if not belongs(info, project):
            continue
        if not include_dreams and info.get("name", "").startswith(DREAM_MARKERS):
            continue   # don't dream about previous dreams
        found.append((mtime, events))
    return [path for _, path in sorted(found, reverse=True)]


def measure(events_path):
    """Token usage per model + AI credits for one session."""
    by_model = defaultdict(lambda: defaultdict(int))
    nano_aiu = 0.0
    with open(events_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"session.usage' not in line and '"session.shutdown"' not in line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            kind, data = obj.get("type"), obj.get("data") or {}
            if kind == "session.usage_record":
                u = data.get("usage") or {}
                m = by_model[u.get("model") or "?"]
                m["requests"] += 1
                m["input"] += u.get("inputTokens") or 0
                m["cache_read"] += u.get("cacheReadTokens") or 0
                m["cache_write"] += u.get("cacheWriteTokens") or 0
                m["output"] += u.get("outputTokens") or 0
            elif kind == "session.usage_checkpoint":
                nano_aiu = max(nano_aiu, float(data.get("totalNanoAiu") or 0))
            elif kind == "session.shutdown":
                snap = data.get("accountingSnapshot") or {}
                nano_aiu = max(nano_aiu, float(snap.get("totalNanoAiu") or 0))
    return by_model, nano_aiu / 1e9


def report(project, days):
    sessions = find_sessions(project, days, include_dreams=True)
    totals = defaultdict(int)
    by_model = defaultdict(int)
    credits = 0.0
    for path in sessions:
        models, session_credits = measure(path)
        credits += session_credits
        for model, m in models.items():
            for key, value in m.items():
                totals[key] += value
            by_model[model] += m["output"]
    print(f"📊 Copilot CLI usage for this project — last {days} day(s)")
    print(f"   Sessions               : {len(sessions):>12,}")
    print(f"   Model requests         : {totals['requests']:>12,}")
    print(f"   Input tokens (total)   : {totals['input']:>12,}")
    print(f"     of which cache read  : {totals['cache_read']:>12,}")
    print(f"     of which cache write : {totals['cache_write']:>12,}")
    print(f"   Output tokens          : {totals['output']:>12,}")
    print(f"   AI credits             : {credits:>12,.2f}")
    if by_model:
        print("   By model (output tokens):")
        for model, value in sorted(by_model.items(), key=lambda x: -x[1]):
            print(f"     {model:35s} {value:>10,}")
    print()
    print("ℹ️  Live view inside a session: /usage (credits, quota) and /context (window).")
    print(f"ℹ️  Raw data: {STATE}/<session>/events.jsonl")


def usage_line(path):
    """Summarize a --usage-output-file JSON (shape not guaranteed: be lenient)."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return 0.0, ""
    flat = {}

    def walk(obj, prefix=""):
        if isinstance(obj, dict):
            for k, v in obj.items():
                walk(v, f"{prefix}{k}.")
        elif isinstance(obj, (int, float)):
            flat[prefix[:-1]] = obj
    walk(data)
    credits = 0.0
    for key, value in flat.items():
        low = key.lower()
        if low.endswith("nanoaiu"):
            credits = max(credits, value / 1e9)
        elif "aicredit" in low.replace("_", "") and not low.endswith("limit"):
            credits = max(credits, float(value))
    return credits, json.dumps(data)[:400]


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "list":
        for p in find_sessions(sys.argv[2], int(sys.argv[3]))[: int(sys.argv[4])]:
            print(p)
    elif cmd == "report":
        report(sys.argv[2], int(sys.argv[3]))
    elif cmd == "usage":
        credits, _ = usage_line(sys.argv[2])
        print(f"{credits:.2f}")
    else:
        sys.exit(__doc__)
