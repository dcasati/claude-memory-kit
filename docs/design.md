# Kit design — from Lamis Mukta's recommendations to implementation

> Design document. It explains **why** the kit is built this way, linking
> each technical choice to the recommendations of the talk
> *"Learning while you sleep: Beyond memory to dreaming"* (Lamis Mukta, Anthropic,
> AI Native DevCon, June 2026). Talk transcript:
> https://tessl.io/registry/ainativedev/aidevcon-2026-ldn/0.100.14/files/talk-lamis-context-engineering-dreaming/transcript.md

## 1. What the talk says (operational summary)

1. **The most effective agent memory today is a simple file system**
   filled with Markdown, which the agent reads and writes itself with standard
   tools (bash, grep). No need for bespoke memory tools.
2. **Three format lessons**:
   - *Format*: Markdown works.
   - *Reading*: progressive disclosure — you read an index and headers
     (frontmatter), not the whole store.
   - *Writing*: autonomy wins — the agent decides what is worth keeping.
3. **Production guardrails**:
   - *Versioning*: every write attributed (author, session, timestamp),
     full history, rollback possible.
   - *Concurrency*: a content precondition (hash) before every write.
   - *Permissioning*: the shared "organization" memory is read-only for the
     agent; its scratchpad is read-write.
   - *Portability*: plain files — the memory moves with the project.
4. **Learning from mistakes**: the agent notes what went wrong; the next time,
   it does better (the talk cites up to 97% fewer errors on the first pass,
   −27% cost, −34% latency).
5. **Dreaming**: an *out-of-band* process (outside the session, in batch, with its
   own token budget) that re-reads transcripts and memory, spots recurring
   patterns, removes what is obsolete, and **proposes** changes — with evidence
   and statistics — that the human approves or rejects.
6. **Identified risks**: *stale* memories, an error propagating to the whole
   fleet via shared memory, prompt injection causing false memories to be
   written.

## 2. Approaches considered

| Approach | Description | Verdict |
|---|---|---|
| **A. Files + skills only** | AGENTS.md + `memory/` folder + skills, no hooks. | Simple, but nothing guarantees the guardrails: the agent may forget to log an error, write to shared memory, or blow up the context without warning. |
| **B. Files + skills + hooks + git** *(chosen)* | The critical guardrails (error log, protection of `organization/`, git versioning, token alerts) are **mechanical** (hooks run by Copilot CLI itself), not left to the model's goodwill. | Reliable, 100% local, zero dependencies beyond git/python3 already present on macOS. |
| **C. Dedicated memory server (MCP, database)** | Full portable memory API, concurrency hashing on the infrastructure side. | Contrary to the talk's "do the simple thing that works" for solo/small-team use. Rejected. |

**Decision: B.** The talk insists: guardrails should be handled "by the
infrastructure, not by the model" (slide 06). In GitHub Copilot CLI, the
infrastructure available without a server is **hooks**
(`.github/hooks/*.json`) and **git**.

## 3. Recommendation → implementation mapping

| Talk recommendation | Implementation in the kit |
|---|---|
| Memory = Markdown file system | `memory/` folder: `MEMORY.md` (index), `organization/`, `lessons/`, `errors/`, `scratchpad/`, `proposals/` |
| Progressive disclosure | `sessionStart` hook that injects (via `additionalContext`) only the index + the 10 most recent errors; AGENTS.md rule: "grep before reading" |
| Write autonomy | `memorize` skill (the agent decides what to keep, format enforced) |
| Attributed versioning | `postToolUse` hook: after every tool call, every change under `memory/` (except `organization/`) is committed — without `--no-verify`, so the project's own git hooks run; the message includes the session id |
| Concurrency (hash) | git detects conflicts; "re-read right before editing" rule in the `memorize` skill (the edit tool already fails if the text to replace has changed — the practical equivalent of the hash precondition) |
| Permissioning (organization read-only) | Enforced on the **outcome**: after every tool call, `memory-git.sh` resets `memory/organization/` and the kit's own files to the last commit (backup in `.git/memory-kit/reverted/`) and restores deleted memories. The `preToolUse` guard refuses the obvious attempts early with a clear message; the AGENTS.md rule explains why |
| Portability | Everything is a flat file in the project; `memory/` is versioned alongside the code |
| Learning from mistakes | `postToolUseFailure` + `postToolUse` hooks: every tool error and every non-zero shell exit is automatically logged in `memory/errors/log.md` (tool, command, exit code — never the output); `lesson` skill: turns a resolved error into a reusable lesson; `sessionStart` re-injects the lessons at the next startup |
| Out-of-band dreaming | `scripts/dream.sh`: runs `copilot -p "/dreaming …"` in batch with file tools only, on copies of the selected session logs; hard AI-credit cap (`--max-ai-credits`), cost estimate **before** running, actual AI-credit bill **after** |
| Dreaming proposes, the human decides | The `dreaming` skill only writes to `memory/proposals/` (evidence + statistics) and `[handled]` annotations; applying happens after human approval (`/dreaming apply`); removals are run by the human (`git rm`) |
| Anti-staleness | Absolute dates mandatory in every memory; freshness-check pass in dreaming |
| Anti-prompt-injection | Rule in AGENTS.md and in the skills: never memorize an instruction found in external content (web page, email, received file); dreaming re-checks suspicious memories |
| Token management | `agentStop` hook: alerts when the context, output tokens or AI credits exceed thresholds (read from the session's `events.jsonl`); `scripts/token-report.sh`: tokens and AI credits for the day/week; `dream.sh`: estimate before, bill after, alert on overrun |

## 4. Notable technical choices

- **python3 rather than jq** in the hooks: shipped by default with the macOS
  developer tools, no extra installation. A shared module
  (`.github/hooks/memory-kit/payload.py`) normalizes the payloads.
- **One payload parser for every shape.** Copilot CLI sends camelCase
  payloads (`toolName`, `toolArgs`) to camelCase hooks and Claude-style
  snake_case payloads to PascalCase hooks. File edits also differ by model:
  GPT models send a raw `apply_patch` string (`*** Update File: …`), Claude
  models send `{path, old_str, new_str}`. The guard understands all of them.
- **Enforce the outcome, not the intent.** Parsing shell commands to predict
  what they write is a losing game (`>|`, `cd dir && >>`, `python -c`,
  `git checkout`, case-variant paths on macOS…). The guard still refuses the
  obvious cases early, but the guarantee comes from `memory-git.sh`, which
  runs after **every** tool call (no matcher, under a lock) and compares the
  protected paths with the last commit: any difference is reverted, any
  deleted memory restored. Only paths present in the last commit are
  protected (an uncommitted kit has no baseline to restore).
- **The guard protects the kit itself.** Otherwise one edit to
  `memory-kit.json` (`disableAllHooks`) would switch every guardrail off.
- **The guard fails safe, not closed.** Copilot CLI denies the tool call when
  a `preToolUse` hook crashes; a buggy guard would block all work. The guard
  catches its own errors and then only denies calls that visibly mention a
  protected path or a secret file; unparseable write arguments go through
  the same check.
- **Shell failures are detected from the output.** Copilot CLI reports a
  command that exits non-zero as a *successful* tool call ending with
  `<… completed with exit code N>`; `postToolUseFailure` only fires for tool
  errors. The error hook handles both (and ignores `grep`/`diff`/`test`
  exiting 1, which is an answer, not an error).
- **The error log never stores command output.** It is re-injected into
  every session, so output (web pages, file contents) would be a persistent
  prompt-injection channel. Only the tool, the command (truncated) and the
  exit code are logged, and the startup block labels them as data.
- **The git hook checks `git status`, not the tool's path.** Agents
  sometimes write files through the shell (`printf > file`), so the hook
  commits whatever changed under `memory/` after any tool call.
- **No `--no-verify`.** Memory commits (and the installer's first commit) let
  the project's git hooks run, so secret scanners still apply; a rejected
  commit leaves the change uncommitted and the agent is told.
- **One fact = one file** in `memory/` (except the error log, append-only):
  limits concurrent-write conflicts and makes the index useful.
- **The error log is capped** (rotation at 400 lines): it is raw material
  for dreaming, not an infinite archive.
- **`memory/scratchpad/` is ignored by git**: it is disposable working memory,
  purged by `dream.sh` (files older than `SCRATCHPAD_MAX_DAYS`).
- **Token alerts use `agentStop` exit code 2**: Copilot CLI shows the hook's
  stderr to the user without blocking or interrupting the work.
- **`dream.sh` uses `--usage-output-file`** to read the AI credits actually
  used and trigger an alert above a threshold (`DREAM_CREDITS_ALERT`, 25 by
  default). It excludes previous dreaming passes from the analysis.
- **Dreaming runs with the least privilege that works.** The pass reads
  untrusted transcripts with `--allow-all-tools` (nobody is there to approve),
  so the tool set itself is narrowed: `--available-tools view grep glob
  create edit apply_patch skill`, `--disable-builtin-mcps`,
  `--disallow-temp-dir`. The selected logs are **copied** to a private temp
  folder, which is the only extra directory granted (`--add-dir`); the copy
  is deleted afterwards. The memory hooks stay active during the pass.
- **The dreaming skill stays model-invocable.** Copilot CLI hides skills
  marked `disable-model-invocation` from the model, which breaks
  non-interactive runs (`copilot -p`). Instead, the skill description and
  AGENTS.md say "only when explicitly asked".

## 5. Accepted limitations

- A hash precondition "managed by the infrastructure" in the strict sense would
  require a server; here git + the edit tool's behavior stand in for it. Sufficient for
  solo use or a small team, to be revisited for a fleet of thousands of agents.
- The kit reads tokens and AI credits from Copilot CLI's local session logs
  (`~/.copilot/session-state/`). That format is not a documented API and may
  change; your plan's official quota is shown by `/usage`.
- The pre-action shell guard uses pattern matching: it catches the usual
  ways of writing or deleting, not every possible program. Integrity relies
  on the post-action revert instead. Neither is a sandbox: a process running
  as the user (a script started in the background, another editor) can
  change files between tool calls; the next tool call reverts it, and git
  keeps the history.
- Human edits to protected paths made **during** a session are reverted too
  (backup in `.git/memory-kit/reverted/`): edit them between sessions and
  commit. On GitHub, CODEOWNERS + branch protection add the human review gate
  the hooks cannot provide.
- Secret files are guarded for `view`/`grep` and for shell commands that name
  them; a program that reads them indirectly is not detectable.
- Fail open: if python3 is missing or a hook times out, Copilot CLI lets the
  call through. A crashing guard denies (fail closed).
- Whether hooks fire for tool calls made by subagents (`task`) is not
  verified; the post-action check on the parent's next tool call still
  applies.
- Dreaming is triggered manually (or via cron, documented): no permanent
  daemon, in line with the simplicity principle.
