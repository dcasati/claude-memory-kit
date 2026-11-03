#!/bin/bash
# ============================================================================
# Stop hook — token consumption watchdog
#
# This script runs at the end of each agent response. It reads the session
# transcript (.jsonl file maintained by Claude Code) to measure two things:
#   1. the current CONTEXT SIZE (what the model re-reads on every turn);
#   2. the CUMULATIVE tokens produced since the session started.
# If a threshold is crossed, an alert is shown to the user
# (via "systemMessage") — only once per threshold per session.
#
# Default thresholds (adjustable via environment variables):
#   KITMEM_CONTEXT_THRESHOLD    = 120000 tokens (context is getting heavy → /compact)
#   KITMEM_CUMULATIVE_THRESHOLD = 150000 tokens produced (big session → take a break?)
# ============================================================================

# Claude Code's JSON arrives on stdin; we store it in an environment
# variable because the heredoc below already occupies python's stdin.
KITMEM_HOOK_INPUT=$(cat)
export KITMEM_HOOK_INPUT

python3 - <<'PYTHON'
import json, os, sys, tempfile

d = json.loads(os.environ.get("KITMEM_HOOK_INPUT") or "{}")
transcript = d.get("transcript_path") or ""
session = (d.get("session_id") or "unknown")[:8]
if not transcript or not os.path.exists(transcript):
    sys.exit(0)

CONTEXT_THRESHOLD = int(os.environ.get("KITMEM_CONTEXT_THRESHOLD", "120000"))
CUMULATIVE_THRESHOLD = int(os.environ.get("KITMEM_CUMULATIVE_THRESHOLD", "150000"))

context = 0          # context size at the last turn
cumulative_out = 0   # total tokens generated during the session
try:
    with open(transcript, encoding="utf-8") as f:
        for line in f:
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            usage = ((obj.get("message") or {}).get("usage")) or {}
            if not usage:
                continue
            cumulative_out += usage.get("output_tokens") or 0
            # context ≈ input tokens of the last call (cache included)
            context = (
                (usage.get("input_tokens") or 0)
                + (usage.get("cache_read_input_tokens") or 0)
                + (usage.get("cache_creation_input_tokens") or 0)
            )
except OSError:
    sys.exit(0)

def already_alerted(level):
    """True if this level's alert was already emitted for this session
    (a small marker file in the temp directory acts as memory)."""
    marker = os.path.join(tempfile.gettempdir(), f"kitmem-{session}-{level}")
    if os.path.exists(marker):
        return True
    open(marker, "w").close()
    return False

messages = []
if context >= CONTEXT_THRESHOLD and not already_alerted("context"):
    messages.append(
        f"⚠️ Memory kit — the session context has reached ≈{context:,} tokens "
        f"(threshold {CONTEXT_THRESHOLD:,}). Each turn is getting more expensive. "
        "Tip: type /compact, or ask the agent to write down the current state "
        "in memory/scratchpad/ and then start a fresh session."
    )
if cumulative_out >= CUMULATIVE_THRESHOLD and not already_alerted("cumulative"):
    messages.append(
        f"⚠️ Memory kit — this session has already produced ≈{cumulative_out:,} tokens. "
        "Unusual consumption: check your quota with /usage, and the details "
        "with scripts/token-report.sh."
    )

if messages:
    print(json.dumps({"systemMessage": "\n".join(messages)}))
sys.exit(0)
PYTHON
