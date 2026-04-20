# rename_memory

Move a memory file to a new path and rewrite every `[[wiki-link]]` that points to it.

## Description (shown to the model)

Rename or move a memory file safely — moves the file AND updates every `[[wiki-link]]` in other memory files that targeted the old name, so links don't break. Use this when promoting/demoting between root and subfolders or reorganizing the graph.

## Input

```ts
{ oldPath: string, newPath: string }
```

Both paths are workspace-relative (e.g. `memory/preferences/coffee.md`). Both must be under `memory/`.

## Output

```ts
{ ok: true, updatedFiles: string[], updatedLinks: number }
```

- `updatedFiles` is the list of memory files whose contents were modified to fix wiki-links.
- `updatedLinks` is the total number of `[[...]]` occurrences rewritten.

Always returns the discriminated shape — never `null`.

## Behavior

1. Refuse if `oldPath` doesn't exist or `newPath` already exists.
2. Refuse if either path is outside `memory/`.
3. Compute the old name (filename without `.md`) and the new name.
4. Move the file with `fs.rename`. If `newPath`'s parent directory doesn't exist, create it.
5. Scan every `memory/**/*.md` for `[[oldName]]` and `[[oldName|...]]` references. Rewrite to `[[newName]]` / `[[newName|...]]`. Preserve the display-text portion. Also handle path-qualified links: `[[oldFolder/oldName]]` → `[[newFolder/newName]]` when both folder and name change.
6. Invalidate the memory graph cache so the next graph operation rebuilds.

## Dependencies

Internal `agent/src/memory.ts` module.

## Implementation notes

- Use the existing wiki-link parser; don't hand-roll a regex that matches across embeds (`![[...]]`) and aliases (`[[name|display]]`) inconsistently. The same parser the graph builder uses should be reused.
- Atomic at the file-move level only. If link rewriting fails partway through, the file has already been moved — log clearly which files were updated before the failure so the agent can finish manually.
- Renaming a file that's referenced by `aliases:` frontmatter in other files is NOT handled; aliases are about names, not paths, and aren't affected by file moves.
