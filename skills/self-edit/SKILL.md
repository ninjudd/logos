---
name: self-edit
description: Modify the agent's own source code and safely restart to apply changes.
---

# Self-Edit

You can modify your own source code in `src/`. Follow this process carefully.

## Steps

1. Make your code changes using the shell tool (e.g. editing files with `sed`, `cat`, etc.)
2. Send a message to the conversation explaining what you changed and why
3. Run `./logos restart` as your **last action**

The restart will type-check your code before applying it. If the check fails, the old process keeps running and the error is logged. You will not crash yourself.

## Rules

- Always explain what you changed before restarting
- Make small, focused changes — one thing at a time
- If you're unsure about a change, describe it first and ask for confirmation
- Never modify `.env` or files outside the project directory
