#!/bin/bash
# ============================================================================
# dream.sh — runs a "Dreaming" pass (memory consolidation)
#
# An OUT-OF-BAND process in Lamis Mukta's sense: it runs outside your working
# sessions, with its own token budget, to analyze past sessions and propose
# memory improvements.
#
# Usage:
#   ./scripts/dream.sh                 # analysis (7 days, 5 sessions max)
#   ./scripts/dream.sh --days 14       # look further back
#   ./scripts/dream.sh --sessions 3    # limit the number of sessions analyzed
#   ./scripts/dream.sh --yes           # no confirmation prompt (for cron)
#   ./scripts/dream.sh --model claude-haiku-4-5-20251001   # cheaper model
#
# Built-in guardrails:
#   - ESTIMATE before running: estimated tokens to read, confirmation required
#     above the threshold (KITMEM_ESTIMATE_THRESHOLD, default 200,000 estimated tokens);
#   - cap on agent turns: --max-turns 40;
#   - BILL after running: actual cost displayed, ALERT if above
#     DREAM_COST_ALERT (default $2.00).
# ============================================================================
set -euo pipefail

# --- Settings (adjustable via environment variables) ------------------------
DAYS=7                 # maximum age of the sessions analyzed
MAX_SESSIONS=5         # maximum number of transcripts passed to dreaming
CONFIRM=1              # 1 = ask for confirmation if the estimate exceeds the threshold
MODEL="${DREAM_MODEL:-}"                              # empty = claude's default model
ESTIMATE_THRESHOLD="${KITMEM_ESTIMATE_THRESHOLD:-200000}"   # estimated tokens
COST_ALERT="${DREAM_COST_ALERT:-2.00}"                # dollars

while [ $# -gt 0 ]; do
  case "$1" in
    --days)     DAYS="$2"; shift 2 ;;
    --sessions) MAX_SESSIONS="$2"; shift 2 ;;
    --yes)      CONFIRM=0; shift ;;
    --model)    MODEL="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Locate the project and its transcripts ---------------------------------
# The script must be run from the project root (where memory/ lives).
PROJECT="$(pwd)"
if [ ! -d "$PROJECT/memory" ]; then
  echo "❌ No memory/ folder here. Run this script from the project root." >&2
  exit 1
fi

# Claude Code stores transcripts in ~/.claude/projects/<encoded-path>/
# (the project path with every special character replaced by a dash).
ENCODED_DIR=$(printf '%s' "$PROJECT" | sed 's/[^a-zA-Z0-9]/-/g')
TRANSCRIPTS="$HOME/.claude/projects/$ENCODED_DIR"

if [ ! -d "$TRANSCRIPTS" ]; then
  echo "❌ No transcripts found ($TRANSCRIPTS)." >&2
  echo "   You need to have used Claude Code in this project already." >&2
  exit 1
fi

# The N most recent transcripts less than DAYS days old
LIST=$(find "$TRANSCRIPTS" -maxdepth 1 -name "*.jsonl" -mtime -"$DAYS" -print0 \
  | xargs -0 ls -t 2>/dev/null | head -n "$MAX_SESSIONS" || true)

if [ -z "$LIST" ]; then
  echo "Nothing to dream about: no session less than $DAYS days old. 😴"
  exit 0
fi

# --- ESTIMATE: token estimate before spending anything ----------------------
BYTES=$(echo "$LIST" | tr '\n' '\0' | xargs -0 wc -c 2>/dev/null | tail -n 1 | awk '{print $1}')
EST_TOKENS=$(( BYTES / 4 ))   # classic approximation: 1 token ≈ 4 characters
COUNT=$(echo "$LIST" | grep -c . )

echo "🌙 Dreaming — estimate before running"
echo "   Sessions to analyze: $COUNT (most recent, < $DAYS days)"
printf "   Raw volume: %'d bytes ≈ %'d tokens (upper bound: the skill samples via grep)\n" "$BYTES" "$EST_TOKENS"

if [ "$EST_TOKENS" -gt "$ESTIMATE_THRESHOLD" ] && [ "$CONFIRM" -eq 1 ]; then
  echo "⚠️  Estimate above the threshold ($ESTIMATE_THRESHOLD tokens)."
  echo "   Tip: reduce it with --sessions 3 or --days 3."
  printf "   Continue anyway? [y/N] "
  read -r ANSWER
  case "$ANSWER" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

# --- Drop the session list for the dreaming skill ---------------------------
mkdir -p "$PROJECT/memory/scratchpad"
echo "$LIST" > "$PROJECT/memory/scratchpad/dreaming-sessions.txt"

# --- Run the pass (batch, capped) -------------------------------------------
echo "   Starting… (cap: 40 agent turns)"
ARGS=(-p "/dreaming" --max-turns 40 --output-format json)
[ -n "$MODEL" ] && ARGS+=(--model "$MODEL")

OUTPUT=$(claude "${ARGS[@]}" 2>&1) || {
  echo "❌ The dreaming pass failed:" >&2
  echo "$OUTPUT" | tail -n 5 >&2
  exit 1
}

# --- BILL: actual cost + alert ----------------------------------------------
export KITMEM_DREAM_OUTPUT="$OUTPUT"
python3 - "$COST_ALERT" <<'PYTHON'
import json, os, sys

threshold = float(sys.argv[1])
raw = os.environ.get("KITMEM_DREAM_OUTPUT") or ""
# The output is JSON; if there's stray text, isolate the JSON object.
try:
    result = json.loads(raw)
except ValueError:
    start = raw.find("{")
    result = json.loads(raw[start:]) if start >= 0 else {}

cost = result.get("total_cost_usd") or 0.0
duration = (result.get("duration_ms") or 0) / 1000
turns = result.get("num_turns") or "?"
text = (result.get("result") or "").strip()

print()
print("🌙 Dreaming finished — actual bill")
print(f"   Cost: ${cost:.4f} · Duration: {duration:.0f}s · Turns: {turns}")
if cost > threshold:
    print(f"   🚨 ALERT: cost above the threshold (${threshold:.2f})!")
    print("      Reduce --sessions/--days or switch to a cheaper model")
    print("      (--model claude-haiku-4-5-20251001) for future passes.")
print()
if text:
    print("── Pass summary ────────────────────────────────────")
    print(text)
PYTHON

# Clean up the session list
rm -f "$PROJECT/memory/scratchpad/dreaming-sessions.txt"

echo
echo "➡️  Next step: open memory/proposals/, mark [OK]/[NO],"
echo "   then run:  claude \"/dreaming apply\""
