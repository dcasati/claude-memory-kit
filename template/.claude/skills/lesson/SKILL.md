---
name: lesson
description: Turns a resolved error into a reusable lesson. Use right after fixing a bug, a failing command, or a wrong assumption — so the next session doesn't repeat the mistake.
---

# Record a lesson (the error-learning loop)

An error has just been diagnosed and fixed. Capture it NOW, while the context
is fresh: this is what makes the agent better in the next session ("the
second time, the task succeeds on the first try").

## 1. Check what already exists

`grep` in `memory/lessons/`: if a lesson already covers this error,
update it (occurrence count, more precise cause) instead of duplicating it.

## 2. Write the lesson

Create `memory/lessons/<YYYY-MM-DD>-<short-slug>.md`:

```markdown
---
name: <short-slug>
description: <the error in one line, phrased as a recognizable symptom>
type: lesson
date: <YYYY-MM-DD>
source: session <first 8 characters of the session id if known>
---

# Lesson: <descriptive title>

**Symptom**: <what you observe when the error happens (exact message if useful)>

**Root cause**: <the real cause, not the symptom>

**Fix applied**: <what worked, precise command or change>

**Prevention**: <the reflex to have BEFORE acting so you don't fall into it again>
```

Rules: absolute dates, no secrets, 15 lines maximum, one error per file.

## 3. Index it and close out the log

1. Add a line to `memory/MEMORY.md`, under "Lessons learned".
2. Open `memory/errors/log.md` and find the lines matching this error.
   Annotate each one with the Edit tool by APPENDING ` [handled → lessons/<file>]`
   at the end of the line, without removing any of the original text (the
   guardrail only allows this form of editing on the log).

## 4. Report back

End with one sentence to the user: "Lesson recorded: <title>. The next
session will see it at startup."
