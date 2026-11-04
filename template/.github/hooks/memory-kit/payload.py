"""
payload.py — shared helper for the memory kit hooks (GitHub Copilot CLI).

Copilot CLI sends each hook a JSON object on stdin. Its shape depends on how
the hook is declared and on the model in use, so this module turns every
variant into one simple, predictable structure:

  - camelCase events (sessionStart, preToolUse…):  toolName / toolArgs
  - PascalCase events (PreToolUse…, Claude style): tool_name / tool_input
  - file edits from GPT models arrive as a raw patch STRING
      "*** Begin Patch\n*** Update File: /abs/path\n@@\n-old\n+new\n*** End Patch"
  - file edits from Claude models arrive as a dict {path, old_str, new_str}

Only the Python standard library is used.
"""
import json
import os
import re
import sys

# The project root = three levels above this file (.github/hooks/memory-kit/)
ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
MEMORY = os.path.join(ROOT, "memory")

WRITE_TOOLS = {"create", "edit", "apply_patch", "write", "multiedit", "str_replace_editor", "notebookedit"}
SHELL_TOOLS = {"bash", "powershell", "shell", "write_bash", "write_powershell"}

# Paths the agent must never change: the shared organization memory and the
# kit's own enforcement files (hooks + skills). Relative to ROOT, lowercase.
ORG = "memory/organization"
KIT_FILES = (".github/hooks/memory-kit.json", ".github/hooks/memory-kit",
             ".github/skills/dreaming", ".github/skills/lesson", ".github/skills/memorize")
PROTECTED = (ORG,) + KIT_FILES


def under(rel, prefix):
    """True if `rel` is `prefix` or inside it. Case-insensitive: macOS and
    Windows file systems usually are, so MEMORY/Organization is the same folder."""
    rel, prefix = rel.lower(), prefix.lower()
    return rel == prefix or rel.startswith(prefix + "/")


def is_protected(rel):
    return any(under(rel, p) for p in PROTECTED)


def read_input():
    """Return (raw_text, parsed_dict) from stdin. Never raises."""
    try:
        raw = sys.stdin.read()
    except Exception:
        raw = ""
    try:
        data = json.loads(raw) if raw.strip() else {}
    except ValueError:
        data = {}
    return raw, data if isinstance(data, dict) else {}


class Event:
    """A normalized view of one hook payload."""

    def __init__(self, data):
        self.data = data
        self.session = str(data.get("sessionId") or data.get("session_id") or "")
        self.cwd = data.get("cwd") or ROOT
        self.tool = str(data.get("toolName") or data.get("tool_name") or "")
        args = data.get("toolArgs", data.get("tool_input"))
        if isinstance(args, str):
            # toolArgs is sometimes a JSON-encoded string, sometimes a patch
            try:
                decoded = json.loads(args)
                args = decoded if isinstance(decoded, (dict, str)) else args
            except ValueError:
                pass
        self.args = args if args is not None else {}
        result = data.get("toolResult") or data.get("tool_response") or {}
        if isinstance(result, dict):
            self.result_text = str(result.get("textResultForLlm") or result.get("output")
                                   or result.get("stdout") or result.get("message") or "")
            self.result_type = str(result.get("resultType") or "")
        else:
            self.result_text, self.result_type = str(result), ""
        self.error = data.get("error")
        self.transcript = data.get("transcriptPath") or data.get("transcript_path") or ""

    @property
    def short_session(self):
        return self.session[:8] or "unknown"

    @property
    def kind(self):
        """'write', 'shell' or 'other'."""
        name = self.tool.lower()
        if name in WRITE_TOOLS or self.patch_text():
            return "write"
        if name in SHELL_TOOLS:
            return "shell"
        return "other"

    def command(self):
        """Shell text: `command` for bash/powershell, `input` for write_bash."""
        if isinstance(self.args, dict):
            return str(self.args.get("command") or self.args.get("input") or "")
        return ""

    def patch_text(self):
        """The raw patch string if this tool call is an apply_patch, else ''."""
        if isinstance(self.args, str) and "*** " in self.args:
            return self.args
        if isinstance(self.args, dict):
            for value in self.args.values():
                if isinstance(value, str) and value.lstrip().startswith("*** Begin Patch"):
                    return value
        return ""

    def file_ops(self):
        """List of FileOp describing every file this write touches."""
        patch = self.patch_text()
        if patch:
            return parse_patch(patch, self.cwd)
        if not isinstance(self.args, dict):
            return []
        a = self.args
        path = a.get("path") or a.get("file_path") or a.get("filePath") or a.get("notebook_path")
        if not path:
            return []
        name = self.tool.lower()
        op = FileOp("add" if name in ("create", "write") else "update", resolve(path, self.cwd))
        old = a.get("old_str", a.get("old_string"))
        new = a.get("new_str", a.get("new_string"))
        if old is not None or new is not None:
            op.replacements.append((old or "", new or ""))
        for edit in a.get("edits") or []:          # MultiEdit-style payloads
            if isinstance(edit, dict):
                op.replacements.append((edit.get("old_string") or edit.get("old_str") or "",
                                        edit.get("new_string") or edit.get("new_str") or ""))
        if op.kind == "update" and not op.replacements:
            op.kind = "overwrite"   # an edit we can't inspect = treat as full rewrite
        return [op]


class FileOp:
    def __init__(self, kind, path):
        self.kind = kind            # add | update | delete | overwrite
        self.path = path            # absolute, symlink-resolved
        self.move_to = None
        self.removed = []           # patch lines starting with '-'
        self.added = []             # patch lines starting with '+'
        self.replacements = []      # (old, new) pairs from dict-style edits

    @property
    def rel(self):
        return relative(self.path)


PATCH_HEADER = re.compile(r"^\*\*\* (Add|Update|Delete) File: (.+?)\s*$")
PATCH_MOVE = re.compile(r"^\*\*\* Move to: (.+?)\s*$")


def parse_patch(text, cwd):
    ops, current = [], None
    for line in text.splitlines():
        m = PATCH_HEADER.match(line)
        if m:
            current = FileOp(m.group(1).lower(), resolve(m.group(2), cwd))
            ops.append(current)
            continue
        if current is None:
            continue
        m = PATCH_MOVE.match(line)
        if m:
            current.move_to = resolve(m.group(1), cwd)
        elif line.startswith("*** "):
            continue
        elif line.startswith("-"):
            current.removed.append(line[1:])
        elif line.startswith("+"):
            current.added.append(line[1:])
    return ops


def resolve(path, cwd):
    path = os.path.expanduser(str(path).strip().strip("'\""))
    if not os.path.isabs(path):
        path = os.path.join(cwd or ROOT, path)
    return os.path.realpath(path)


def relative(path):
    """Path relative to the project root, with forward slashes ('' if outside)."""
    try:
        rel = os.path.relpath(path, ROOT)
    except ValueError:
        return ""
    if rel.startswith(".."):
        return ""
    return rel.replace(os.sep, "/")


def flatten(text, limit):
    return re.sub(r"\s+", " ", str(text)).strip()[:limit]
