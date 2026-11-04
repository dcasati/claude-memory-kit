#!/usr/bin/env bash
# shfmt -i 2 -ci -w
# No `set -e` on purpose: a hook must never fail the session it serves.
# ============================================================================
# agentStop hook — token / AI-credit consumption watchdog
#
# Runs at the end of each agent turn. It reads the session's event log
# (~/.copilot/session-state/<session>/events.jsonl, given as transcriptPath)
# to measure three things:
#   1. the current CONTEXT SIZE (what the model re-reads on every request);
#   2. the cumulative OUTPUT tokens produced since the session started;
#   3. the AI CREDITS consumed by the session so far.
# If a threshold is crossed, a warning is shown to the user (stderr + exit 2,
# which Copilot CLI displays without blocking) — once per threshold per session.
#
# Default thresholds (adjustable via environment variables):
#   KITMEM_CONTEXT_THRESHOLD    = 120000 tokens, or 60% of the model's
#                                 context window if smaller (→ /compact)
#   KITMEM_CUMULATIVE_THRESHOLD = 150000 output tokens (big session → break?)
#   KITMEM_CREDITS_THRESHOLD    = 100 AI credits
# ============================================================================
command -v python3 >/dev/null 2>&1 || exit 0
HERE="$(cd "$(dirname "$0")" && pwd)"

# The Python code comes in on fd 3, so stdin stays the hook's JSON payload
python3 /dev/fd/3 "$HERE" 3<<'PYTHON'
import json, os, sys, tempfile
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import payload

ev = payload.Event(payload.read_input()[1])
transcript = ev.transcript or (
    os.path.expanduser(f"~/.copilot/session-state/{ev.session}/events.jsonl") if ev.session else "")
if not transcript or not os.path.exists(transcript):
    sys.exit(0)

context = window = output = 0
nano_aiu = 0.0
try:
    with open(transcript, encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"session.usage' not in line and '"session.shutdown"' not in line:
                continue   # cheap pre-filter: the file can be large
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            kind, data = obj.get("type"), obj.get("data") or {}
            if kind == "session.usage_record":
                u = data.get("usage") or {}
                output += u.get("outputTokens") or 0
                if (u.get("interactionType") or "conversation-agent") == "conversation-agent":
                    context = u.get("inputTokens") or context   # last main-agent request
                    window = u.get("maxPromptTokens") or window
            elif kind == "session.usage_checkpoint":
                nano_aiu = max(nano_aiu, float(data.get("totalNanoAiu") or 0))
            elif kind == "session.shutdown":
                snap = data.get("accountingSnapshot") or {}
                nano_aiu = max(nano_aiu, float(snap.get("totalNanoAiu") or 0))
except OSError:
    sys.exit(0)
credits = nano_aiu / 1e9

ctx_threshold = int(os.environ.get("KITMEM_CONTEXT_THRESHOLD", "120000"))
if window and "KITMEM_CONTEXT_THRESHOLD" not in os.environ:
    ctx_threshold = min(ctx_threshold, int(window * 0.6))
out_threshold = int(os.environ.get("KITMEM_CUMULATIVE_THRESHOLD", "150000"))
credit_threshold = float(os.environ.get("KITMEM_CREDITS_THRESHOLD", "100"))

def already_alerted(level):
    """True if this level's alert was already emitted for this session
    (a small marker file in the temp directory acts as memory)."""
    marker = os.path.join(tempfile.gettempdir(), f"kitmem-{ev.short_session}-{level}")
    try:
        # O_EXCL + O_NOFOLLOW: never open (or truncate) a file planted by
        # someone else, e.g. a symlink in a shared /tmp
        os.close(os.open(marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY
                         | getattr(os, "O_NOFOLLOW", 0), 0o600))
    except FileExistsError:
        return True
    except OSError:
        return True    # can't keep track: stay quiet rather than repeat
    return False

messages = []
if context >= ctx_threshold and not already_alerted("context"):
    pct = f" ({context * 100 // window}% of the window)" if window else ""
    messages.append(
        f"⚠️ Memory kit — the session context has reached ≈{context:,} tokens{pct}, "
        f"threshold {ctx_threshold:,}. Each turn is getting more expensive. "
        "Tip: type /compact, or ask the agent to save the current state in "
        "memory/scratchpad/ and then start a fresh session (/new).")
if output >= out_threshold and not already_alerted("cumulative"):
    messages.append(
        f"⚠️ Memory kit — this session has already produced ≈{output:,} output tokens. "
        "Unusual consumption: check /usage, and the details with scripts/token-report.sh.")
if credits >= credit_threshold and not already_alerted("credits"):
    messages.append(
        f"⚠️ Memory kit — this session has used ≈{credits:.1f} AI credits "
        f"(threshold {credit_threshold:g}). Check /usage; cap future runs with /limits.")
if messages:
    print("\n".join(messages), file=sys.stderr)
    sys.exit(2)   # agentStop: exit 2 = show stderr to the user, nothing is blocked
PYTHON
[ $? -eq 2 ] && exit 2
exit 0
