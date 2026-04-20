# find_orphans

List memory files that are not transitively reachable from any root-level file via `[[wiki-links]]`.

## Description (shown to the model)

Return every non-root memory file that nothing at the root level links to (directly or transitively). Use this during memory hygiene to find files that have been forgotten — either link them in from a relevant root file or move/delete them.

## Input

```ts
{}
```

No arguments.

## Output

```ts
{ orphans: Array<{ path: string }> }
```

`orphans` is empty when every non-root file is reachable. Always returns the discriminated shape — never `null`.

## Behavior

- Considers every `memory/*.md` file (top-level only) a **root**.
- Walks outgoing `[[wiki-link]]` edges from each root, transitively, marking every reached file.
- Any non-root file (i.e. under a subfolder) not marked is an orphan and goes in the output.
- Treats `memory/journal/*.md` and `memory/new/*.md` as **excluded** — those are managed independently (journal is a scratch pad; inbox is a holding pen). They never appear in `orphans`.
- Uses the cached memory graph (`runtime/memory-graph.json`); rebuilds via mtime check if stale.

## Dependencies

Internal `agent/src/memory.ts` module (graph + cache).

## Implementation notes

- Reachability is computed on the existing graph data structure — no extra disk reads beyond cache rebuild.
- A file with no incoming links from anywhere can still be reachable if a root file links to it directly. The check is reachability from roots, not in-degree.
