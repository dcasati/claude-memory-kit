---
name: example-port-already-in-use
description: EXAMPLE — the local server refuses to start because port 3000 is already taken.
type: lesson
date: 2026-07-17
source: example file provided by the kit (delete it once you have real lessons)
---

# Lesson: port 3000 already in use when starting the local server

**Symptom**: `npm run dev` fails with `EADDRINUSE: address already in use :::3000`.

**Root cause**: a previous session left a server running in the background.

**Fix applied**: find and stop the process:
`lsof -ti :3000 | xargs kill`

**Prevention**: before starting a dev server, check whether the port already
responds (`lsof -ti :3000`) and reuse the existing server rather than starting a second one.

<!-- This file shows the format expected by the `lesson` skill:
     a clear title, symptom / cause / fix / prevention, and a frontmatter
     with an ABSOLUTE date. One fact per file. -->
