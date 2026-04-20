---
schedule: "0 * * * *"
history: none
---

# Nap

Quick, opportunistic per-thread consolidation. Runs hourly. Threshold-gated — does nothing unless a thread has accumulated enough new messages to be worth processing.

## Approach

This job runs with `history: none`, so your context starts clean. Walk `runtime/threads/`. For each thread, compare its current message count to the cursor in the sidecar `*.cursor` file (missing means 0). For any thread where unconsolidated messages ≥ 50, read those messages, write anything worth remembering into `memory/` (creating files, updating existing ones, using `[[wiki-links]]`), then advance the cursor. Skip threads under the threshold.

Reply with a brief summary of what was consolidated, or `NO_REPLY` if no thread crossed the threshold. The summary goes to the user's primary channel.

## Scope

`nap` does **only** per-thread consolidation. It deliberately skips:

- Journal sweep (`dream`'s job)
- Inbox sweep (`dream`'s job)
- Cross-thread correlations (`dream`'s job — `nap` looks at one thread at a time)
- Orphan check / hierarchy hygiene (`dream`'s job)

The split exists because per-thread consolidation needs to react quickly to bursts of activity (a long conversation in the morning shouldn't have to wait until 23:00), while full hygiene only needs to run once a day. Both jobs share the same cursor scheme, so neither re-consolidates content the other has already processed.

## Threshold

50 messages of unconsolidated tail is a reasonable starting point. The threshold is what prevents `nap` from doing meaningless work every hour on quiet threads — adjust if it's firing too often or letting threads grow too big between consolidations.
