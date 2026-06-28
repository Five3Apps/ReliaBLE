# Critique: Peripheral → Sendable Value Struct Plan (2026-06-13)

**Scope**: Plan for ReliaBLE #17 (Peripheral value struct + AdvertisementData + CBPeripheral registry). Review limited to the three named seams.

## 1. Under-specified Seams

**handlePeripheralDiscovered rebuild + registry sync** (`BluetoothActor.swift:266-305`)
- Current code mutates in place via `existing.update(...)` and `discoveredPeripherals.append(new)`. Plan says "rebuild value Peripheral, replace element" but never states the exact lookup/replacement logic or how `cbPeripherals[id] = cbPeripheral` is kept consistent with the two identifier checks (`id` vs `peripheralIdentifier`).
- `invalidatePeripherals()` (318) and `refreshPeripherals()` (326) still call the old class methods; plan gives no replacement for either path. `refreshPeripherals` uses `peripheralIdentifier` which disappears from the value struct, so the `identifiers` collection and the subsequent `first(where:)` will break.

**discoveredPeripherals: AnyPublisher emission**
- Plan claims value-semantic snapshots "rebuilt by replacing elements" will keep the publisher working. It does not address whether `discoveredPeripheralsSubject.send(discoveredPeripherals)` (called after every mutation today) still fires correctly when the array contains immutable structs, or whether duplicate `id` entries can appear after a replacement.

**CBUUID retroactive Sendable vs CBMUUID collision**
- Plan correctly flags the risk in the mock target. It does not state where the guarded declaration lives or whether the production `CBUUID+Sendable.swift` must be excluded from `ReliaBLEMock` target the same way `CBCentralManagerFactory.swift` is.

## 2. Contradictions / Missing Dependencies

- Work Item 5 requires `cbPeripherals` registry, yet the current `invalidatePeripherals`/`refreshPeripherals` paths (already merged in Step 1) are not listed as dependents. They must be rewritten in the same PR or the build will be broken.
- `PeripheralDiscoveryEvent` conversion (Work Item 7) depends on `AdvertisementData` (Item 1) but also on the same extraction code inside `handlePeripheralDiscovered`. No ordering or shared helper is declared.
- `PeripheralError` (Item 4) is required for `connect(to:)` (Item 6), but `connect` is the only consumer; if Item 6 slips, Item 4 is dead weight.

## 3. Over-planning

- Work Item 8 ("Demo adaptation") can be deleted. The plan already asserts that `CentralViewModel` only reads `.id`/`.name`/`.lastSeen` and `.rssi`, all of which survive the struct rewrite. No signature change touches the demo.
- Work Item 10's DocC update is boilerplate; it belongs in the PR description, not a tracked work item.

## 4. Questions That Change Implementation Order

- Must `invalidatePeripherals` and `refreshPeripherals` be rewritten before or after the `Peripheral` struct change? If the registry must stay in sync on power-cycle, the order is forced.
- Is `discoveredPeripheralsSubject` allowed to emit duplicate `id` values after a replacement, or must the plan guarantee uniqueness? The answer determines whether a dictionary or array-with-replace is used.

**Recommendation**: Resolve the three seams above and delete Work Items 8 and 10 before scheduling.