#!/usr/bin/env bash
# shfmt -i 2 -ci -w
# ============================================================================
# install.sh — installs the memory kit into a project (GitHub Copilot CLI)
#
# Usage:
#   ./install.sh /path/to/your/project
#   ./install.sh .                  # install into the current folder
#   ./install.sh --force /path      # also overwrite the kit's own hooks,
#                                   # skills and scripts (upgrade)
#
# What the script does, in order:
#   1. copies memory/, .github/hooks/ (memory-kit.json + scripts),
#      .github/skills/ (dreaming, lesson, memorize) and scripts/;
#   2. breaks NOTHING that exists: existing AGENTS.md → a section is appended;
#      existing kit files → kept unless --force; your other hooks/skills are
#      never touched;
#   3. makes the scripts executable;
#   4. creates a git repo if there isn't one (essential for memory
#      versioning) and makes a first commit.
# ============================================================================
set -Eeuo pipefail

trap exit SIGINT SIGTERM

log() {
  echo "[$(date +"%r")] $*"
}

FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi

KIT="$(cd "$(dirname "$0")" && pwd)"          # kit folder (where this script lives)
SRC="$KIT/template"
TARGET="${1:-}"

if [ -z "$TARGET" ]; then
  echo "Usage: ./install.sh [--force] /path/to/your/project" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || { echo "❌ Folder not found: $1" >&2; exit 1; }

if [ "$TARGET" = "$KIT" ]; then
  echo "❌ Install the kit into a DIFFERENT folder than the kit itself." >&2
  exit 1
fi
command -v python3 >/dev/null 2>&1 || echo "⚠️  python3 not found: the hooks need it (they stay inactive without it)."

log "📦 Installing the memory kit into: $TARGET"

# copy_kit <relative path>: copy a kit-owned file/folder unless it exists
copy_kit() {
  local rel="$1"
  if [ -e "$TARGET/$rel" ] && [ "$FORCE" -eq 0 ]; then
    if diff -rq "$SRC/$rel" "$TARGET/$rel" >/dev/null 2>&1; then
      log "   $rel already up to date."
    else
      log "   ⚠️ $rel already exists and differs → kept (use --force to overwrite)."
    fi
    return
  fi
  mkdir -p "$(dirname "$TARGET/$rel")"
  rm -rf "${TARGET:?}/$rel"
  cp -R "$SRC/$rel" "$TARGET/$rel"
  log "   $rel installed."
}

# --- 1. The memory/ folder (never overwritten, even with --force) -----------
if [ -d "$TARGET/memory" ]; then
  log "   memory/ already exists → kept as is (no changes)."
else
  cp -R "$SRC/memory" "$TARGET/memory"
  log "   memory/ created (index, organization, lessons, error log, scratchpad, proposals)."
fi

# --- 2. AGENTS.md (append, never overwrite) ---------------------------------
if [ -f "$TARGET/AGENTS.md" ]; then
  if grep -q '"Dreaming" kit' "$TARGET/AGENTS.md"; then
    log "   AGENTS.md already contains the kit's rules → unchanged."
  else
    { echo; echo; cat "$SRC/AGENTS.md"; } >> "$TARGET/AGENTS.md"
    log "   Existing AGENTS.md → kit rules APPENDED at the end (nothing overwritten)."
  fi
else
  cp "$SRC/AGENTS.md" "$TARGET/AGENTS.md"
  log "   AGENTS.md created."
fi

# --- 3. Hooks and skills (kit-owned names only) ------------------------------
copy_kit ".github/hooks/memory-kit.json"
copy_kit ".github/hooks/memory-kit"
for skill in dreaming lesson memorize; do
  copy_kit ".github/skills/$skill"
done
chmod +x "$TARGET/.github/hooks/memory-kit/"*.sh

# A Claude Code install of the kit would make Copilot CLI run the hooks twice
# (Copilot also reads hooks from .claude/settings.json).
if [ -f "$TARGET/.claude/settings.json" ] && grep -q 'memory-guard.sh' "$TARGET/.claude/settings.json"; then
  log "   ⚠️ .claude/settings.json still declares the kit's Claude Code hooks."
  log "      Copilot CLI reads that file too: remove its \"hooks\" block (and"
  log "      .claude/hooks/) so the hooks don't run twice."
fi

# --- 4. Scripts and .gitignore -----------------------------------------------
for f in dream.sh token-report.sh copilot_sessions.py; do
  copy_kit "scripts/$f"
done
chmod +x "$TARGET/scripts/dream.sh" "$TARGET/scripts/token-report.sh"

if [ -f "$TARGET/.gitignore" ]; then
  if ! grep -q "memory/scratchpad" "$TARGET/.gitignore"; then
    { echo; cat "$SRC/.gitignore"; } >> "$TARGET/.gitignore"
    log "   Rules appended to the existing .gitignore."
  fi
else
  cp "$SRC/.gitignore" "$TARGET/.gitignore"
  log "   .gitignore created."
fi

# macOS on exFAT/FAT drives leaves AppleDouble files behind: never commit them
find "$TARGET/memory" "$TARGET/.github" "$TARGET/scripts" -name '._*' -delete 2>/dev/null || true

# --- 5. git: essential for memory versioning ---------------------------------
cd "$TARGET"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "   git repo already present → great, memory versioning is active."
else
  git init -q
  log "   git repo created (git init) — required for the memory history."
fi
KIT_PATHS=(AGENTS.md .github/hooks/memory-kit.json .github/hooks/memory-kit
  .github/skills/dreaming .github/skills/lesson .github/skills/memorize
  memory scripts/dream.sh scripts/token-report.sh scripts/copilot_sessions.py
  .gitignore)
git add -- "${KIT_PATHS[@]}" 2>/dev/null || true
if ! git diff --cached --quiet -- "${KIT_PATHS[@]}" 2>/dev/null; then
  # The project's own git hooks run (no --no-verify): if one rejects the
  # commit, the files stay staged for you to review and commit.
  # Only the kit's paths are committed, never other files you had staged.
  if git commit -q -m "Install the memory kit (Copilot CLI)" -- "${KIT_PATHS[@]}"; then
    log "   First commit done."
  else
    log "   ⚠️ The commit was rejected by a git hook: the kit's files are staged,"
    log "      review them and commit. Until they are committed, the memory hooks"
    log "      cannot revert agent changes to them (no baseline)."
  fi
fi

echo
echo "✅ Done! Next steps:"
echo "   1. Open memory/organization/conventions.md and adapt the rules to your project."
echo "   2. Run \`copilot\` in $TARGET and trust the folder: the memory index loads"
echo "      automatically (check with /skills list and \"what do you remember?\")."
echo "   3. Once a week: ./scripts/dream.sh"
echo "   4. Recommended on GitHub: require human review for memory/organization/"
echo "      and the kit's files with CODEOWNERS + branch protection (see README)."

