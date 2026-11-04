#!/bin/bash
# ============================================================================
# dream.sh — runs a "Dreaming" pass (memory consolidation) with Copilot CLI
#
# An OUT-OF-BAND process in Lamis Mukta's sense: it runs outside your working
# sessions, with its own budget, to analyze past sessions and propose memory
# improvements.
#
# Usage (from the project root):
#   ./scripts/dream.sh                 # analysis (7 days, 5 sessions max)
#   ./scripts/dream.sh --days 14       # look further back
#   ./scripts/dream.sh --sessions 3    # limit the number of sessions analyzed
#   ./scripts/dream.sh --yes           # no confirmation prompt (for cron)
#   ./scripts/dream.sh --model claude-haiku-4.5   # cheaper model
#   ./scripts/dream.sh --max-credits 20           # hard AI-credit cap
#
# Built-in guardrails:
#   - ESTIMATE before running: estimated tokens to read, confirmation required
#     above the threshold (KITMEM_ESTIMATE_THRESHOLD, default 200,000 tokens);
#   - hard budget: --max-ai-credits (DREAM_MAX_CREDITS, default 50);
#   - BILL after running: AI credits used, ALERT above DREAM_CREDITS_ALERT
#     (default 25 credits).
# The memory guardrail hooks stay active during the pass: the agent can only
# write proposals, purge the scratchpad and annotate the error log.
# ============================================================================
set -euo pipefail

# --- Settings (adjustable via environment variables) ------------------------
DAYS=7                 # maximum age of the sessions analyzed
MAX_SESSIONS=5         # maximum number of sessions passed to dreaming
CONFIRM=1              # 1 = ask for confirmation if the estimate exceeds the threshold
MODEL="${DREAM_MODEL:-}"                                    # empty = Copilot's default model
ESTIMATE_THRESHOLD="${KITMEM_ESTIMATE_THRESHOLD:-200000}"   # estimated tokens
MAX_CREDITS="${DREAM_MAX_CREDITS:-50}"                      # hard cap per pass
CREDITS_ALERT="${DREAM_CREDITS_ALERT:-25}"                  # alert threshold

while [ $# -gt 0 ]; do
  case "$1" in
    --days)        DAYS="$2"; shift 2 ;;
    --sessions)    MAX_SESSIONS="$2"; shift 2 ;;
    --yes)         CONFIRM=0; shift ;;
    --model)       MODEL="$2"; shift 2 ;;
    --max-credits) MAX_CREDITS="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

command -v copilot >/dev/null 2>&1 || { echo "❌ GitHub Copilot CLI (copilot) not found in PATH." >&2; exit 1; }

# --- Locate the project and its sessions ------------------------------------
# The script must be run from the project root (where memory/ lives).
PROJECT="$(pwd)"
if [ ! -d "$PROJECT/memory" ]; then
  echo "❌ No memory/ folder here. Run this script from the project root." >&2
  exit 1
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
STATE="${COPILOT_HOME:-$HOME/.copilot}/session-state"

# The N most recent Copilot CLI sessions of this project, < DAYS days old
# (previous dreaming passes are excluded)
LIST=$(python3 "$HERE/copilot_sessions.py" list "$PROJECT" "$DAYS" "$MAX_SESSIONS")

if [ -z "$LIST" ]; then
  echo "Nothing to dream about: no Copilot CLI session in this project in the last $DAYS days. 😴"
  exit 0
fi

# --- ESTIMATE: token estimate before spending anything ----------------------
BYTES=0
while IFS= read -r f; do
  BYTES=$(( BYTES + $(wc -c < "$f") ))
done <<< "$LIST"
EST_TOKENS=$(( BYTES / 4 ))   # classic approximation: 1 token ≈ 4 characters
COUNT=$(printf '%s\n' "$LIST" | grep -c .)

echo "🌙 Dreaming — estimate before running"
echo "   Sessions to analyze: $COUNT (most recent, < $DAYS days)"
printf "   Raw volume: %'d bytes ≈ %'d tokens (upper bound: the skill samples via grep)\n" "$BYTES" "$EST_TOKENS"
echo "   Hard budget: $MAX_CREDITS AI credits"

if [ "$EST_TOKENS" -gt "$ESTIMATE_THRESHOLD" ] && [ "$CONFIRM" -eq 1 ]; then
  echo "⚠️  Estimate above the threshold ($ESTIMATE_THRESHOLD tokens)."
  echo "   Tip: reduce it with --sessions 3 or --days 3."
  printf "   Continue anyway? [y/N] "
  read -r ANSWER
  case "$ANSWER" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

# --- Drop the session list for the dreaming skill ---------------------------
mkdir -p "$PROJECT/memory/scratchpad"
printf '%s\n' "$LIST" > "$PROJECT/memory/scratchpad/dreaming-sessions.txt"
USAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/kitmem-dream-usage.XXXXXX")
trap 'rm -f "$USAGE_FILE" "$PROJECT/memory/scratchpad/dreaming-sessions.txt"' EXIT

# --- Run the pass (non-interactive, capped) ---------------------------------
# --allow-all-tools: no one is there to approve tool calls; the memory
#   guardrail hooks still deny any write outside what dreaming may touch.
# --add-dir: lets the agent read the session logs outside the project.
echo "   Starting… (Copilot CLI, non-interactive)"
ARGS=(-p "Use the /dreaming skill to run an analysis pass on this project's memory."
      --allow-all-tools --no-ask-user -s
      --add-dir "$STATE"
      --max-ai-credits "$MAX_CREDITS"
      --usage-output-file "$USAGE_FILE")
[ -n "$MODEL" ] && ARGS+=(--model "$MODEL")

if ! OUTPUT=$(copilot "${ARGS[@]}" 2>&1); then
  echo "❌ The dreaming pass failed:" >&2
  printf '%s\n' "$OUTPUT" | tail -n 5 >&2
  exit 1
fi

# --- BILL: AI credits + alert -----------------------------------------------
CREDITS=$(python3 "$HERE/copilot_sessions.py" usage "$USAGE_FILE")
echo
echo "🌙 Dreaming finished — actual bill"
echo "   AI credits: $CREDITS (alert threshold $CREDITS_ALERT, hard cap $MAX_CREDITS)"
if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)' "$CREDITS" "$CREDITS_ALERT"; then
  echo "   🚨 ALERT: cost above the threshold!"
  echo "      Reduce --sessions/--days or use a cheaper model"
  echo "      (--model claude-haiku-4.5) for future passes."
fi
echo
if [ -n "$OUTPUT" ]; then
  echo "── Pass summary ────────────────────────────────────"
  printf '%s\n' "$OUTPUT"
fi

echo
echo "➡️  Next step: open memory/proposals/, mark [OK]/[NO],"
echo "   then run:  copilot -i \"/dreaming apply\""
