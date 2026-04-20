---
name: update
description: Check for spec updates and apply them via a coding agent.
---

# Update

When the owner asks you to "check for updates", "sync with spec", or similar, delegate the work to a coding agent. The running agent orchestrates; the coding agent does the diff and apply.

## Steps

1. **Confirm with the owner** that you should proceed. A spec update can touch many files in `agent/` — ask before running.
2. **Delegate via the coding skill.** Use the **coding** skill to spawn Claude Code or Codex from the workspace root with the prompt `update agent`. That's the command defined in `AGENTS.md`; the coding agent pulls the latest `spec/`, diffs it against `agent/`, and follows `spec/build.md` → Updating to apply and commit the changes.
3. **Report back.** Summarize what changed in `agent/`. If anything under `agent/src/` was touched, remind the owner to run `agent/protos restart` to pick up the changes.

## Rules

- Don't attempt the diff or edits yourself. Spec syncs can span many files; the coding agent has the right tools.
- Never touch `config/`, `memory/`, or `runtime/` — spec updates regenerate `agent/` only.
- If the coding agent reports nothing to update, tell the owner that spec is already current.
