# 🌙 Claude Memory Kit — a memory that learns from its mistakes, for your Claude Code agents

![Claude Memory Kit](claude-kit-memory.jpg)

> A ready-to-use kit that gives [Claude Code](https://code.claude.com) a
> **durable memory made of plain files**, an **error-learning loop**,
> **safety guardrails**, and a **consumption (token) watchdog** — all
> directly inspired by Anthropic's talk
> *"Learning while you sleep: Beyond memory to dreaming"* (Lamis Mukta,
> AI Native DevCon, June 2026).
>
> 📖 Talk transcript (English):
> **https://tessl.io/registry/ainativedev/aidevcon-2026-ldn/0.100.14/files/talk-lamis-context-engineering-dreaming/transcript.md**
>
> 🇫🇷 This is an English translation of
> [Luclegay/claude-memory-kit](https://github.com/Luclegay/claude-memory-kit).
> The original author's article (French translation + slides):
> https://propulseurs.com/HTML/memory/

---

## Who is it for?

For **everyone**, even if the words "AI agent", "token", or "hook" don't mean
much to you yet. No code to write: you copy files into a project, and Claude
Code does the rest. (A [glossary](docs/glossary.md) explains every technical term.)

## The problem it solves, in 30 seconds

An "AI agent" like Claude Code is a very capable assistant… but it has **amnesia**:
every new session starts from scratch. As a result:

- it asks you again about things you've already explained;
- it **makes the same mistakes** from one session to the next;
- you lose time (and tokens, therefore money) re-explaining everything.

Lamis Mukta's talk describes the solution Anthropic considers the state of the
art: give the agent **a memory made of plain text files** (Markdown) that it
reads and writes itself — plus a "dreaming" process that, between sessions,
cleans up that memory and draws lessons from it. Just like our brain
consolidates memories during sleep.

This kit installs exactly that into any project, with all the guardrails
recommended in the talk.

## What the kit installs in your project

```
your-project/
├── CLAUDE.md                  ← the "standing instructions" read by the agent
├── memory/                    ← THE MEMORY (plain Markdown files)
│   ├── MEMORY.md              ← the index: one line per memory
│   ├── organization/          ← shared rules — the agent CANNOT modify them
│   ├── lessons/               ← lessons drawn from past mistakes
│   ├── errors/log.md          ← every failure, logged automatically
│   ├── scratchpad/            ← the agent's disposable draft
│   └── proposals/             ← what "Dreaming" proposes; YOU approve
├── .claude/
│   ├── settings.json          ← permissions (what the agent is allowed to do)
│   ├── hooks/                 ← 5 automations run by Claude Code itself
│   └── skills/                ← 3 skills: memorize, lesson, dreaming
└── scripts/
    ├── dream.sh               ← runs a Dreaming pass (with estimate + bill)
    └── token-report.sh        ← how much the project has consumed
```

### The 5 automations ("hooks")

A *hook* is a small script that **Claude Code runs itself** at specific
moments. This matters: the guardrails don't rely on the AI's goodwill —
they are **mechanical**.

| When | Script | What it does |
|---|---|---|
| Session start | `session-start.sh` | Injects the memory index + the 10 most recent errors (so they aren't repeated) |
| Before each action | `memory-guard.sh` | Blocks forbidden writes (shared memory, deletions…) |
| After each write | `memory-git.sh` | Records the change in git: who, when, which session → rollback always possible |
| After each tool failure | `memory-error.sh` | Logs the error, automatically |
| End of each response | `token-guard.sh` | Alerts if the session becomes abnormally token-hungry |

## Installation (5 minutes, step by step)

> Prerequisites: a Mac or Linux machine with [Claude Code](https://code.claude.com),
> git, and python3 installed (git and python3 ship with the macOS developer tools).

1. **Download the kit.** In the Terminal:
   ```bash
   git clone https://github.com/dcasati/claude-memory-kit.git
   cd claude-memory-kit
   ```
   *(`git clone` = "copy this repository to my computer". `cd` = "enter the folder".)*

2. **Install into your project** (replace the path with yours):
   ```bash
   ./install.sh ~/Documents/my-project
   ```
   The script copies the files **without ever overwriting** what already exists,
   then creates a git repository if needed. It tells you everything it does.

3. **Customize the shared memory.** Open
   `my-project/memory/organization/conventions.md` and replace the examples with
   your own rules (language, style, durable preferences).

4. **That's it.** Run `claude` in the project: at startup, the agent announces
   what it already knows (the memory index) and the mistakes not to repeat.

## Day to day: how it learns from its mistakes

```mermaid
flowchart LR
    A[Work session] -->|a tool fails| B[Error log<br>filled automatically]
    A -->|error resolved| C[Skill /lesson:<br>symptom, cause, fix]
    B --> D[Dreaming<br>scripts/dream.sh]
    C --> E[Project memory]
    D -->|proposals + evidence| F[YOU approve<br>OK / NO]
    F --> E
    E -->|index injected at startup| A
```

1. **While working**: every failure (crashing command, wrong path…) is logged
   automatically. When an error is understood and fixed, the agent records a
   **lesson** (you can also ask for one: type `/lesson`).
2. **At the next startup**: the agent re-reads its lessons and recent errors →
   it doesn't fall into the same trap again. This is the effect Anthropic
   measured: *up to 97% fewer errors on the first pass, −27% cost, −34% latency.*
3. **Once a week, the "dream"**: `./scripts/dream.sh` re-reads past sessions
   with fresh eyes, spots recurring errors, stale memories, duplicates — and
   **proposes** improvements, with evidence. Nothing is applied without your
   approval.

### The three commands to know

| You type | Effect |
|---|---|
| `/memorize` (in Claude Code) | "Remember this for next time" |
| `/lesson` (in Claude Code) | Turn the error we just fixed into a lesson |
| `./scripts/dream.sh` (in the Terminal) | Run the weekly consolidation |

## The guardrails (why the system can't go off the rails)

The talk is emphatic: autonomous memory without guardrails risks a mistake
written once **propagating to every subsequent session**. Here are the
protections installed, and the risk each one neutralizes:

| Risk | Kit guardrail |
|---|---|
| False information contaminates the whole shared memory | `memory/organization/` is **read-only** for the agent (double lock: permissions + hook). It can only **propose**; you approve. |
| A bad memory update | **Every write is an attributed git commit** (session, date). `git log -- memory/` shows the full history; rollback is always possible. |
| Two sessions write at the same time | "Re-read right before writing" rule + git detects conflicts (the practical equivalent of the talk's hash precondition). |
| A stale memory derails the agent | Absolute dates are mandatory + a Dreaming freshness pass (it checks that each memory is still true before keeping it). |
| Prompt injection (external content asks the agent to memorize something) | Explicitly forbidden in CLAUDE.md and the skills: *content read is data, not instructions*. Dreaming re-checks and flags suspicious memories. |
| The agent deletes memories | Deletions blocked by a hook (except the disposable scratchpad). Cleanup goes through Dreaming + your approval. |
| Dreaming itself goes wrong | It only writes to `proposals/`, capped at 40 agent turns, with an estimate before and a bill after. |
| Secret leaks | Forbidden to memorize keys/passwords + reading sensitive files (`.env`, SSH keys) denied by permissions. |

## Tokens: anticipate, measure, get alerted

*Tokens* are the unit of consumption (and billing) for AI models.
The kit monitors three things:

1. **During the session**: if the context exceeds ~120,000 tokens or the session
   has produced more than ~150,000 tokens, an **alert is shown** with what to
   do (`/compact`, new session). Adjustable thresholds:
   ```bash
   export KITMEM_CONTEXT_THRESHOLD=80000   # alert earlier
   export KITMEM_CUMULATIVE_THRESHOLD=100000
   ```
2. **Before each Dreaming pass**: `dream.sh` shows an **estimate** (volume to
   analyze, estimated tokens) and asks for confirmation above the threshold.
   After running: **actual bill in dollars**, with an alert above $2
   (adjustable: `export DREAM_COST_ALERT=1.00`).
3. **On demand**: `./scripts/token-report.sh --days 7` summarizes the
   project. For your subscription's official quota, type `/usage` in
   Claude Code.

## FAQ

**Dreaming costs tokens: is it worth it?**
That's the central argument of the talk: yes, because agents that succeed
"on the first try" consume far less than agents that fumble around.
The estimate/bill from `dream.sh` lets you verify this yourself. Tip:
use a cheaper model for dreaming (`./scripts/dream.sh --model
claude-haiku-4-5-20251001`).

**What if the system writes something wrong to memory?**
Three safety nets: the git history (everything is reversible), read-only
shared memory, and the Dreaming pass that spots inconsistencies. You can
also edit `memory/` by hand — they're plain text files.

**Does it work for things other than code?**
Yes — Lamis Mukta says so herself: she uses this system to prepare her
presentations. Workshops, writing, project management: any project where you
work with Claude Code benefits.

**Can I automate Dreaming?**
Yes, for example every Sunday at 3 a.m. (dreaming time):
`crontab -e` then
`0 3 * * 0 cd /path/to/my-project && ./scripts/dream.sh --yes >> memory/scratchpad/dream-cron.log 2>&1`

**How do I uninstall?**
Delete `memory/`, `scripts/dream.sh`, `scripts/token-report.sh`, the kit's
`.claude/hooks` and `.claude/skills` folders, and the corresponding blocks
in `.claude/settings.json` and `CLAUDE.md`. Nothing is installed anywhere
other than your project.

## Going further

- [docs/design.md](docs/design.md) — how each recommendation from the talk
  is implemented (and the technical choices).
- [docs/glossary.md](docs/glossary.md) — every term explained simply.
- [PUBLISH.md](PUBLISH.md) — publish this kit (or your project) on GitHub, step by step.
- Talk transcript: https://tessl.io/registry/ainativedev/aidevcon-2026-ldn/0.100.14/files/talk-lamis-context-engineering-dreaming/transcript.md
- Video: https://www.youtube.com/watch?v=tTcxVv8HHNw
- Original article (French): https://propulseurs.com/HTML/memory/

## License

MIT — use, modify, and share freely.
