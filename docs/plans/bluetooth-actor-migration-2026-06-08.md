# BluetoothActor Migration: Plan (Step 1 of 5)
*Issue #13 · 2026-06-08*

## Goal

Introduce `@globalActor BluetoothActor` and `BluetoothDelegateShim` so all CoreBluetooth-touching state and callbacks are serialized by Swift actor isolation. Fixes the three unsynchronized concurrency domains currently sharing `centralManager`, `stateSubject`, and `discoverySubject` with zero synchronization (`BluetoothManager.swift:41,81,199`). `updateState()` reads `centralManager?.state` and `.isScanning` off-queue from the caller thread (`BluetoothManager.swift:108,113,170,195`), violating CoreBluetooth's queue-affinity contract. See `docs/investigations/swift6-concurrency-audit-2026-05-13.md §1, §A, §D`.

This is **Step 1 of 5**. The public `AnyPublisher` surface and the `Peripheral` class are untouched; those are Steps 3 (#12) and 2 (#17).

## Background

**Three domains, no synchronization.**
- Domain 1 (caller thread): `init`, `authorize`, `startScanning`, `stopScanning`, `updateState`
- Domain 2 (`BluetoothManager.queue` dispatch): all `CBCentralManagerDelegate` callbacks
- Domain 3 (Combine subscriber threads): downstream of `subject.send(...)`

**Mock target.** `CoreBluetoothMockAliases.swift` aliases `CBCentralManagerDelegate` → `CBMCentralManagerDelegate`. The new shim conforming to `CBCentralManagerDelegate` picks up the mock type automatically in `ReliaBLEMock` — no alias changes needed. `CBCentralManagerFactory.swift` is excluded from `ReliaBLEMock` via `Package.swift:33`.

**Step handoffs (do not implement here):**
- Step 2 (#17): `Peripheral` → `Sendable` value struct; `CBPeripheral` registry fully actor-owned
- Step 3 (#12): Replace `AnyPublisher` with `AsyncStream`; remove all `@unchecked Sendable`/`nonisolated(unsafe)` Combine workarounds from this step
- Step 4 (#18): `ReliaBLEManager` → `nonisolated Sendable`; collapse `BluetoothManager` into the actor
- Step 5 (#19): `-strict-concurrency=complete` flag flip + logging polish + DocC

## Approach

### `BluetoothActor` — `@globalActor` singleton

`BluetoothActor` is a **process-wide** `@globalActor` (`static let shared = BluetoothActor()`). Two `ReliaBLEManager` instances share the same actor (same isolation domain). This matches the issue spec and is acceptable because a single BLE central manager per process is already a CoreBluetooth constraint.

All mutable BLE state moves here: `centralManager: CBCentralManager?`, the three Combine subjects, and the `discoveredPeripherals: [Peripheral]` array (currently on `PeripheralManager`). All mutations happen from actor-isolated methods only.

### `BluetoothDelegateShim` — nonisolated delegate bridge

`nonisolated final class: NSObject, CBCentralManagerDelegate`. No stored state. Each delegate callback is `nonisolated` and hops to the actor via `Task { @BluetoothActor in BluetoothActor.shared.handleXxx(...) }`. No weak/unowned capture needed — the shim simply references the process-lifetime `BluetoothActor.shared` singleton.

### Combine bridge (transitional)

Subjects are regular **actor-isolated** `let` properties. Publishers are extracted once in actor `init` and stored as `nonisolated(unsafe) let` properties:

```swift
private let stateSubject = CurrentValueSubject<BluetoothState, Never>(.unknown)
nonisolated(unsafe) let statePublisher: AnyPublisher<BluetoothState, Never>
// in init: statePublisher = stateSubject.eraseToAnyPublisher()
// TODO: removed in Step 3
```

`subject.send(...)` is only ever called from actor-isolated context (serial executor prevents concurrent writes). Reading the publisher reference via `nonisolated(unsafe)` is safe. `BluetoothManager`'s sync `AnyPublisher` computed properties consume these directly. Every workaround is tagged `// TODO: removed in Step 3`.

`Peripheral` is already `@unchecked Sendable` (`Peripheral.swift:41`), so `[Peripheral]` satisfies `Sendable`. The `discoveredPeripheralsSubject` emission compiles under the same pattern.

### `currentState` sync access

The actor exposes a single `nonisolated(unsafe) var currentBluetoothState: BluetoothState = .unknown`. Only the actor-isolated `broadcastState(_:)` method writes it (serial executor prevents concurrent writes). `BluetoothManager.currentState` reads it directly. Tagged `// TODO: removed in Step 3`.

### `init` stays synchronous

`BluetoothManager.init` and `ReliaBLEManager.init` must remain synchronous. The initial `setupCentralManager()` (if auth is already `.allowedAlways`) and `updateState()` calls dispatch via `Task { @BluetoothActor in … }` rather than awaiting. Consumers see the initial state on the next run-loop turn — indistinguishable from current behavior.

### Public API: `authorizeBluetooth` / `startScanning` / `stopScanning` become `async`

By decision: Step 1 owns the public-API async break. `ReliaBLEManager.authorizeBluetooth()`, `startScanning()`, `stopScanning()` become `async throws`/`async`. Pre-1.0, no external consumers; breaking is acceptable. Step 4 removes `BluetoothManager` as an internal indirection but does not re-break the API.

### `PeripheralManager` is deleted

`discoveredPeripheral(_:advertisementData:rssi:)`, `invalidatePeripherals()`, and the discovery dedup logic move directly onto `BluetoothActor`. `refreshPeripherals(using:)` (`PeripheralManager.swift:81`) no longer needs its `CBCentralManager` parameter — actor-isolated code accesses `self.centralManager` directly. `PeripheralManager.swift` is deleted. Step 4 inherits no collapse work from this file.

### Preserved invariants

- `forceMock: true` literal at `CBCentralManagerFactory.instance(...)` — unchanged, just moves into the actor's `setupCentralManager()`.
- Lazy-init of `CBCentralManager` — `setupCentralManager()` retains its `guard centralManager == nil` check and is still called only when `.allowedAlways` or `authorize()` is called.
- Three-target SPM trick — `Package.swift` untouched; mock aliases cover the shim's delegate conformance automatically.

## Work Items

1. **Create `Sources/ReliaBLE/BluetoothActor.swift`** — declare `@globalActor public actor BluetoothActor { public static let shared = BluetoothActor() }` with all actor-isolated state (`centralManager`, subjects, `discoveredPeripherals`), `nonisolated(unsafe)` publisher + `currentBluetoothState` properties, and `BluetoothDelegateShim`.

2. **Port actor-isolated methods** — `setupCentralManager`, `authorize`, `startScanning`, `stopScanning`, `updateState`/`broadcastState`, `centralManagerDidUpdateState`, `centralManager(_:didDiscover:...)`, plus the three inlined `PeripheralManager` methods (discovery dedup, invalidate, refresh-without-param).

3. **Wire the shim** — shim's `@Sendable` closures hop each callback to `BluetoothActor.shared`. Factory call in `setupCentralManager` passes the shim as delegate. Shim stored as actor property to keep it alive.

4. **Refactor `BluetoothManager`** — remove `NSObject`/`CBCentralManagerDelegate` conformance, `queue: DispatchQueue`. Methods `authorize()`, `startScanning()`, `stopScanning()` become `async` forwarders. Sync computed properties (`state`, `currentState`, `peripheralDiscoveries`) read from actor's `nonisolated(unsafe)` properties.

5. **Delete `Sources/ReliaBLE/PeripheralManager.swift`**.

6. **Update `ReliaBLEManager`** — `authorizeBluetooth()`, `startScanning()`, `stopScanning()` become `async throws`/`async`. Update DocC on these methods. Publisher properties unchanged.

7. **Update Demo app** — `Demo/ReliaBLE Demo/ReliaBLE Demo/Central/CentralViewModel.swift:101,105,109` calls `authorizeBluetooth()`, `startScanning()`, and `stopScanning()` synchronously. Wrap each in `Task { await … }` (or `Task { try? await … }` for the throwing one). No other Demo files call these methods. Demo conventions are looser (see `Demo/AGENTS.md`) — fire-and-forget `Task {}` is appropriate here.

8. **Build and test** — `swift build` clean; `swift test` passes. Grep that no `centralManager.state` / `centralManager.isScanning` read occurs outside actor isolation.

9. **DocC** — Add `BluetoothActor` entry in `Documentation.docc/`. Update `GettingStarted.md` for the async public methods.

## References

- Audit: `docs/investigations/swift6-concurrency-audit-2026-05-13.md` — §1 (Cluster 1), §A, §D
- Issue #13: https://github.com/Five3Apps/ReliaBLE/issues/13
- Parent: https://github.com/Five3Apps/ReliaBLE/issues/10
- WWDC24 session 10169 — Migrate your app to Swift 6
