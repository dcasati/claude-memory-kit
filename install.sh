#!/bin/bash
# ============================================================================
# install.sh — installs the memory kit into a project
#
# Usage:
#   ./install.sh /path/to/your/project
#   ./install.sh .          # install into the current folder
#
# What the script does, in order:
#   1. copies memory/, .claude/ (hooks, skills, settings) and scripts/;
#   2. breaks NOTHING that exists: existing CLAUDE.md → a section is appended;
#      existing settings.json → ours is placed alongside with instructions;
#   3. makes the scripts executable;
#   4. creates a git repo if there isn't one (essential for memory
#      versioning) and makes a first commit.
# ============================================================================
set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"          # kit folder (where this script lives)
TARGET="${1:-}"

if [ -z "$TARGET" ]; then
  echo "Usage: ./install.sh /path/to/your/project" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || { echo "❌ Folder not found: $1" >&2; exit 1; }

if [ "$TARGET" = "$KIT" ]; then
  echo "❌ Install the kit into a DIFFERENT folder than the kit itself." >&2
  exit 1
fi

echo "📦 Installing the memory kit into: $TARGET"

# --- 1. The memory/ folder (without overwriting an existing memory) ---------
if [ -d "$TARGET/memory" ]; then
  echo "   memory/ already exists → kept as is (no changes)."
else
  cp -R "$KIT/template/memory" "$TARGET/memory"
  echo "   memory/ created (index, organization, lessons, error log, scratchpad, proposals)."
fi

# --- 2. CLAUDE.md (append, never overwrite) ---------------------------------
if [ -f "$TARGET/CLAUDE.md" ]; then
  if grep -q '"Dreaming" kit' "$TARGET/CLAUDE.md"; then
    echo "   CLAUDE.md already contains the kit's rules → unchanged."
  else
    { echo; echo; cat "$KIT/template/CLAUDE.md"; } >> "$TARGET/CLAUDE.md"
    echo "   Existing CLAUDE.md → kit rules APPENDED at the end (nothing overwritten)."
  fi
else
  cp "$KIT/template/CLAUDE.md" "$TARGET/CLAUDE.md"
  echo "   CLAUDE.md created."
fi

# --- 3. .claude/: hooks, skills, settings ------------------------------------
mkdir -p "$TARGET/.claude"
cp -R "$KIT/template/.claude/hooks" "$TARGET/.claude/"
mkdir -p "$TARGET/.claude/skills"
cp -R "$KIT/template/.claude/skills/." "$TARGET/.claude/skills/"
chmod +x "$TARGET/.claude/hooks/"*.sh
echo "   Hooks and skills installed (.claude/hooks, .claude/skills)."

if [ -f "$TARGET/.claude/settings.json" ]; then
  cp "$KIT/template/.claude/settings.json" "$TARGET/.claude/settings.memory-kit.json"
  echo "   ⚠️ .claude/settings.json already exists: ours is placed alongside as"
  echo "      settings.memory-kit.json. Merge the \"hooks\" and \"permissions\""
  echo "      blocks by hand (or ask Claude to do it)."
else
  cp "$KIT/template/.claude/settings.json" "$TARGET/.claude/settings.json"
  echo "   .claude/settings.json created (permissions + hooks)."
fi

# --- 4. Scripts and .gitignore -----------------------------------------------
mkdir -p "$TARGET/scripts"
cp "$KIT/template/scripts/dream.sh" "$KIT/template/scripts/token-report.sh" "$TARGET/scripts/"
chmod +x "$TARGET/scripts/dream.sh" "$TARGET/scripts/token-report.sh"
echo "   scripts/dream.sh and scripts/token-report.sh installed."

if [ -f "$TARGET/.gitignore" ]; then
  if ! grep -q "memory/scratchpad" "$TARGET/.gitignore"; then
    { echo; cat "$KIT/template/.gitignore"; } >> "$TARGET/.gitignore"
    echo "   Rules appended to the existing .gitignore."
  fi
else
  cp "$KIT/template/.gitignore" "$TARGET/.gitignore"
  echo "   .gitignore created."
fi

# --- 5. git: essential for memory versioning ---------------------------------
cd "$TARGET"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "   git repo already present → great, memory versioning is active."
else
  git init -q
  echo "   git repo created (git init) — required for the memory history."
fi
git add CLAUDE.md .claude memory scripts .gitignore 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -q -m "Install the memory kit (claude-memory-kit)" --no-verify
  echo "   First commit done."
fi

echo
echo "✅ Done! Next steps:"
echo "   1. Open memory/organization/conventions.md and adapt the rules to your project."
echo "   2. Run \`claude\` in $TARGET: the memory index loads automatically."
echo "   3. Once a week: ./scripts/dream.sh"
