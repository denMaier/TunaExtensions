# Agent

Hand a question or a task to an agent CLI you already have, without opening a terminal. Requires
macOS 15 or later and Tuna 0.96 or later.

## Use it

| First | Then | Third |
| --- | --- | --- |
| typed text | **Ask Agent** | — |
| **Ask Agent** | **Ask…** | typed text |
| one or more files or folders | **Ask Agent About…** | typed text |

Tuna hides and the request runs as a Shelf task named after its first words. When it ends, the
task row goes away and:

- **Done:** the agent changed what you asked and there's nothing to read. A small
  **Agent: Done!** banner appears.
- **Answer:** Tuna opens with the answer as text in the subject pane, so you can copy it, paste
  it, show it in Large Type, add it to the Shelf, or ask again about it.
- **Failed:** Tuna opens the same way with "Agent couldn't do it:" and the reason. This covers
  anything not done or done only in part, a missing CLI, a non-zero exit, a reply that can't be
  read, and the 10-minute timeout.

The text comes back through Tuna's documented `tuna://stage?subject=text:…` link, which fills the
panes without running anything.

Every request is a single shot: there are no follow-up questions. The agent is told that it can't
ask, and should report a failure rather than guess at an unclear or risky request.

## Settings

**Agent** picks the CLI. It must be installed and signed in. Tuna looks on its own `PATH`, then
in `/opt/homebrew/bin`, `/usr/local/bin`, and `~/.local/bin`.

| Agent | Command | Unattended mode |
| --- | --- | --- |
| Claude Code (default) | `claude -p` | `--permission-mode auto`: a classifier allows routine actions and blocks risky or unrequested ones. No session is saved. |
| Codex | `codex exec` | `--approve-for-me`: automatic review inside Codex's `workspace-write` sandbox, so commands write only in your home folder and temporary folders. The run is `--ephemeral`. |
| Antigravity | `agy -p` | `--sandbox` (terminal restrictions) in its default mode. Its `auto` mode isn't available on every account, and the default mode runs commands without asking, so this is the least guarded choice. |

## Security and privacy

- The agent runs as you, in your home folder. Folders of selected files outside your home folder
  are added with `--add-dir`. What it may do is decided by the CLI's mode above, not by Tuna.
- The request, and the paths of selected files, go to the agent's provider under your account and
  may cost usage. The CLI also loads its own configuration, such as `~/.claude/CLAUDE.md`.
- Requests are passed as an argument with no shell in between, and standard input is empty.
- The extension stores nothing. Tuna's log gets one line per run: the agent, the outcome kind,
  and the duration. Never the request or the reply.
- Codex's schema and reply files live in a private temporary folder that is removed after each
  run.

## Limits

- No follow-ups, no model picker, and no live progress on the Shelf.
- Cancelling the Shelf task stops the CLI, but work already done stays done.
- A reply that arrives while you're using Tuna replaces what's in its panes.
- The done, answer, and failed split is the agent's own report. A wrong report can hide an answer
  behind the banner; unreadable replies always fail instead.
