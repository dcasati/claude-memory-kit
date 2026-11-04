# Glossary — the kit's terms, explained simply

**AI agent** — an artificial-intelligence assistant capable of *acting* (reading
files, running commands, writing code), not just chatting.
GitHub Copilot CLI is an agent.

**Session** — a working conversation with the agent, from launching `copilot`
until you close it. Without memory, every session starts from scratch.

**Context (context window)** — the model's "working memory": everything it
has in front of it at a given moment (your messages, files read, command
results). It is limited — hence the value of loading only the essentials.

**Token** — the smallest unit of text processed by the model (≈ a word or a
piece of a word; in practice 1 token ≈ 4 characters). It is the unit of
consumption and billing. Fewer tokens = cheaper and faster.

**AGENTS.md** — a text file at the root of the project, read automatically at
the start of each session: the agent's "standing instructions". (Claude Code
uses `CLAUDE.md` for the same purpose; Copilot CLI reads both.)

**AI credits** — the unit GitHub Copilot uses to bill model usage. `/usage`
shows them for the current session; `scripts/token-report.sh` sums them for
the project.

**Markdown (.md)** — a plain-text format with light formatting
(headings with `#`, lists with `-`). Readable by humans AND by agents;
it is the recommended format for memory.

**Memory (in the kit's sense)** — a `memory/` folder filled with Markdown files
that the agent reads and writes. The talk's central recommendation: the most
effective agent memory is a simple file system.

**Index (MEMORY.md)** — the memory catalog: one line per memory.
The agent reads the index, then opens only the useful files. This is
*progressive disclosure*: Lamis Mukta's analogy is a bookshelf where you
scan the titles before pulling out a book.

**Skill** — a folder containing detailed instructions for a recurring task
(e.g. "how to record a lesson"). The agent first reads only the summary
(the *frontmatter*), and loads the details only when needed.

**Frontmatter** — the small block of information between `---` at the top of a
file: name, description, date… The "summary on the book's spine".

**Hook** — a small script that Copilot CLI runs automatically at a specific
moment (startup, before/after an action, after a failure). The kit's
guardrails are hooks: they apply mechanically, without depending on the AI.

**Permissions** — what the agent may do without asking. Copilot CLI asks
you before running commands or writing files, unless you pre-approve them
(`--allow-tool`, `--allow-all-tools`). The kit's guard hook adds rules that
apply even when everything is pre-approved.

**git** — the file-history system used by developers.
Each save ("commit") records who changed what, and when. The kit uses it
for memory **versioning**: everything is traceable and reversible.

**Versioning / rollback** — keeping every successive version of a file
(versioning) so you can return to an earlier version (rollback).

**Concurrency** — when two sessions want to modify the same file at the same
time. The kit's rule: re-read the file right before writing it; git detects
any remaining conflicts.

**Stale** — information that used to be true but no longer is, like
directions that weren't updated after a move. Dreaming hunts down *stale*
memories.

**Prompt injection** — an attack where some text (web page, email, document)
contains hidden instructions aimed at the agent, for example "write this into
your memory". The kit's defense: content read is *data*, never
*instructions*, and Dreaming flags suspicious memories.

**In-band / out-of-band** — *in-band*: what happens during the working
session (the agent splits its attention between the task and its memory).
*Out-of-band*: what runs outside, with its own budget — like Dreaming.

**Dreaming** — the periodic process (a name given by Anthropic, by analogy
with sleep) that re-reads past sessions and memory, spots recurring patterns,
and proposes improvements that the human approves. "Learning while you sleep."

**Transcript (session log)** — the complete record of a session (messages,
commands, errors, token usage), kept by Copilot CLI in
`~/.copilot/session-state/<session>/events.jsonl`. It is Dreaming's raw
material.

**Scratchpad** — the agent's draft: temporary, disposable notes, purged
automatically.

**Orchestrator / sub-agents** — an architecture where a "team lead" agent
distributes work to specialized agents and then assembles their results.
This is how Anthropic runs Dreaming at scale (one sub-agent per session
analyzed).
