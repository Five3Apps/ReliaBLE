# Critique: Combine → AsyncStream Plan (2026-06-18)

**Scope**: Only the three named seams in `BluetoothActor.swift`, `BluetoothManager.swift`, `ReliaBLEManager.swift` (plan lines 83-108, 244, 287, 336, 341, 359).

## 1. Top 3 Under-specified Seams

- `stateStream()` replay of `currentBluetoothState` (plan:59) — no specification of what happens if `currentBluetoothState` is mutated between the `yield` and the first downstream `for await` consumption.
- `peripheralDiscoveriesStream()` registration window (plan:68) — the documented “event lost” gap is accepted but has no test or logging hook to surface it in production.
- `broadcast(_:to:)` helper (plan:78) — signature, error handling, and whether it removes dead continuations are unspecified.

## 2. Contradictions / Missing Dependencies

- Plan says “Drop `import Combine`” from all three files (Work Items 1-3), yet `BluetoothActor.swift:30` retains `SendableWrapper<T>` which is **not** a Combine type; the TODO markers at :95/:98/:101/:107 are the only Combine-specific lines. Removing the import is safe, but the plan’s wording implies more Combine removal than actually exists.
- `currentBluetoothState` TODO reword (plan:107) is listed under “keep” but the Work Items still say “reword its TODO” — a minor internal inconsistency.

## 3. Risk of Over-planning

- Work Item 5 (new multi-subscriber test) and Work Item 6 (DocC) are full implementation tasks, not plan-level decisions. They can be cut or deferred without changing the broadcaster design.
- The “Open Questions” section is empty; the two cosmetic Demo items do not affect library order.

## 4. Questions That Change Implementation Order

- Must the `onTermination` cleanup `Task` be fire-and-forget, or should it be awaited inside a detached task to guarantee removal before the next broadcast?
- Is `.bufferingNewest(1)` for `state`/`discoveredPeripherals` streams required to be exactly 1, or can it be a larger bounded buffer without affecting the “latest value” replay contract?

**Broadcaster actor-isolation sanity check**: The `Task { @BluetoothActor in … }` body contains only synchronous operations (`yield`, dictionary write, `onTermination` setter). No suspension points exist inside the closure, so the three statements execute as one indivisible actor job. The documented window between `AsyncStream` creation and job start remains the only gap; `.bufferingNewest(1)` + `nonisolated(unsafe) currentBluetoothState` correctly backs both replay and the synchronous `currentState` accessor. No contradictions found in the named seams.
