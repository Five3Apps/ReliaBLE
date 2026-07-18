# Background Scanning + State Restoration: Plan Critique

**Scope**: Review of `docs/plans/background-scanning-state-restoration-2026-07-13.md` (Issue #38 / FR-8.3) against current `Sources/ReliaBLE/BluetoothActor.swift`. Focus limited to under-specified seams, work-item dependencies, over-planning, and ordering questions. All 6 design decisions are accepted as resolved.

## 1. Top 3 Under-Specified Seams

1. **Lazy-init vs. eager-creation reconciliation (BluetoothActor.swift:291–331)**: `ensureInitialized` creates the central only on `.allowedAlways`; the plan states `restoreIdentifier` forces eager creation at `init`. No explicit overload or flag is described for how `ReliaBLEManager.init(config:)` bypasses the auth gate while still honoring the lazy-prompt contract for `authorizeBluetooth()`.

2. **`willRestoreState` → connection rehydration (plan step 4 + BluetoothActor:130,135)**: Seed `connectionStates[id]` from `CBPeripheral.state` and re-arm `reconnectEnabled` for connected/connecting IDs. Unspecified: whether restored peripherals bypass `handlePeripheralDiscovered` identity logic (line 546), how `cbPeripherals` is populated before the seed, and whether `reconnectAttempts`/`reconnectTasks` must be explicitly cleared (currently empty on restore).

3. **Teardown interaction with restored state (BluetoothActor:620 `invalidatePeripherals`)**: Called on `.resetting`/`.unauthorized`. The plan does not state whether `handleWillRestoreState` must defensively clear or preserve `reconnectEnabled`/`connectionStates` when `invalidatePeripherals` later fires, nor whether restored intent survives a subsequent state transition.

## 2. Work-Item Ordering / Dependency Issues

- Steps 2–3 introduce `DelegateEvent.willRestore` and `handleWillRestoreState` before step 5 flips creation to eager. The code path is unreachable until step 5; ordering is acceptable but the plan should note the temporary dead code.
- Eager-creation (step 5) vs. lazy-auth (step 1) creates a new init path that still must not trigger the permission prompt. The interaction is mentioned but not sequenced.
- `invalidatePeripherals` (called from `handleCentralManagerStateUpdate`) clears `reconnectEnabled` and `connectionStates`. No work item ensures restored reconnection intent is re-seeded after a later reset/unauthorized cycle.

## 3. Sections to Cut or Simplify

- Work item 6 ("Connect notification options: none for now") and work item 7 (background-scan guard) are single-line changes with no new API surface. They add noise; fold into the restoration-handler or scanning items.
- Work item 10 (Demo) is explicitly delegated; its inclusion in the main plan list is unnecessary.

## 4. Questions That Would Change Implementation Order

- Does `restoreIdentifier` presence also force creation of the central even when authorization is still `.notDetermined`, or only after `.allowedAlways` is observed? (Answer determines whether the eager path must also short-circuit the auth gate inside `ensureInitialized`.)