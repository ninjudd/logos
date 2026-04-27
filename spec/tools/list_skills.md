# list_skills

Return the current skill manifest — the same merged view that gets injected into the system prompt at dispatch time.

## Description (shown to the model)

List the skills currently available, with their names, descriptions, and source paths. Use this when:

- You think a skill may have been added, removed, or modified during the conversation and your system prompt's manifest may be stale (the backend caches the prompt for a resumed session, so changes the user just made on disk might not show up until you refresh).
- You want to discover skills you don't remember loading.
- You're about to call `delegate_task` with a `skills:` list and want to confirm the names are still valid.

The skill bodies themselves aren't returned — they're fetched on demand via `read` against the listed `paths`, and `read` always reads from disk so the body is never stale.

## Input

```ts
{}
```

## Output

```ts
Array<{
  name: string,            // skill name (frontmatter `name:` or filename basename)
  description: string,     // frontmatter `description:` — one-line hint shown to the model
  paths: string[],         // workspace-relative path(s) to read for the full body. Two entries when a config skill layers on top of a spec skill (read both, in order, to get the merged body).
  preferred_model?: string, // optional — the profile name a delegate_task call should prefer when this skill is in the skills: list
  enabled?: boolean,       // present and `true` (skills with `enabled: false` are filtered out)
}>
```

Sorted alphabetically by `name`. Disabled skills (`frontmatter.enabled: false`) are omitted — same filter the system prompt applies — so the model sees the same set it would on a fresh dispatch.

## Behavior

Read fresh from disk every call. No caching at the tool layer. Concretely:

1. Scan `spec/skills/*.md` (the bundled set).
2. Scan `config/skills/*.md` and `config/skills/*/SKILL.md` (instance overrides — flat form wins over directory form on collision).
3. Merge: when a config skill shares a `name:` with a spec skill, the layered skill's `paths` field includes both files in order (`[spec, config]`), and the description follows the merge rules in `spec/architecture.md` → Components → Agent → Skills.
4. Filter out `enabled: false`.
5. Return sorted alphabetically by name.

The implementation reuses the existing `loadAllSkills()` helper in `agent/src/agent.ts` — same code path the system prompt uses, so the tool's output is by construction identical to what the manifest would look like on the *next* dispatch.

## Use cases

- **Mid-conversation refresh** — the user mentions "I just added a new skill, can you use it?" The agent calls `list_skills`, sees the new entry, then `read`s its path to use the body.
- **Layered-skill discovery** — the agent wants to use the `coding` skill but isn't sure if the user has overlaid a `config/skills/coding.md` with extra guidance. `list_skills` returns both paths; the agent reads both.
- **Pre-flight check before `delegate_task`** — the agent is about to delegate a sub-task with `skills: ["browser-use", "coding"]`. A quick `list_skills` confirms both names still resolve.

## Dependencies

Internal — `loadAllSkills()` from `agent/src/agent.ts` and the surrounding parsers (frontmatter, merge rules). No external libraries.

## Implementation notes

- **Tool, not skill.** Atomic call, structured output, no playbook decisions. Lives at `agent/src/tools/list_skills.ts` alongside the other custom tools.
- **No `enabled: false` entries.** The filter mirrors the system-prompt manifest filter — keep them in lockstep so the tool can't surface a skill the model couldn't actually use anyway.
- **`paths` are workspace-relative** (e.g. `spec/skills/coding.md`, not absolute) so the agent can pass them straight to `read`.
- **Don't return the body.** Bodies can be 10s of KB; returning all of them would balloon the tool result. The agent reads only the bodies it actually needs.
- **Cheap call.** The skills directories are small (<20 files typically); reading all of them is sub-millisecond. Safe to call freely.
