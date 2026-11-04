#!/bin/bash
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
set -euo pipefail

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

echo "📦 Installing the memory kit into: $TARGET"

# copy_kit <relative path>: copy a kit-owned file/folder unless it exists
copy_kit() {
  local rel="$1"
  if [ -e "$TARGET/$rel" ] && [ "$FORCE" -eq 0 ]; then
    if diff -rq "$SRC/$rel" "$TARGET/$rel" >/dev/null 2>&1; then
      echo "   $rel already up to date."
    else
      echo "   ⚠️ $rel already exists and differs → kept (use --force to overwrite)."
    fi
    return
  fi
  mkdir -p "$(dirname "$TARGET/$rel")"
  rm -rf "${TARGET:?}/$rel"
  cp -R "$SRC/$rel" "$TARGET/$rel"
  echo "   $rel installed."
}

# --- 1. The memory/ folder (never overwritten, even with --force) -----------
if [ -d "$TARGET/memory" ]; then
  echo "   memory/ already exists → kept as is (no changes)."
else
  cp -R "$SRC/memory" "$TARGET/memory"
  echo "   memory/ created (index, organization, lessons, error log, scratchpad, proposals)."
fi

# --- 2. AGENTS.md (append, never overwrite) ---------------------------------
if [ -f "$TARGET/AGENTS.md" ]; then
  if grep -q '"Dreaming" kit' "$TARGET/AGENTS.md"; then
    echo "   AGENTS.md already contains the kit's rules → unchanged."
  else
    { echo; echo; cat "$SRC/AGENTS.md"; } >> "$TARGET/AGENTS.md"
    echo "   Existing AGENTS.md → kit rules APPENDED at the end (nothing overwritten)."
  fi
else
  cp "$SRC/AGENTS.md" "$TARGET/AGENTS.md"
  echo "   AGENTS.md created."
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
  echo "   ⚠️ .claude/settings.json still declares the kit's Claude Code hooks."
  echo "      Copilot CLI reads that file too: remove its \"hooks\" block (and"
  echo "      .claude/hooks/) so the hooks don't run twice."
fi

# --- 4. Scripts and .gitignore -----------------------------------------------
for f in dream.sh token-report.sh copilot_sessions.py; do
  copy_kit "scripts/$f"
done
chmod +x "$TARGET/scripts/dream.sh" "$TARGET/scripts/token-report.sh"

if [ -f "$TARGET/.gitignore" ]; then
  if ! grep -q "memory/scratchpad" "$TARGET/.gitignore"; then
    { echo; cat "$SRC/.gitignore"; } >> "$TARGET/.gitignore"
    echo "   Rules appended to the existing .gitignore."
  fi
else
  cp "$SRC/.gitignore" "$TARGET/.gitignore"
  echo "   .gitignore created."
fi

# macOS on exFAT/FAT drives leaves AppleDouble files behind: never commit them
find "$TARGET/memory" "$TARGET/.github" "$TARGET/scripts" -name '._*' -delete 2>/dev/null || true

# --- 5. git: essential for memory versioning ---------------------------------
cd "$TARGET"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "   git repo already present → great, memory versioning is active."
else
  git init -q
  echo "   git repo created (git init) — required for the memory history."
fi
git add AGENTS.md .github/hooks/memory-kit.json .github/hooks/memory-kit \
  .github/skills/dreaming .github/skills/lesson .github/skills/memorize \
  memory scripts/dream.sh scripts/token-report.sh scripts/copilot_sessions.py \
  .gitignore 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -q -m "Install the memory kit (Copilot CLI)" --no-verify
  echo "   First commit done."
fi

echo
echo "✅ Done! Next steps:"
echo "   1. Open memory/organization/conventions.md and adapt the rules to your project."
echo "   2. Run \`copilot\` in $TARGET and trust the folder: the memory index loads"
echo "      automatically (check with /skills list and \"what do you remember?\")."
echo "   3. Once a week: ./scripts/dream.sh"
