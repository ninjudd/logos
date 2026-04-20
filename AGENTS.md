# Agents

This workspace is a spec for building a personal AI assistant ("the agent"). If you're a coding agent (Claude Code, Codex, Cursor, …) that the user has opened here, you're here to generate or maintain that assistant's implementation.

The user may invoke you with:

- **`bootstrap <channel>`** — first-time generation. Read `spec/build.md` and generate the implementation in `agent/` for the named channel (telegram, slack, discord, …).
- **`update agent`** — sync an existing implementation with spec changes. Follow `spec/build.md` → Updating.

Start with:

- `spec/build.md` — the bootstrap sequence
- `spec/architecture.md` — system design
- `spec/agent.md` — the base prompt loaded into the running assistant at runtime
