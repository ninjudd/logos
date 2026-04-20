# list_threads

Enumerate all conversation threads with their consolidation cursor state.

## Description (shown to the model)

List every conversation thread known to the engine, with each thread's total message count, current consolidation cursor, and the number of unconsolidated messages waiting. Use this to plan a consolidation pass — pick the threads whose `unconsolidated` count is worth processing.

## Input

```ts
{}
```

No arguments.

## Output

```ts
{
  threads: Array<{
    channelId: string,
    conversationId: string,
    total: number,         // total messages in the JSONL
    cursor: number,        // last consolidated index (0 if no cursor file)
    unconsolidated: number // total - cursor
  }>
}
```

`threads` is empty if no conversations exist yet. Always returns the discriminated shape — never `null`.

## Behavior

- Walks `runtime/threads/{channelId}/{conversationId}.jsonl`. For each, counts non-blank lines to compute `total`, reads the sidecar `*.cursor` file (a single integer; missing means `0`), computes `unconsolidated = total - cursor`.
- Skips files that don't end in `.jsonl` and any directory entries that aren't conversation files.
- Cheap to call — counts lines without parsing JSON.

## Dependencies

Built-in, no external services. Reads `runtime/threads/`.

## Implementation notes

- Use the same path layout the threads module already enforces.
- Don't validate the cursor against the JSONL contents — if a cursor file says `999` but the JSONL has 5 lines, return `cursor: 999, unconsolidated: -994` and let the caller decide. (Negative `unconsolidated` indicates a corrupt cursor; not the tool's job to fix.)
