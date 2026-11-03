#!/bin/bash
# ============================================================================
# SessionStart hook — "progressive disclosure" of the memory
# (Lamis Mukta's recommendation: inject a lightweight INDEX, never the whole store)
#
# What this script does: everything it prints (echo) is added to the agent's
# context when the session starts. So we only inject:
#   1. the memory index (one line per memory),
#   2. the 10 most recent logged errors (so they aren't repeated),
#   3. an alert if dreaming proposals are pending.
# ============================================================================

MEM="$CLAUDE_PROJECT_DIR/memory"

# 1. The index (the library catalog, not the books)
if [ -f "$MEM/MEMORY.md" ]; then
  echo "## Project memory (index — open files only when relevant)"
  # grep -v strips HTML comment lines to save tokens
  grep -v '^<!--' "$MEM/MEMORY.md" | grep -v '^     '
  echo
fi

# 2. Recent unhandled errors (lines marked [handled …] are excluded)
if [ -f "$MEM/errors/log.md" ]; then
  RECENT=$(grep '^- ' "$MEM/errors/log.md" | grep -v '\[handled' | tail -n 10)
  if [ -n "$RECENT" ]; then
    echo "## Recently logged errors (do not repeat — see memory/errors/log.md)"
    echo "$RECENT"
    echo
  fi
fi

# 3. Dreaming proposals awaiting human approval?
if ls "$MEM/proposals/"*dreaming*.md >/dev/null 2>&1; then
  if ls "$MEM/proposals/"*dreaming*.md 2>/dev/null | grep -qv -- '-done\.md$'; then
    echo "⚠️ Dreaming proposals are awaiting human approval in memory/proposals/. Let the user know."
  fi
fi

exit 0
