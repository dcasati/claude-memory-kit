#!/usr/bin/env bash
# shfmt -i 2 -ci -w
set -Eeuo pipefail

trap exit SIGINT SIGTERM

################################################################################
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
#   - LEAST PRIVILEGE: nobody approves tool calls during the pass, and the
#     session logs it reads contain untrusted text (web pages, command
#     output). So the agent only gets file tools — no shell, no web, no MCP
#     servers — and can only read COPIES of the selected session logs, not
#     ~/.copilot. The memory hooks stay active and revert any change outside
#     what dreaming may touch;
#   - ESTIMATE before running: estimated tokens to read, confirmation required
#     above the threshold (KITMEM_ESTIMATE_THRESHOLD, default 200,000 tokens);
#   - hard budget: --max-ai-credits (DREAM_MAX_CREDITS, default 50);
#   - BILL after running: AI credits used, ALERT above DREAM_CREDITS_ALERT
#     (default 25 credits).
# The scratchpad purge (files older than 7 days) is done by this script, not
# by the agent.

################################################################################
# Default configuration
DREAM_DAYS=${DREAM_DAYS:-7}                                   # max age of sessions
DREAM_SESSIONS=${DREAM_SESSIONS:-5}                           # max sessions analyzed
DREAM_MODEL=${DREAM_MODEL:-}                                  # empty = Copilot's default
KITMEM_ESTIMATE_THRESHOLD=${KITMEM_ESTIMATE_THRESHOLD:-200000} # estimated tokens
DREAM_MAX_CREDITS=${DREAM_MAX_CREDITS:-50}                    # hard cap per pass
DREAM_CREDITS_ALERT=${DREAM_CREDITS_ALERT:-25}                # alert threshold
SCRATCHPAD_MAX_DAYS=${SCRATCHPAD_MAX_DAYS:-7}                 # scratchpad purge age
################################################################################

# Tools available to the dreaming agent (file tools only: see above)
DREAM_TOOLS=(view grep glob create edit apply_patch skill)

__usage="
    --days N          only sessions from the last N days (default ${DREAM_DAYS})
    --sessions N      analyze at most N sessions (default ${DREAM_SESSIONS})
    --yes             no confirmation prompt (for cron)
    --model NAME      Copilot model to use (default: Copilot's default)
    --max-credits N   hard AI-credit cap for the pass (default ${DREAM_MAX_CREDITS})

Environment variables (with defaults):
    DREAM_DAYS=${DREAM_DAYS}
    DREAM_SESSIONS=${DREAM_SESSIONS}
    DREAM_MODEL=${DREAM_MODEL}
    KITMEM_ESTIMATE_THRESHOLD=${KITMEM_ESTIMATE_THRESHOLD}
    DREAM_MAX_CREDITS=${DREAM_MAX_CREDITS}
    DREAM_CREDITS_ALERT=${DREAM_CREDITS_ALERT}
    SCRATCHPAD_MAX_DAYS=${SCRATCHPAD_MAX_DAYS}
"

usage() {
  echo "usage: ${0##*/} [options]"
  echo "${__usage/[[:space:]]/}"
  exit 1
}

log() {
  echo "[$(date +"%r")] $*"
}

die() {
  log "❌ $*" >&2
  exit 1
}

# need_value <option> <value>: options that take an argument
need_value() {
  [ -n "${2:-}" ] || die "$1 needs a value."
}

# need_number <option> <value>: positive number (integer or decimal)
need_number() {
  need_value "$1" "${2:-}"
  [[ "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ "$2" =~ [1-9] ]] || die "$1 must be a positive number (got: $2)."
}

parse_args() {
  CONFIRM=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --days)
        need_number "$1" "${2:-}"
        DREAM_DAYS="$2"
        shift 2
        ;;
      --sessions)
        need_number "$1" "${2:-}"
        DREAM_SESSIONS="$2"
        shift 2
        ;;
      --yes)
        CONFIRM=0
        shift
        ;;
      --model)
        need_value "$1" "${2:-}"
        DREAM_MODEL="$2"
        shift 2
        ;;
      --max-credits)
        need_number "$1" "${2:-}"
        DREAM_MAX_CREDITS="$2"
        shift 2
        ;;
      -h | --help) usage ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        ;;
    esac
  done
  [[ "$DREAM_DAYS" =~ ^[0-9]+$ ]] || die "--days must be a whole number."
  [[ "$DREAM_SESSIONS" =~ ^[0-9]+$ ]] || die "--sessions must be a whole number."
  # Copilot CLI refuses --max-ai-credits below 30
  awk -v c="$DREAM_MAX_CREDITS" 'BEGIN { exit !(c + 0 >= 30) }' ||
    die "--max-credits must be at least 30 (Copilot CLI minimum)."
}

check_dependencies() {
  command -v copilot >/dev/null 2>&1 || die "GitHub Copilot CLI (copilot) not found in PATH."
  command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH."
  [ -d "$PROJECT/memory" ] || die "No memory/ folder here. Run this script from the project root."
}

purge_scratchpad() {
  local _old
  _old=$(find "$PROJECT/memory/scratchpad" -type f ! -name README.md \
    -mtime +"$SCRATCHPAD_MAX_DAYS" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$_old" -gt 0 ]; then
    find "$PROJECT/memory/scratchpad" -type f ! -name README.md \
      -mtime +"$SCRATCHPAD_MAX_DAYS" -delete
    log "Scratchpad: $_old file(s) older than $SCRATCHPAD_MAX_DAYS days removed."
  fi
}

# estimate <session list>: token estimate before spending anything
estimate() {
  local _bytes=0 _count _tokens _f
  while IFS= read -r _f; do
    _bytes=$((_bytes + $(wc -c <"$_f")))
  done <<<"$1"
  _tokens=$((_bytes / 4)) # classic approximation: 1 token ≈ 4 characters
  _count=$(printf '%s\n' "$1" | grep -c .)

  log "🌙 Dreaming — estimate before running"
  log "   Sessions to analyze: $_count (most recent, < $DREAM_DAYS days)"
  log "   Raw volume: $_bytes bytes ≈ $_tokens tokens (upper bound: the skill samples via grep)"
  log "   Hard budget: $DREAM_MAX_CREDITS AI credits"

  if [ "$_tokens" -gt "$KITMEM_ESTIMATE_THRESHOLD" ] && [ "$CONFIRM" -eq 1 ]; then
    log "⚠️  Estimate above the threshold ($KITMEM_ESTIMATE_THRESHOLD tokens)."
    log "   Tip: reduce it with --sessions 3 or --days 3."
    printf "   Continue anyway? [y/N] "
    local _answer
    read -r _answer
    case "$_answer" in
      y | Y | yes | YES) ;;
      *)
        log "Cancelled."
        exit 0
        ;;
    esac
  fi
}

# stage_sessions <session list>: copy the logs the agent may read
stage_sessions() {
  local _f _id
  : >"$PROJECT/memory/scratchpad/dreaming-sessions.txt"
  while IFS= read -r _f; do
    _id=$(basename "$(dirname "$_f")")
    cp "$_f" "$WORK/$_id.jsonl"
    echo "$WORK/$_id.jsonl" >>"$PROJECT/memory/scratchpad/dreaming-sessions.txt"
  done <<<"$1"
}

cleanup() {
  rm -rf "${WORK:-}" "${USAGE_FILE:-}"
  rm -f "${PROJECT:-.}/memory/scratchpad/dreaming-sessions.txt"
}

do_dream() {
  local _list _args _output _credits

  # The N most recent Copilot CLI sessions of this project, < N days old
  # (previous dreaming passes are excluded)
  _list=$(python3 "$HERE/copilot_sessions.py" list "$PROJECT" "$DREAM_DAYS" "$DREAM_SESSIONS")
  if [ -z "$_list" ]; then
    log "Nothing to dream about: no Copilot CLI session in this project in the last $DREAM_DAYS days. 😴"
    exit 0
  fi

  estimate "$_list"
  mkdir -p "$PROJECT/memory/scratchpad"
  purge_scratchpad

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/kitmem-dream.XXXXXX")
  USAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/kitmem-dream-usage.XXXXXX")
  trap cleanup EXIT
  stage_sessions "$_list"

  # --allow-all-tools: no one is there to approve tool calls, so the tool
  #   set itself is restricted (--available-tools, no built-in MCP servers,
  #   no automatic temp-dir access) and the memory hooks stay active.
  # --add-dir: read access to the session-log copies only.
  log "   Starting… (Copilot CLI, non-interactive, file tools only)"
  _args=(-p "/dreaming Run the analysis pass now on the sessions listed in memory/scratchpad/dreaming-sessions.txt."
    --available-tools "${DREAM_TOOLS[@]}"
    --disable-builtin-mcps
    --disallow-temp-dir
    --add-dir "$WORK"
    --allow-all-tools --no-ask-user -s
    --max-ai-credits "$DREAM_MAX_CREDITS"
    --usage-output-file "$USAGE_FILE")
  [ -n "$DREAM_MODEL" ] && _args+=(--model "$DREAM_MODEL")

  if ! _output=$(copilot "${_args[@]}" 2>&1); then
    log "❌ The dreaming pass failed:" >&2
    printf '%s\n' "$_output" | tail -n 5 >&2
    exit 1
  fi

  # BILL: AI credits + alert
  _credits=$(python3 "$HERE/copilot_sessions.py" usage "$USAGE_FILE")
  echo
  log "🌙 Dreaming finished — actual bill"
  log "   AI credits: $_credits (alert threshold $DREAM_CREDITS_ALERT, hard cap $DREAM_MAX_CREDITS)"
  if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)' \
    "$_credits" "$DREAM_CREDITS_ALERT"; then
    log "   🚨 ALERT: cost above the threshold!"
    log "      Reduce --sessions/--days or use a cheaper model"
    log "      (--model claude-haiku-4.5) for future passes."
  fi
  echo
  if [ -n "$_output" ]; then
    echo "── Pass summary ────────────────────────────────────"
    printf '%s\n' "$_output"
  fi

  echo
  log "➡️  Next step: open memory/proposals/, mark [OK]/[NO],"
  log "   then run:  copilot -i \"/dreaming apply\""
}

################################################################################
# Entry point
main() {
  parse_args "$@"
  PROJECT="$(pwd)"
  HERE="$(cd "$(dirname "$0")" && pwd)"
  export PYTHONDONTWRITEBYTECODE=1
  check_dependencies
  do_dream
}

main "$@"
exit 0
