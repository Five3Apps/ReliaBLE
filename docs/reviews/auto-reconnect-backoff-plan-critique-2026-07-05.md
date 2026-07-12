# Critique: Automatic Reconnection with Exponential Backoff Plan
*For `docs/plans/auto-reconnect-backoff-2026-07-05.md` · 2026-07-05*

## Context/Scope
This review covers only the three named seams (event-driven retry loop, `reconnectTasks`/`Task.sleep`/re-entrancy, `intentionalDisconnects` clearing), contradictions/missing dependencies, over-planning risks, and order-affecting questions. Spot-check limited to `BluetoothActor.swift:656-737` (current handlers) per instructions. No broader exploration or plan rewrite.

## Findings

### 1. Top 3 Under-Specified Seams
- **Attempt counter across delegate events (BluetoothActor.swift:666,682)**: `scheduleReconnect(id:attempt:)` receives `attempt`, but no storage for a per-peripheral attempt counter is declared alongside `reconnectPolicy`/`reconnectTasks`. `handleDidDisconnect` and `handleDidFailToConnect` both arm the ladder; nothing specifies how the counter is read/incremented on the second+ failure (e.g., after a `.reconnecting` sleep yields a failed `connect`). `handleDidConnect:656` clears it, but the initial value and increment path are undefined.
- **`reconnectTasks` Task + `Task.sleep` + actor re-entrancy (Approach §Scheduler)**: The stored `Task` sleeps then calls `connect(id:)`. Actor re-entrancy on suspension is safe, but concurrent `disconnect`/`invalidatePeripherals` cancellation while sleeping, or a second `scheduleReconnect` racing the first sleep, is unspecified. No mention of checking task existence before overwriting or draining on give-up.
- **`intentionalDisconnects` clearing on all paths (Approach §Scheduler, Q2)**: Inserted in `disconnect:730`; cleared in `handleDidDisconnect`. But `handleDidFailToConnect` (transient connect failure path) and give-up (maxAttempts exceeded) have no clear instruction. Connect-success path also unmentioned; a stale entry could suppress future reconnects.

### 2. Contradictions / Missing Dependencies
- "Clear the attempt counter" (handleDidConnect) and "under `maxAttempts`" (scheduleReconnect) reference an attempt counter that is never added to the stored state list.
- `ReconnectPolicy.enabled` (default true) has no guard location specified; plan states handlers "arm the ladder" without showing where the check occurs.
- `invalidatePeripherals` is listed for task cancellation, but the current actor (lines 650-737) has no such method—plan assumes it exists or will be added.

### 3. Risk of Over-Planning
- Detailed backoff math + jitter formula in Approach can be cut; implementation will be a few lines once policy fields exist.
- Full Demo work item (SettingsView bindings, list-row badge, visual disconnect semantics) is large relative to library changes; consider trimming to "surface `.reconnecting` in detail view only" for v1.

### 4. Questions Affecting Implementation Order
- Where will the attempt counter live (separate `[String:Int]` map, or embedded in `reconnectTasks` value type)? Answer determines state shape before any handler edits.
- Does the `enabled` check live in `scheduleReconnect`, the two handlers, or `connect` itself? Affects whether Work Item 3 can land without Item 1.
- Must `intentionalDisconnects` be cleared on give-up and on `handleDidConnect` success, or only on explicit `disconnect`? Changes the set's lifecycle and test surface.

## Recommendations
Clarify the three seams and the attempt-counter storage question first; everything else (policy plumbing, state enum, tests) follows. Delete the detailed scheduler pseudocode and trim Demo scope to reduce plan surface. Report path: `docs/reviews/auto-reconnect-backoff-plan-critique-2026-07-05.md`.