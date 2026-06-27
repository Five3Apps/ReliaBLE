# Critique: `ReliaBLEManager` → nonisolated `Sendable` + collapse `BluetoothManager`

**Reviewer:** opencode (grok-4.3)  
**Date:** 2026-06-23  
**Plan:** `docs/plans/manager-sendable-collapse-2026-06-23.md`

## 1. Top 3 Under-specified Seams

**(a) Inside-out ordering / double-`initialize` risk**  
Work Item 2 moves the fire-and-forget `Task { await BluetoothActor.shared.initialize(...) }` verbatim from `BluetoothManager.init` (BluetoothManager.swift:64) into `ReliaBLEManager.init`.  
- The plan asserts “build stays green at each step” because types move first (Item 1), then the init change (Item 2).  
- However, after Item 1 the `BluetoothManager` class still exists and its `init` still fires the `Task`. If a caller (or test) instantiates `BluetoothManager` directly between Items 1 and 2, `initialize` will be called twice.  
- The plan never states that `BluetoothManager` is made `internal`/`fileprivate` or otherwise hidden after the type relocation, so the ordering claim is incomplete.  
- Double-initialize is harmless today (actor guards `centralManager == nil`), but the seam is unstated.

**(b) `currentBluetoothState` as plain actor-isolated `var`**  
Work Item 3 drops `nonisolated(unsafe)` from `BluetoothActor.currentBluetoothState` (BluetoothActor.swift:101) once `currentState` becomes `get async`.  
- The only remaining reader listed is `register(stateContinuation:)` (line 210), which runs on-actor and does `continuation.yield(currentBluetoothState)`.  
- `broadcastState` (line 280) also writes it while on-actor.  
- No nonisolated reader is shown after the change, so the seam appears safe, but the plan does not explicitly confirm that `stateStream()` callers or any test code still compile.

**(c) `currentState` `get async` vs. existing synchronous surface**  
Work Item 2 applies the decision “`currentState` → `get async`”.  
- `ReliaBLEManager.currentState` is currently documented as “Synchronous, thread-safe” (ReliaBLEManager.swift:72).  
- The plan states DocC examples in `GettingStarted.md:90,105` will be updated (Item 6), but does not list any other synchronous call sites that must be audited (e.g., internal helpers, future test helpers).  
- The synchronous → async change is breaking; the plan treats it as acceptable pre-1.0, but the seam between “update DocC” and “guarantee no other sync readers” is not enumerated.

## 2. Contradictions or Missing Dependencies

- **No dependency on making `BluetoothManager` non-public.** Item 1 relocates the public types; Item 4 deletes the file. Between those steps `BluetoothManager` remains a public symbol that still performs initialization. The plan never says “make `BluetoothManager` internal after Item 1” or “add `@testable import` only for tests,” leaving a window for accidental double-initialize or stale references.
- **DocC update scope.** Item 6 only mentions `GettingStarted.md`. The plan does not check whether any other DocC pages or in-source documentation still reference the synchronous `currentState` or the `BluetoothManager` type after the collapse.

## 3. Risk of Over-planning

- The plan is already minimal. No sections need deletion; the work-item list is appropriately coarse.

## 4. Questions Whose Answers Would Change Implementation Order

1. Can `BluetoothManager` be made `internal` (or `@usableFromInline internal`) immediately after Item 1 without breaking any test target that still links against it?
2. Are there any non-DocC call sites (including generated DocC or other markdown) that read `currentState` synchronously today?
3. Does the test that exercises `testFunction()` (ReliaBLEManagerTests.swift:30) also instantiate `BluetoothManager` directly? If so, removing `testFunction` in Item 3 could mask a double-initialize scenario that only surfaces in tests.

These three answers determine whether Items 2 and 3 can safely be merged or must remain strictly ordered.