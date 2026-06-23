# Peripheral → Sendable Value Struct + AdvertisementData: Plan (Step 2 of 5)
*Issue #17 · 2026-06-13*

## Goal

Replace the `@unchecked Sendable` `Peripheral` class — which leaks `CBPeripheral?` and `[String: Any]?` through its public surface under a false `Sendable` promise — with a true `Sendable` value struct. Introduce a strongly-typed `AdvertisementData` struct to replace `[String: Any]`. Keep the live `CBPeripheral` reference inside `BluetoothActor` in an `id`-keyed registry that never escapes the actor. Add `id`-based operation entry points (`connect(to:)`) that throw `PeripheralError.notFound` on a stale snapshot. Fixes **Cluster 3** of the Swift 6 concurrency audit.

This is **Step 2 of 5**. Combine → AsyncStream is Step 3 (#12); `ReliaBLEManager` `Sendable` conformance is Step 4 (#18). The `AnyPublisher` surface stays in this PR.

## Background

Step 1 (#13) is merged: `@globalActor BluetoothActor` and `BluetoothDelegateShim` already exist and own all BLE state. There is **no** `PeripheralManager` class in the library — the issue's item #4 refers to work already absorbed into `BluetoothActor` in Step 1. The registry today is the actor's `discoveredPeripherals: [Peripheral]` array.

**Current `Peripheral`** (`Sources/ReliaBLE/Models/Peripheral.swift`):
- `public final class Peripheral: Identifiable, Hashable, @unchecked Sendable`, NSLock-guarded.
- Stored: `id: String`, `_peripheralIdentifier: UUID?`, `_peripheral: CBPeripheral?`, `_rssi: Int?`, `_advertisementData: [String: Any]?`, `_lastSeen: Date?`.
- Computed: `name` (falls back to `advertisementData[CBAdvertisementDataLocalNameKey]`), `serviceUUIDs` (from `advertisementData[CBAdvertisementDataServiceUUIDsKey]`).
- Mutation API: `init(id:peripheral:advertisementData:rssi:)`, `update(cbPeripheral:advertisementData:rssi:)` (:129), `invalidateCBPeripheral()` (:145).
- Equality/hash already key on `id` only.

**Discovery flow** (`Sources/ReliaBLE/BluetoothActor.swift`):
- `BluetoothDelegateShim.centralManager(_:didDiscover:advertisementData:rssi:)` (:344) wraps non-Sendable values in `SendableWrapper` and hops to the actor.
- `handlePeripheralDiscovered(_:advertisementData:rssi:)` (:266–305): builds `PeripheralDiscoveryEvent` (:280) from raw `[String: Any]`; derives `identifier = cbPeripheral.name ?? advertisementData[localName] ?? cbPeripheral.identifier.uuidString`; looks up an existing `Peripheral` by `id`/`peripheralIdentifier` and calls `update(...)`, else constructs a new `Peripheral` (:302) and appends + publishes.
- `refreshPeripherals()` (:~326) obtains `CBPeripheral`s via `centralManager.retrievePeripherals(withIdentifiers:)` and calls `update(...)`.

**Public surface today** (`ReliaBLEManager.swift`): `state`, `currentState`, `authorizeBluetooth()`, `peripheralDiscoveries: AnyPublisher<PeripheralDiscoveryEvent, Never>`, `discoveredPeripherals: AnyPublisher<[Peripheral], Never>`, `startScanning(services:)`, `stopScanning()`. **No** `connect`/`disconnect` exists anywhere in the library yet.

**`PeripheralDiscoveryEvent`** (`Models/Events/PeripheralDiscoveryEvent.swift`): public struct, also stores `advertisementData: [String: Any]` (:49) with computed `serviceUUIDs` (:39). It does *not* wrap a `Peripheral`. This is a **second** `[String: Any]` leak in the public surface, converted to `AdvertisementData` in this issue.

**Errors**: only `AuthorizationError` exists (`BluetoothManager.swift:197`). No `PeripheralError`.

**Mock target**: `CoreBluetoothMockAliases.swift` already aliases `CBUUID = CBMUUID` (:42) and `CBPeripheral = CBMPeripheral`. There are **zero** `@retroactive`/retroactive-`Sendable` conformances anywhere in `Sources/`.

## Approach

### `Peripheral` → pure value struct

```swift
public struct Peripheral: Sendable, Identifiable, Hashable {
    public let id: String           // app-supplied or CB UUID string
    public let cbIdentifier: UUID?  // CB's own identifier, for retrieval
    public let name: String?
    public let rssi: Int?
    public let lastSeen: Date?
    public let advertisement: AdvertisementData?  // nil until discovered (see Addendum)

    public init(id: String)  // app-facing pre-discovery construction (see Addendum)
    // internal full init used by BluetoothActor at discovery time
}
```

- No `CBPeripheral`, no `[String: Any]`, no `NSLock`. `Equatable`/`Hashable` key on `id` only (matches today; lets `AdvertisementData` stay out of the hash — see below).
- `name` becomes a stored field, resolved once at discovery time (`cbPeripheral.name ?? advertisement.localName`).
- `cbIdentifier` replaces the internal `peripheralIdentifier`; it is the lookup bridge back to the live `CBPeripheral`.
- **As-built:** `advertisement` shipped as `AdvertisementData?` and a `public init(id:)` was restored — see the Addendum at the end of this document.

### `AdvertisementData` — strongly-typed, extracted once

```swift
public struct AdvertisementData: Sendable, Hashable {
    public let localName: String?
    public let serviceUUIDs: [CBUUID]
    public let manufacturerData: Data?
    public let txPowerLevel: Int?
    public let isConnectable: Bool?
    public let serviceData: [CBUUID: Data]
    public let overflowServiceUUIDs: [CBUUID]
    public let solicitedServiceUUIDs: [CBUUID]
}
```

A single internal `init(rawAdvertisementData: [String: Any])` performs all `CBAdvertisementData*Key` extraction at discovery time, inside the actor. `[String: Any]` never leaves the actor.

**Decision:** typed-only for now — no `rawAdvertisement: [String: any Sendable]` hatch. A dict of `any Sendable` is neither `Hashable` nor `Equatable` and would force hand-rolled conformance or dropping `Hashable`; the clean typed surface ships now and a raw hatch can be added in a follow-up if integrators need vendor-extension keys.

### `CBPeripheral` registry inside `BluetoothActor`

Add an actor-private `var cbPeripherals: [String: CBPeripheral] = [:]` keyed by `Peripheral.id`. The mutable reference never escapes the actor. The existing `discoveredPeripherals` array stays `[Peripheral]` (now value snapshots). Three existing paths must change together (all in the same PR, or the build breaks):

- **`handlePeripheralDiscovered`** (:266–305): today the two lookups (`$0.id == identifier`, then `$0.peripheralIdentifier == cbPeripheral.identifier`) call `existing.update(...)`. With value structs, find the index and **replace** (`discoveredPeripherals[idx] = rebuilt`), and set `cbPeripherals[id] = cbPeripheral`. The lookup-before-append already guarantees `id` uniqueness, so the array stays duplicate-free. The method's hand-inlining (and its `// TODO: Step 2 — refactor once Peripheral is a Sendable value type` note) exists only because `CBPeripheral` couldn't cross actor-method boundaries; with the value struct, extraction can move into a shared helper.
- **`invalidatePeripherals`** (:318): drops the `peripheral.invalidateCBPeripheral()` loop — it becomes `cbPeripherals.removeAll()` (the value snapshots hold no CB ref to clear), then re-emit.
- **`refreshPeripherals`** (:326): replace `peripheralIdentifier`/`p.update(cbPeripheral:)` with `cbIdentifier`-based retrieval that re-populates `cbPeripherals[id] = cbPeripheral` for matching entries. No struct mutation.

### `id`-keyed operations + `PeripheralError`

```swift
public enum PeripheralError: Error, Sendable { case notFound }

// ReliaBLEManager
public func connect(to peripheral: Peripheral) async throws

// BluetoothActor
func connect(id: String) async throws {
    guard let cb = cbPeripherals[id] else { throw PeripheralError.notFound }
    centralManager?.connect(cb, options: nil)
}
```

`connect(to:)` forwards the stable `id`; the actor looks up the live `CBPeripheral` and throws `PeripheralError.notFound` if the registry no longer holds it (stale snapshot after invalidation). **Decision:** scope is the entry point + lookup + `notFound` only — `centralManager.connect(cb, options: nil)` is fired, but the full connection lifecycle (didConnect/didDisconnect handling, a connection-state surface) is deferred to a later issue.

### `CBUUID: Sendable`

Add `extension CBUUID: @retroactive @unchecked Sendable {}` with a comment that `CBUUID` is effectively immutable after init. **Risk:** in `ReliaBLEMock`, `CBUUID` resolves to `CBMUUID`; if Nordic already declares `CBMUUID: Sendable`, the extension is a redundant-conformance compile error in that target. Verify per target; guard with a parallel/conditional declaration only if needed.

## Work Items

1. **`AdvertisementData`** — new file `Sources/ReliaBLE/Models/AdvertisementData.swift`. Struct + internal `init(rawAdvertisementData: [String: Any])` doing all key extraction (localName, serviceUUIDs, manufacturerData, txPowerLevel, isConnectable, serviceData, overflow/solicited UUIDs). Typed-only, clean `Hashable` — no raw escape hatch. **Build this first** — Items 5 and 7 both consume the same extraction (build the `AdvertisementData` once in `handlePeripheralDiscovered`, feed it to both the `Peripheral` and the event).
2. **`CBUUID` Sendable** — add the `@retroactive @unchecked Sendable` extension (own small file, e.g. `Sources/ReliaBLE/CBUUID+Sendable.swift`). It lives in the **shared** source tree (no `Package.swift` exclusion like `CBCentralManagerFactory.swift`), so in `ReliaBLEMock` it applies to `CBMUUID` via the existing `CBUUID = CBMUUID` alias. Build both targets; **if** Nordic already declares `CBMUUID: Sendable` the extension is a redundant-conformance error in the mock target — only then guard it (e.g. `#if`/move the mock-side declaration into `CoreBluetoothMockAliases.swift`).
3. **`Peripheral` struct rewrite** — replace the class in `Peripheral.swift`. Remove NSLock, `_peripheral`, `update`, `invalidateCBPeripheral`. New stored fields per Approach. Keep `Identifiable`/`Hashable` (by `id`).
4. **`PeripheralError`** — add `public enum PeripheralError: Error, Sendable { case notFound }` (new file or alongside `AuthorizationError`).
5. **`BluetoothActor` rewrite of discovery** — add the `cbPeripherals: [String: CBPeripheral]` registry and rewrite all three paths per Approach: `handlePeripheralDiscovered` (extract once, replace-by-index, set registry), `invalidatePeripherals` (clear registry), `refreshPeripherals` (use `cbIdentifier`, repopulate registry). These must land in the same PR — they currently call the class-only `update()`/`invalidateCBPeripheral()`/`peripheralIdentifier`, which all disappear.
6. **`connect(to:)` entry points** — add `connect(id:)` (and the registry lookup + `PeripheralError.notFound`) on `BluetoothActor`; expose `connect(to:)` on `ReliaBLEManager`. Entry-point-only (no connection lifecycle) per Decision 3.
7. **`PeripheralDiscoveryEvent`** — replace `advertisementData: [String: Any]` with `advertisement: AdvertisementData`; drop the computed `serviceUUIDs` (now on `AdvertisementData`). Build it from the same extracted `AdvertisementData` in `handlePeripheralDiscovered`. Demo reads only `.id`/`.name`/`.rssi` — unaffected.
8. **Unit test** — capture a `Peripheral` inside a `Task.detached` closure (compile-time `Sendable` proof); assert `connect` on a stale id throws `PeripheralError.notFound`.
9. **Verify + docs** — `swift build` + `swift test` for `ReliaBLE`, `ReliaBLEMock`, `ReliaBLETests`; confirm the Demo still builds (it reads only `.id`/`.name`/`.lastSeen` + event `.id`/`.name`/`.rssi`, all preserved). Confirm no `CBPeripheral` / `[String: Any]` in any public type. Update the DocC catalog for the new public surface (`Peripheral`, `AdvertisementData`, `connect(to:)`, `PeripheralError`) per the project's DocC rule.

## Decisions (resolved at planning)

1. **`PeripheralDiscoveryEvent` is converted in #17** — its `[String: Any]` becomes `AdvertisementData`, honoring "no `[String: Any]` in any public type."
2. **`AdvertisementData` is typed-only** — no `rawAdvertisement` escape hatch (would break `Hashable`); a raw hatch is a possible follow-up.
3. **`connect(to:)` is entry-point-only** — lookup + `centralManager.connect` + `PeripheralError.notFound`; full connection lifecycle deferred to a later issue.

## Open Questions

None blocking. One implementation-time risk: the `CBUUID: @retroactive @unchecked Sendable` extension may collide with an upstream `CBMUUID: Sendable` in `ReliaBLEMock` (redundant conformance). Resolve at the build step (Work Item 2) — guard per target only if the error appears.

## References

- Investigation report: `docs/investigations/swift6-concurrency-audit-2026-05-13.md` — §3, Cluster 3, Recommendations §B (target design at lines ~697–760).
- Step 1 plan: `docs/plans/bluetooth-actor-migration-2026-06-08.md`
- Issue #17 (this); parent #10; depends on #13 (merged, PR #23). Hands off to #12 (Step 3) and #18 (Step 4).
- Key files: `Sources/ReliaBLE/Models/Peripheral.swift`, `Sources/ReliaBLE/BluetoothActor.swift` (:266–305, :326, :344), `Sources/ReliaBLE/Models/Events/PeripheralDiscoveryEvent.swift`, `Sources/ReliaBLE/ReliaBLEManager.swift`, `Sources/ReliaBLEMock/CoreBluetoothMockAliases.swift`.

## Addendum — As-Built Notes (2026-06-15)

Records where the shipped implementation deviates from or clarifies the plan above. The plan body is left intact as the original intent; this section is authoritative where the two differ.

### 1. `Peripheral` is publicly constructible (reversed from the original cut)

The original draft made all initializers internal, which removed the old `public init`. This was reversed during review:

- Added **`public init(id: String)`** so an integrating app can register a known peripheral *before* discovery — e.g. a wearable bound to the user's account — to be matched against its `CBPeripheral` once discovered (the FR-8.5 custom-advertised-ID path, still unimplemented).
- The fully-specified initializer (`id:cbIdentifier:name:rssi:lastSeen:advertisement:`) remains **internal**, used only by `BluetoothActor` at discovery time.
- `AdvertisementData.init(rawAdvertisementData:)` remains **internal** — the "extract the `[String: Any]` exactly once, inside the actor" invariant is preserved. Apps construct a `Peripheral` by `id`; only the library ever builds an `AdvertisementData`.

### 2. `Peripheral.advertisement` is optional (`AdvertisementData?`)

Because an app-constructed, pre-discovery `Peripheral` has no advertisement yet, `advertisement` shipped as `AdvertisementData?` (`nil` until discovery populates it). This honestly distinguishes "not yet seen advertising" from "advertised nothing," and avoids needing a public empty `AdvertisementData` initializer. Likewise `cbIdentifier`/`name`/`rssi`/`lastSeen` are empty on an app-constructed snapshot.

- `PeripheralDiscoveryEvent.advertisement` stays **non-optional** — an event always originates from a received advertisement packet.
- Consumer impact: reading advertisement off a discovered peripheral now optional-chains, e.g. `peripheral.advertisement?.serviceUUIDs ?? []`.

### 3. Service UUIDs stay on `AdvertisementData` (Work Item 7 confirmed, no convenience accessor)

Considered, then rejected, adding `serviceUUIDs` (or an `advertisedServiceUUIDs` convenience) onto `Peripheral`. Rationale: advertised service UUIDs are a pre-connection *hint* from the advertisement packet and are distinct from `CBPeripheral.services` (the post-connection GATT catalog). Keeping them on `advertisement` (alongside `overflowServiceUUIDs`/`solicitedServiceUUIDs`) leaves `Peripheral.services` free to mean the real connected GATT catalog in a future connection-lifecycle step.

### 4. `SendableWrapper` retained (not removed in Step 2)

The plan's Background implied the `SendableWrapper` hop might go away once `Peripheral` is a value type. It was **kept**: the raw `CBPeripheral` and `[String: Any]` advertisement dictionary delivered by the delegate are still non-`Sendable` and must cross the delegate-queue → actor hop before extraction into `Peripheral`/`AdvertisementData` *inside* the actor. The doc comments were updated to reflect this.

**Why the Step 1 expectation was wrong.** The Step 1 plan (and the original `SendableWrapper` TODO comments) assumed the wrapper existed to ferry the non-`Sendable` `Peripheral` *class*, so making `Peripheral` a value type would remove it. That was a misattribution: the wrapper never carried a `Peripheral` — it carries the raw `CBPeripheral` and `[String: Any]` advertisement dictionary delivered on CoreBluetooth's nonisolated delegate queue. Those framework types stay non-`Sendable`, the architecture deliberately defers extraction into value types until *inside* the actor, and Step 2's new actor-owned `cbPeripherals: [String: CBPeripheral]` registry actually *requires* the live reference to reach the actor. So the hop survives regardless of `Peripheral`'s Sendability. An oracle review confirmed this and validated keeping the hop (do **not** extract in the shim or pass only a `UUID` — that would violate the invariant and trade a live reference for a racy `retrievePeripherals(withIdentifiers:)` lookup).

### 5. `CBUUID: @retroactive @unchecked Sendable` — no mock-target collision

The Open Question risk (redundant-conformance error if `CoreBluetoothMock` already declares `CBMUUID: Sendable`) did **not** materialize. Both `ReliaBLE` and `ReliaBLEMock` compile the shared extension cleanly; no per-target guard was needed.

### 6. `connect(id:)` guards a missing central manager

In addition to the `PeripheralError.notFound` registry-lookup throw, `connect(id:)` guards `centralManager == nil` with a log-and-no-op, matching the existing `startScanning`/`stopScanning` convention. In practice unreachable (the registry is only populated while a central manager exists), but it prevents the API from silently reporting success with nothing to act on.

### 7. Tests

Shipped as planned: a `Task.detached`-capture `Sendable` proof (`peripheralIsSendable`) and a stale-snapshot `connect` test (`connectToUnknownPeripheralThrowsNotFound`, asserting `PeripheralError.self`). Both use the new `public init(id:)`. A broader actor/registry test harness (driving the mock central to emit discoveries) was noted as a possible follow-up, out of scope here.

### 8. `SendableWrapper<T>` → `DiscoveryPayload`: keep the unchecked scope small (post-merge refinement, 2026-06-19)

The same oracle review from item #4 recommended narrowing the unchecked assertion. The generic `private struct SendableWrapper<T>: @unchecked Sendable` was replaced with a single-purpose `private struct DiscoveryPayload: @unchecked Sendable { let peripheral: CBPeripheral; let advertisementData: [String: Any]; let rssi: Int }` in `BluetoothActor.swift`. The shim now ferries one `DiscoveryPayload` across the hop instead of two generic wrappers.

- **Decision — keep the solution scope small.** A generic `@unchecked Sendable` wrapper reads as a reusable escape hatch: it invites future call sites to bypass concurrency checking for *any* type, which muddies the waters over time and erodes the value of complete concurrency checking. The real invariant is narrow — "this one discovery payload is safe to ferry once into the actor." A single-purpose type names exactly that boundary, makes the unchecked assertion self-documenting, and keeps the unsafe surface confined to the one hop that genuinely needs it rather than normalizing a general-purpose unchecked tool.
- **No behavior change:** still a `@unchecked Sendable` ferry of the raw, read-once CoreBluetooth payload; extraction into `Peripheral`/`AdvertisementData` still happens inside the actor. Builds clean under `ReliaBLE` and `ReliaBLEMock`.
- **Not a Step 3 obligation:** the oracle confirmed AsyncStream cleanup (Step 3) removes the Combine `nonisolated(unsafe)` bridging, but does not inherently solve the non-`Sendable` CoreBluetooth payload hop. A future switch to `sending` parameters would be a targeted, compiler-verified refactor rather than a required goal.
