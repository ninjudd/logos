# advance_cursor

Mark messages as consolidated by writing the consolidation cursor.

## Description (shown to the model)

Write the consolidation cursor for a thread. Pass the `newCursor` value returned by the most recent `read_thread_tail` call after you've finished processing those messages. Skip this step on failure — the cursor only advances when consolidation actually happened.

## Input

```ts
{ channelId: string, conversationId: string, to: number }
```

`to` is the new cursor value (count of consolidated messages from the start of the JSONL). Use the `newCursor` returned by `read_thread_tail`.

## Output

```ts
{ ok: true, previous: number, current: number }
```

`previous` is the cursor before the call, `current` is the new value. Always returns the discriminated shape — never `null`.

## Behavior

- Writes a single integer to `runtime/threads/{channelId}/{conversationId}.cursor`.
- Creates the parent directory if missing (matching the threads module's lazy-create pattern).
- Does NOT verify `to` against the thread's actual line count. The caller passes the `newCursor` from `read_thread_tail`; trusting it avoids re-reading the JSONL.
- Refuses to move the cursor backward — if `to < previous`, return an error rather than silently rewinding. (Going backward would re-consolidate already-processed messages and likely create duplicate memory entries.)

## Dependencies

Built-in, no external services. Writes `runtime/threads/`.

## Implementation notes

- Validate `to >= 0` and `to >= previous`. On violation, throw with a clear message — do not write.
