# Phase 1: Public Type Model — `Peripheral` Handle + `DiscoveredPeripheral`: Plan

Tracking: [#50](https://github.com/Five3Apps/ReliaBLE/issues/50) (parent) → [#53](https://github.com/Five3Apps/ReliaBLE/issues/53), [#54](https://github.com/Five3Apps/ReliaBLE/issues/54), [#55](https://github.com/Five3Apps/ReliaBLE/issues/55), [#56](https://github.com/Five3Apps/ReliaBLE/issues/56)

## Goal

Split today's single public `Peripheral` value type into two: `DiscoveredPeripheral` (Sendable scan snapshot) and `Peripheral` (long-lived, per-manager interned control handle that owns connect/disconnect). Deliver the PRD's handle-centric public API without ever exposing live CoreBluetooth objects, and decide whether sub-issues #53–#56 ship as one branch/PR or four.

## Out of scope

Work-driven auto-connect, idle teardown, and Approach B queue gating (#51); FR-10 GATT discovery / readiness / subscriptions (#52); PoweredOn await gating (#57); FR-4/5 commands.

**#57 deserves an explicit note** because `Peripheral.connect()` is a new public entry point and reviewers will ask: it does **not** await PoweredOn. It preserves today's contract exactly — ensure the central, then throw `.bluetoothUnavailable` if the central is missing or `.notFound` if no live reference exists (`BluetoothActor.swift:1031-1050`). FR-1.4 / FR-8.6 gating arrives with #57.

## Background

### Current public types (`Sources/ReliaBLE/Models/`)

- `Peripheral.swift` — `public struct Peripheral: Sendable, Identifiable, Hashable` (`:42`). All-`let` stored properties: `id: String`, `cbIdentifier: UUID?`, `name: String?`, `rssi: Int?`, `lastSeen: Date?`, `advertisement: AdvertisementData?`. `public init(id: String)` (`:78`, app-constructed known-id, all other fields nil) plus an internal full init (`:91`). `hash(into:)` (`:107-109`) and `==` (`:111-115`) key on `id` **only**. Holds no `CBPeripheral`; the doc comment already states the live object is actor-owned and looked up by id. **Option A metadata already lives on this type.**
- `Events/PeripheralDiscoveryEvent.swift` — `public let id: UUID` (from `cbPeripheral.identifier`, **not** the app-facing `Peripheral.id` String), `name`, `rssi: Int`, `advertisement: AdvertisementData`; internal `init(cbPeripheral:advertisement:rssi:)`.
- `AdvertisementData.swift` — `Sendable, Hashable`; `localName`, `serviceUUIDs: [CBUUID]`, `manufacturerData`, `txPowerLevel`, `isConnectable`, `serviceData`, `overflowServiceUUIDs`, `solicitedServiceUUIDs`. Internal `init(rawAdvertisementData:)` extracts from the CB dict exactly once.
- `ConnectionState.swift` — `ConnectionState` enum (`.connecting`, `.reconnecting(source:attempt:nextRetryAt:)`, `.connected`, `.disconnecting`, `.disconnected(reason:)`, `.failed(reason:)`), `ReconnectSource { system, library }`, and `ConnectionStateChange { peripheralId: String, state: ConnectionState }` — **keyed by String id, not by handle**.
- `PeripheralError.swift` — `.notFound`, `.bluetoothUnavailable`, `.connectionFailed`, `.connectionTimeout`, `.peripheralDisconnected`, `.unknown`, plus `fromCBError(_:)`.

### Discovery pipeline (`Sources/ReliaBLE/BluetoothActor.swift`)

- Actor-isolated storage: `var discoveredPeripherals: [Peripheral]` (`:180`, value snapshots), `private var cbPeripherals: [String: CBPeripheral]` (`:186`, live refs keyed by the same String id, never escapes), `var connectionStates: [String: ConnectionState]` (`:201`).
- Flow: CB delegate shims (`:1486`, `:1540`) → `DelegateEventForwarder` (ordered `AsyncStream`) → `process` → `handlePeripheralDiscovered` (`:876`).
- `handlePeripheralDiscovered` builds `AdvertisementData` once, broadcasts `PeripheralDiscoveryEvent`, then derives `identifier = cbPeripheral.name ?? advertisement.localName ?? cbPeripheral.identifier.uuidString`, resolves against the existing list (match `id`, else `cbIdentifier`, else append), updates `discoveredPeripherals`, sets `cbPeripherals[resolvedId]`, and broadcasts the updated `[Peripheral]`.
- `handleWillRestoreState` (`:709-807`) duplicates the id-resolution logic to re-bind restored `CBPeripheral`s, but **not identically** — it preserves prior `rssi` (`:742`), falls back to the prior `advertisement` (`:744`, `:754`), and coalesces `name ?? existing` in the `cbIdentifier`-match branch (`:751`) where discovery (`:930`) overwrites. It broadcasts **once** after the loop, guarded by `didMutatePeripherals` (`:722`, `:771`, `:804`). Restored peripherals are deliberately **not** emitted on the `peripheralDiscoveries` ad feed.
- A **third** live-reference binding site exists: `refreshPeripherals()` (`:999-1016`) re-binds `cbPeripherals[p.id]` from `retrievePeripherals(withIdentifiers:)` after a power cycle and broadcasts the list. It resolves no new ids and changes no metadata.
- `shutdown()` clears `cbPeripherals`, `discoveredPeripherals`, `connectionStates`, `reconnectEnabled`, and `intentionalDisconnects` (`:255-261`). `invalidatePeripherals()` (`:956-968`) clears only the live map and connection state.
- Reverse lookup `id(for:)` (~:1099) uses `===` over `cbPeripherals`.
- Identity is name-first and best-effort; FR-8.5 (manufacturer-data unique id) is an open TODO noted in the actor and will later change interning/matching.

### Public API surface (`Sources/ReliaBLE/ReliaBLEManager.swift`)

`public final class ReliaBLEManager: Sendable`, with `let bluetooth: BluetoothActor` already **internal** (`:46`) and a fire-and-forget `Task { await bluetooth.ensureCentralManager() }` in `init`. Today: `loggingService`; `state: AsyncStream<BluetoothState>` (replays); `currentState`; `connectionStateChanges: AsyncStream<ConnectionStateChange>` (no replay); `currentConnectionStates: [String: ConnectionState]`; `peripheralDiscoveries: AsyncStream<PeripheralDiscoveryEvent>`; `discoveredPeripherals: AsyncStream<[Peripheral]>` (replays); `authorizeBluetooth()`; `startScanning(services:)`; `stopScanning()`; `connect(to:autoReconnect:)`; `disconnect(from:)`. Streams are `nonisolated` factories that schedule registration on the actor; operational methods are `async` and forward `peripheral.id` to the actor after `ensureCentralManager()`. No `peripheral(id:)`, no `.peripheral` sugar, connect is still manager-primary.

### Prior decisions already settled (do not re-litigate)

From `docs/designs/discovered-peripheral-vs-peripheral-2026-07-15.md` and PRD Architecture "Public types" / FR-2.1 / FR-2.4 / FR-2.5 / FR-8.2.1 / NFR-1.3:

- Split is chosen; snapshot-only and grow-one-type options were rejected. Control type is named `Peripheral`, snapshot is `DiscoveredPeripheral`. `Device` is rejected (reserved for app multi-transport types).
- **One handle per id per manager.** `manager.peripheral(id:)` creates or returns the interned handle; `discovered.peripheral` is sugar over a manager stamp + registry lookup, "multi-manager safe because the stamp identifies the registry". (D7 keeps the multi-manager guarantee but satisfies it by carrying the registry itself rather than a separate stamp object.)
- **Option A** = last-discovery metadata (`lastSeen`, `rssi`, optional last advertisement) lives on the handle so "my devices" UI binds a single object. Option B (a later thin `PeripheralUpdate { peripheral, discovery }` stream) is explicitly deferred, and is "not a third control type".
- UI rules: "My devices" comes from tracked handles + Option A metadata; "Nearby" comes from the real `DiscoveredPeripheral` stream only. **Never vend synthetic `DiscoveredPeripheral` rows for offline bound devices.**
- Connect/disconnect belong on `Peripheral` (`connect(autoReconnect:)`, `disconnect()`); manager-level `connect(to:)` as the primary app API is an explicit refactor target (FR-2.5: "a temporary milestone to be refactored away").
- NFR-1.3: all CoreBluetooth objects stay in one internal isolation domain; public handles forward by id. **No per-peripheral actors owning `CBPeripheral`.**
- NFR-1.2 leaves `Peripheral` as "class or id-façade — implementation choice".

From `docs/designs/bluetoothactor-instance-isolation-2026-07-19.md`: one stack per manager; each manager owns its actor, central, snapshots, connection state, and streams. Two managers scanning the same device each hold their own snapshots and live-reference map — there is no cross-manager discovered list. The registry must therefore be per-manager, never global.

From `docs/plans/background-scanning-state-restoration-2026-07-13.md`: `handleWillRestoreState` re-binds restored `CBPeripheral`s using the same identity logic as discovery, seeds connection state, and re-arms persisted reconnect intent. Whatever the registry becomes, restoration must intern the same handles.

### Blast radius

- **Tests** (`Tests/ReliaBLETests/ReliaBLEManagerTests.swift`, single file): swift-testing (`@Suite(.serialized)`, `@Test`, `#expect`, `#require`), `@preconcurrency import CoreBluetoothMock` + `@testable import ReliaBLEMock`, `CBMCentralManagerMock.simulate*` driven through a one-time `SimulationConfig` actor. `Tests/ReliaBLETests/Mocks/` is effectively empty — all fixtures are inline (~:2170+: `makeTestPeripheralSpec`, `connectionTestSpec`, `waitForPeripheral(...) -> Peripheral?`, `pollUntil`, `firstEvent`, `drain*`). Deterministic ids: `Mock.testPeripheralID = "ReliaBLE-Test-Peripheral"` (`:1964`) and `connectionTestPeripheralID` (`:1969`). Two simultaneous managers are supported via `makeManager(tearDownPrevious: false)` (`:2072`+, used at `:1808`), and restore is directly drivable through `bluetooth.testHandleWillRestoreState` (`:1628`, `:1679`, `:1704`, `:1745`).
- **`connect(to:)` / `disconnect(from:)` occupy exactly 36 lines**: `:70`, `:445`, `:457`, `:585`, `:614`, `:620`, `:661`, `:694`, `:738`, `:770`, `:804`, `:853`, `:878`, `:885`, `:935`, `:957`, `:990`, `:1015`, `:1043`, `:1070`, `:1104`, `:1125`, `:1163`, `:1213`, `:1228`, `:1251`, `:1284`, `:1332`, `:1377`, `:1455`, `:1550`, `:1596`, `:1655`, `:1808`. Other clusters: `:64-:126` (Sendable/equality proofs), `:320-:349` (discovery assertions), `:432-:466` (stale-snapshot connect).
- **Demo** (~10–12 library-type sites): `Central/DeviceStoreActor.swift:55` (`PeripheralDiscoveryEvent` param), `:68` (`syncDevices(_ peripherals: [Peripheral])`), `:73-78`; `Central/CentralView.swift:183/188/193` (stream subscriptions), `:282` (`disconnect(from: Peripheral(id: device.id))`), `:286` (`connect(to: Peripheral(id: device.id), ...)`). `CentralViewModel.swift` uses String ids + `ConnectionStateChange` only. The Demo's own `Device`/`DiscoveryEvent` types are unaffected in name.
- **DocC** (~50 sites, all stale on rename): `Documentation.md:18,22,35,42,69,71`; `GettingStarted.md:129-130,134,137-139,144,148,158,161,172,200+`; `Topics/Background.md:73,79-80,87,95+`; `Topics/Concurrency.md:88,90,100-101`; `Topics/Multi-Manager.md:19,45-46`. CI runs `generate-documentation --warnings-as-errors`, so stale symbol links fail the build.
- **`Sources/ReliaBLEMock/CoreBluetoothMockAliases.swift`**: zero impact (only `CB*` → `CBM*` rebindings).

### Repo workflow conventions

- Default branch `master` (clean, tracking `origin/master`). Branch naming is `<issue-number>-<slug>` (`65-bluetoothactor-instance-isolation`, `38-background-scanning`, `37-auto-reconnect`).
- Merge commits, **not** squash: `Merge pull request #NN from owner/<branch>`.
- **One issue per PR ("Closes #NN"), with related sub-work bundled inside as sequential green checkpoints.** Recent feature PRs: #66 (15 files, 14 commits, "Each commit is an independently green checkpoint"), #44 (14 files, 4 commits), #41 (15 files, 5 commits), #39 (10 files, 4 commits). PR bodies follow a loose template: Closes/refs, plan or design doc link, What changed, Verification, Notes.
- CI (`.github/workflows/ci.yml`): on every PR and on push to `master`; macos-15 / Xcode 16.4; `build-test` job = `swift build` + `swift test` (library + ReliaBLETests only, no Demo, no matrix); `docc` job = `generate-documentation --warnings-as-errors`; `deploy-docs` only on master push. No lint job.

## Delivery strategy: one branch, one PR

**Branch `50-peripheral-handle-type-model` → one PR (`Closes #50`, body referencing #53–#56 as delivered checkpoints).** Not four PRs.

The four sub-issues are totally coupled at the type level. #53 alone renames today's `Peripheral` snapshot without a replacement handle type, which leaves `BluetoothActor`, `ReliaBLEManager`, the entire test file, and every DocC symbol link non-compiling — there is no green intermediate state where the snapshot exists but the handle does not. #55's `.peripheral` sugar is meaningless without #54's registry, and #54's registry is unobservable without #56's handle-side connect. Splitting would require throwaway shim APIs on each of three PRs.

This matches observed repo convention: one issue per PR with related sub-work bundled as sequential green checkpoints inside (PR #66 = 15 files / 14 commits, "Each commit is an independently green checkpoint"; #44 = 14 files / 4 commits; #41 = 15 files / 5 commits). Sub-issues #53–#56 stay as tracking/checkpoint markers and are closed manually when #50's PR merges.

## Approach

Replace the single public value type `Peripheral` (immutable discovery snapshot serving as both list row and connect argument) with two types:

- **`DiscoveredPeripheral`** — Sendable scan snapshot, carrying a reference to its vending manager's handle registry (PRD FR-2.4.3).
- **`Peripheral`** — long-lived, per-manager-interned `final class` control handle.

Handle instances are interned in a **manager-owned** `PeripheralHandleRegistry`, not on the actor, so `manager.peripheral(id:)` can be synchronous and usable before any `CBCentralManager` exists. The actor keeps owning `cbPeripherals`, `connectionStates`, and the discovered snapshot list, and pushes metadata into handles through an injected `PeripheralRegistryBridge`. Handles are thin id façades: they forward connect/disconnect by id and expose **synchronous, lock-protected cached** last-discovery metadata for SwiftUI. `discoveredPeripherals` becomes `AsyncStream<[DiscoveredPeripheral]>`; `peripheralDiscoveries` keeps `PeripheralDiscoveryEvent` as the per-advertisement feed. Manager-level connect/disconnect are **removed** outright. Discovery and restoration share one id-resolution helper so the same handle instance is always returned for a given id on a given manager.

### What blocks the PRD shape today

- An immutable snapshot struct cannot own a sticky discovery filter, a command queue, a manual-connect hold, or stable reference identity for a "my devices" list.
- Manager-primary `connect(to:)` teaches the wrong API (FR-2.5 calls it a temporary milestone).
- There is no registry, so known-id-before-scan (`Peripheral(id:)` today) produces an orphan value that can only fail.
- `DiscoveredPeripheral` and the `.peripheral` sugar don't exist.
- Id-resolution logic is duplicated between `handlePeripheralDiscovered` and `handleWillRestoreState`; adding a registry to both sites without factoring it first guarantees divergence.

### What is reused unchanged

`AdvertisementData`, `ConnectionState` / `ReconnectSource` / `ConnectionStateChange`, `PeripheralError`, the stream-broadcaster pattern, the actor's `connect(id:)` / `disconnect(id:)` methods, the reconnect ladder, restore-intent persistence in `UserDefaults`, the three-target SPM mocking trick, and `forceMock: true` in the factory call.

## Design decisions

### D0 — Declare all five Apple platforms, pinned to the `Synchronization.Mutex` floor

`Package.swift:8-9` currently declares only `.iOS(.v18)` and `.macOS(.v10_15)`. The macOS value is leftover, not a real support target. Replace the whole block with explicit support for every Apple platform, each pinned to the lowest version that ships `Synchronization`:

```swift
platforms: [
    .iOS(.v18),
    .macOS(.v15),
    .tvOS(.v18),
    .watchOS(.v11),
    .visionOS(.v2)
],
```

These are the exact floors, read from the SDK rather than from memory — `Synchronization.swiftinterface` annotates `Mutex` as:

```
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
@frozen @_staticExclusiveOnly public struct Mutex<Value> : ~Copyable where Value : ~Copyable
```

Declaring platforms explicitly is what makes this safe. Previously, a consumer building for tvOS/watchOS/visionOS would inherit the SPM *default* floor for those platforms and fail on `import Synchronization`; pinning each one to its `Mutex` floor removes that failure mode instead of documenting around it.

This is load-bearing for D1: with these floors, `Mutex` is available unconditionally — no `@available` annotations, no shimmed fallback — so every new type in this phase can be a **checked** `Sendable` rather than `@unchecked`.

**Verified, not assumed** (against the Xcode 26.5 SDKs):

| Platform | Check | Result |
|----------|-------|--------|
| watchOS 11 | `xcodebuild -scheme ReliaBLE -destination generic/platform=watchOS` on a scratch copy with the new platform block | `** BUILD SUCCEEDED **` |
| tvOS 18 | `swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-tvos18.0 -typecheck` over all of `Sources/ReliaBLE` (Willow built from source for the same triple) | clean |
| visionOS 2 | same, `-target arm64-apple-xros2.0` | clean |
| all five | `Mutex<State>` + `weak var` + checked `Sendable` typechecked per-triple | clean on iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2 |

tvOS and visionOS could not be driven through `xcodebuild` on this machine — their SDKs are present but the platform *runtime components* are not installed, so no destination resolves. The direct `swiftc` typecheck against each SDK is the equivalent compile-level evidence; a full link on those two platforms is still unproven and should be confirmed in CI (see below).

**Why this is safe for a central-role library.** CoreBluetooth's only `API_UNAVAILABLE(watchos, tvos)` symbols are peripheral-role: `CBPeripheralManager`'s initializers and the designated initializers on `CBMutableService` / `CBMutableCharacteristic` / `CBMutableDescriptor`. ReliaBLE uses none of them — a grep across `Sources/` for `CBPeripheralManager|CBMutable*|CBATTRequest` returns only a doc-comment mention in `CoreBluetoothMockAliases.swift:153`. `CBCentralManager`, `CBCentralManagerOptionRestoreIdentifierKey` (`NS_AVAILABLE(10_13, 7_0)`), and `centralManager:willRestoreState:` carry no platform exclusions.

**Dependency floors are not a blocker:** CoreBluetoothMock declares macOS 10.14 / iOS 12 / watchOS 4 / tvOS 12 and Willow declares macOS 10.12 / iOS 10 / tvOS 10 / watchOS 3 — all below ours, and neither declares visionOS, so SPM applies its default floor rather than a conflicting one. Note both are `ReliaBLEMock`/test-target dependencies; the production `ReliaBLE` target depends only on Willow.

**Runtime caveat to document, not a compile issue.** Background scanning and state restoration — this library's headline feature — are constrained on tvOS and watchOS: tvOS has no `bluetooth-central` background mode, and watchOS background BLE is limited. The API compiles and the central role works; `restoreIdentifier` will simply not deliver the same background behavior there. State this in `Topics/Background.md` rather than silently implying parity.

**CI consequence.** `.github/workflows/ci.yml` builds and tests on macOS only, so these four extra platform declarations are unverified by CI as written. Add a compile-only matrix leg (`xcodebuild -scheme ReliaBLE -destination 'generic/platform=<p>'` for iOS/tvOS/watchOS/visionOS) so a future change cannot silently break a declared platform. Tests stay macOS-only — they need the CoreBluetoothMock harness, not real radios.

### D1 — `Peripheral` is a `final class`, not an id-façade struct

`public final class Peripheral: Sendable, Identifiable, Hashable`

One interned instance per id per manager gives reference identity (`===`) for SwiftUI and makes `discovered.peripheral` return *the same object* rather than an equal copy. Option A metadata mutates in place without replacing the object, and the future FR-10 sticky filter / queue / readiness state attaches to the same instance. A struct façade would need an external registry of boxes anyway to deliver "same object" semantics, so it buys nothing.

**Sendable contract — checked, via `Mutex`.** All mutable state lives in a single `Mutex`-wrapped value; every other stored property is a `let`. The compiler verifies `Sendable` conformance; nothing is asserted by hand.

```swift
import Synchronization

public final class Peripheral: Sendable, Identifiable, Hashable {
    struct State {
        weak var manager: ReliaBLEManager?
        var cbIdentifier: UUID?
        var name: String?
        var rssi: Int?
        var lastSeen: Date?
        var advertisement: AdvertisementData?
    }

    public let id: String
    private let state: Mutex<State>
}
```

A `weak var` inside a `Mutex`-guarded struct is legal and keeps the whole type checked-`Sendable` — this is the pattern to use anywhere a weak manager reference is needed. **Compile-verified** under `-swift-version 6 -strict-concurrency=complete` at `-target arm64-apple-macos15.0`, including a registry whose `withLock` closure creates, inserts, and returns a handle, and a `Task.detached` capturing both types.

Three rules that govern any future field added to `State`:

1. **`Mutex` is unconditionally `Sendable`** (SE-0433 achieves safety via `sending` on `init`/`withLock`, not by requiring `Value: Sendable`). The real constraint is on what **escapes**: `withLock` returns `sending Result`, so only `Sendable` or provably-isolated values may be returned. Every Option A field qualifies (`String`, `Int`, `Date`, `UUID`, `AdvertisementData`), as does `ReliaBLEManager`.
2. **`weak` is sound here for a specific reason:** all reads and writes of the weak reference happen under the mutex, and the runtime's weak load/zeroing is itself atomic with respect to deallocation. A bare `weak var` on an `@unchecked Sendable` class would *not* be sound — that is precisely why this design boxes it.
3. **Platform floor mechanics.** `Synchronization` needs macOS 15 / iOS 18 / tvOS 18 / watchOS 11 / visionOS 2 at runtime; CI's `macos-15` runner satisfies it and D0 removes any need for `@available`. D0 declares all five platforms at exactly those floors, so no consumer inherits an SPM default floor that would fail on `import Synchronization`. One consequence to accept explicitly: contributors on macOS 14 can no longer build or test the library locally.

- `id` is an immutable `let`.
- No `CBPeripheral` is ever stored on the handle.
- Writes happen only via an internal `applyMetadata(...)` called from the actor's discovery/restore paths, so ordering is already actor-serialized.
- The manager reference is **weak, not `unowned`**. Handles can legitimately outlive the manager (the app holds one after dropping the manager); `unowned` would crash. Connect/disconnect on an orphaned handle throw `PeripheralError.bluetoothUnavailable`.

**Equality/hash key on `id` only**, matching today (`Peripheral.swift:107-109` and `:111-115`) and the String-keyed `connectionStates` / `ConnectionStateChange.peripheralId` maps. `ObjectIdentifier`-based hashing would also work given one instance per id, but id-based keeps existing tests and connection-state correlation natural. Document the consequence: two handles from *different* managers with the same id compare `==` but are different objects on different registries; multi-manager apps must not mix them, and `===` plus the manager stamp distinguish them.

### D2 — Option A metadata: synchronous cached properties on the handle

```swift
public let id: String
public var cbIdentifier: UUID? { get }
public var name: String? { get }
public var rssi: Int? { get }
public var lastSeen: Date? { get }
public var advertisement: AdvertisementData? { get }
```

No public setters. Values update only through the internal `applyMetadata(...)` path.

Each getter takes the `Mutex` for a single field read. **Reads of different properties are not one atomic snapshot** — a row reading `name`, then `rssi`, then `lastSeen` can straddle two discovery updates. This is benign for UI but is a public contract: document it, and prefer storing one immutable metadata struct in the `Mutex` so a caller who needs consistency can be offered a single-`withLock` accessor later.

**Why sync, not async accessors:** SwiftUI `ForEach` row bodies need synchronous reads. Async accessors force a `.task` per row and produce visible flicker on every list update — unacceptable for the "my devices" screen that Option A exists to serve. A metadata-free control handle was also considered and rejected: it would leave offline known devices with no metadata at all, which is exactly the "my devices UI binds a single object" case Option A exists for.

These are explicitly **last-known** values, not live CB state. After `invalidatePeripherals`/shutdown clears `cbPeripherals`, metadata remains at its last-known value while `connect()` throws `.notFound` until rediscovery rebinds a live reference. Document that contract.

**Change notification — the missing half.** `Peripheral` is a plain `Sendable` class: not `@Observable`, no `objectWillChange`, and both a metadata-change stream and design Option B (`PeripheralUpdate { peripheral, discovery }`) stay deferred. SwiftUI therefore gets **no signal** that handle metadata changed. The "Nearby" screen re-renders because `discoveredPeripherals` vends fresh *value* snapshots; the "my devices" screen — the entire justification for Option A — would be handed a mutable reference with no invalidation channel and would render once, then go stale.

**Resolution, zero API cost:** document that `discoveredPeripherals` doubles as the "something changed" tick. It fires on every advertisement, so an app re-reads handle metadata inside that loop. This must appear in D2 *and* in the `GettingStarted.md` DocC checklist item — shipping docs that say "bind your my-devices list to handle metadata" without it would teach a pattern that visibly does not update. A real notification mechanism stays deferred to Option B.

This is now a PRD requirement rather than a plan-local note: **FR-2.4.5.3** mandates the change-notification affordance, names this interim contract, and explicitly forbids documentation that implies the view self-updates. **FR-2.4.5.1** requires the metadata to be readable without awaiting the isolation domain, which is what makes the sync accessors in this decision a requirement rather than a preference.

### D3 — Manager connect/disconnect are removed, not deprecated

Delete `ReliaBLEManager.connect(to:autoReconnect:)` and `ReliaBLEManager.disconnect(from:)` outright. No `@available(*, deprecated)` shim — AGENTS.md says this is pre-release and breaking changes are expected, so a deprecation tier would only preserve the wrong teaching surface.

```swift
// on Peripheral
public func connect(autoReconnect: Bool = true) async throws
public func disconnect() async throws
```

Each resolves `manager` (throwing `.bluetoothUnavailable` if nil), then calls `await manager.bluetooth.ensureCentralManager()` followed by `try await manager.bluetooth.connect(id: id, autoReconnect:)` — the exact sequence `connect(to:)` performs today at `ReliaBLEManager.swift:189`.

No access-level change and no new helper is required: `bluetooth` is **already** `internal let` (`ReliaBLEManager.swift:46`) and the handle is in the same module. Add an `ensureCentralManagerReady()` wrapper only if a single named seam for handle entry is wanted for its own sake — not to "avoid widening access," which is not a real constraint here.

### D4 — `discoveredPeripherals` vends `[DiscoveredPeripheral]`

`public var discoveredPeripherals: AsyncStream<[DiscoveredPeripheral]>` — real scan snapshots only, replayed as today.

Offline known-id handles never appear here; that is the design doc's "don't fake discoveries" rule. Restored peripherals still appear (the restore path already upserts into this list) with empty advertisement and nil rssi, exactly as today, and are still deliberately absent from the `peripheralDiscoveries` ad feed.

**No `trackedPeripherals` stream in this phase.** Apps obtain handles from `peripheral(id:)` or `discovered.peripheral`; a tracked feed is design Option B and stays deferred. **PRD FR-2.4.5.2** now states this explicitly — a dedicated tracked feed is not required, and composing the view from those two entry points is what keeps offline devices representable without fake discoveries.

### D5 — Both discovery feeds survive

| Feed | Element | Replay | Role |
|------|---------|--------|------|
| `peripheralDiscoveries` | `PeripheralDiscoveryEvent` | No | Every advertisement (CB `UUID` id, rssi, ad) |
| `discoveredPeripherals` | `[DiscoveredPeripheral]` | Yes (latest list) | Deduped nearby list |

Do not merge them: the event's `id` is the CoreBluetooth `UUID` while the app-facing id is a `String`, and the high-rate ad path should stay small. The Demo continues to consume `insertDiscovery(PeripheralDiscoveryEvent)`.

`PeripheralDiscoveryEvent`'s fields stay **unchanged** this phase. Adding a `peripheralId: String?` correlation field was considered and **deferred to FR-8.5**, not merely dropped for blast radius: FR-8.5 introduces manufacturer-data-based unique identity, which is what determines how an advertisement maps to an app-facing id in the first place. Adding a correlation field now would bake in today's name-derived resolution (`name ?? localName ?? uuidString`) and then have to change again when FR-8.5 lands.

This deferral is now recorded in the PRD as **FR-8.5.4**, so FR-8.5 cannot be implemented without settling it.

Add a doc comment clarifying that `id` is the CoreBluetooth identifier, not the app-facing peripheral id — a contract now required by **PRD FR-8.1.4**. Until FR-8.5, correlate via `DiscoveredPeripheral` or the handle.

### D6 — `peripheral(id:)` is synchronous and nonisolated; the registry is manager-owned

```swift
public func peripheral(id: String) -> Peripheral
```

This must work before `ensureCentralManager()` — it is the known-id-before-scan entry point — and it must be synchronous so SwiftUI can call it inline. That rules out interning on the actor, which would force `async`.

**Resolution: split ownership.**

- `PeripheralHandleRegistry` — a `final class`, checked `Sendable`, holding `Mutex<Storage>` where `Storage` carries `[String: Peripheral]` plus a `weak var manager`. Created in `ReliaBLEManager.init` and owned by the manager. `peripheral(id:)` takes the lock, returns the existing handle or creates, inserts, and returns a new one with empty metadata. No actor hop.
- `BluetoothActor` does **not** own handle instances. It continues to own `cbPeripherals`, `connectionStates`, and the discovered snapshot list.

**Construction order — the naive wiring does not compile.** `PeripheralHandleRegistry(manager: self)` cannot appear in `ReliaBLEManager.init` before `bluetooth` is assigned: `self` is unusable in a class initializer until every stored property is initialized, so `registry` (needing `self`) cannot precede `bluetooth` (needing `registry`). Verified — `error: 'self' used before all stored properties are initialized`. Note this diagnostic is a SIL pass, so `-typecheck` alone reports nothing; it surfaces on a real build.

Use a two-phase attach:

```swift
public init(config: ReliaBLEConfig = ReliaBLEConfig()) {
    loggingService = LoggingService(...)
    handleRegistry = PeripheralHandleRegistry()          // no manager yet
    bluetooth = BluetoothActor(log: ..., reconnectPolicy: ..., restoreIdentifier: ...,
                               registry: handleRegistry)
    handleRegistry.attach(manager: self)                 // legal: all stored props initialized
    Task { await bluetooth.ensureCentralManager() }
}
```

Consequence to state rather than leave implicit: handles capture their `weak manager` **at creation, from the registry's stored reference**, so nothing may call `peripheral(id:)` before `attach`. Nothing does today — but the registry should assert it in debug builds.

(The alternative — passing `manager:` per call to `registry.peripheral(id:manager:)` — avoids `attach` entirely, but then `DiscoveredPeripheral` cannot resolve `.peripheral` from a registry reference alone, which reintroduces the `ManagerStamp` that D7 deletes. The two-phase attach is the cheaper trade.)

**Bridging actor → registry.** The actor has no manager reference today. Two alternatives were rejected: having the manager observe its own discovered stream and sync handles (racy, and ordering is not guaranteed relative to connect), and having the actor own an id/metadata registry while the manager owns the class instances (splits one concept across two owners and re-creates the divergence hazard). Instead, inject a bridge at actor init:

```swift
/// Invoked only from BluetoothActor's executor. Create-or-update: interns the handle
/// if absent, then applies metadata.
protocol PeripheralRegistryBridge: Sendable {
    func applyDiscovery(
        id: String,
        cbIdentifier: UUID?,
        name: String?,
        rssi: Int?,
        lastSeen: Date?,
        advertisement: AdvertisementData?
    )
    func applyConnectionState(id: String, state: ConnectionState)
}
```

**One discovery method, not two.** A separate `ensureHandle(id:)` was considered and rejected: it is always called immediately before `applyDiscovery`, which must intern anyway, so it only doubles lock acquisitions on the library's hottest path (one call per advertisement per device — the mock alone advertises every 50 ms across two peripherals, `ReliaBLEManagerTests.swift:2138`, `:2156`).

**`PeripheralHandleRegistry` conforms to this protocol directly** — no separate adapter object. The protocol exists for the actor's dependency inversion and testability; a second type would add nothing and would create another place to accidentally capture the manager strongly.

`BluetoothActor.init` gains a `registry: PeripheralRegistryBridge` parameter alongside `log:reconnectPolicy:restoreIdentifier:`. Connect still resolves `cbPeripherals[id]` on the actor — a handle is never needed for CB lookup.

**Known-id matching semantics are unchanged from today.** If the app calls `peripheral(id: "MyBand")` and a device advertises name `MyBand`, the resolved id is `MyBand` and the live reference binds to the existing handle. If the advertised name differs, no bind occurs — the same limitation `Peripheral(id:)` has today, tracked by FR-8.5 (manufacturer-data unique id).

### D7 — `DiscoveredPeripheral` holds the registry; the `.peripheral` sugar

`DiscoveredPeripheral` must stay a `Sendable` struct while being able to reach its vending manager's registry. A dedicated `ManagerStamp` box was considered and **rejected** — the snapshot should simply hold the registry, which is already per-manager, already `Sendable`, and is the very thing being looked up:

```swift
public struct DiscoveredPeripheral: Sendable, Identifiable, Hashable {
    // …public lets…
    let registry: PeripheralHandleRegistry     // internal; excluded from ==/hash
    public var peripheral: Peripheral { registry.peripheral(id: id) }
}
```

This is better on four counts:

1. Deletes a type and one of the design's weak references.
2. Removes an injection dependency — the actor already receives the registry, so nothing extra needs passing to `BluetoothActor.init`.
3. **Preserves the interning invariant after manager death.** With a stamp, `.peripheral` on a snapshot whose manager was freed would return a *fresh* orphan on every call, making `snap.peripheral === snap.peripheral` false — quietly violating this phase's headline guarantee in exactly the state that is hardest to debug. Holding the registry keeps interning alive; the handle's own weak manager is nil, so `connect()` still throws `.bluetoothUnavailable`. Same documented behavior, no second identity rule.
4. Retain graph stays acyclic: manager → registry (strong), registry → handles (strong), handle → manager (weak), snapshot → registry (strong). A retained snapshot outliving its manager keeps the registry alive — which is exactly what makes point 3 work.

`==`/`hash` on `id` only, consistent with the handle; `registry` is excluded.

### D8 — Registry shape

```
ReliaBLEManager
  ├── PeripheralHandleRegistry            ← owns handle instances; conforms to
  │     Mutex<Storage>                        PeripheralRegistryBridge directly
  │       ├── handles: [String: Peripheral]   (strong)
  │       └── manager: ReliaBLEManager?      (weak, set via attach)
  └── BluetoothActor
        ├── registry: PeripheralRegistryBridge   (injected at init)
        ├── discoveredPeripherals: [DiscoveredPeripheral]   (name kept; element type changed)
        ├── cbPeripherals: [String: CBPeripheral]
        ├── connectionStates: [String: ConnectionState]
        └── resolveAndUpsertDiscovered(...)   ← single id-resolution site
```

**Keep the actor property named `discoveredPeripherals`.** Only its element type changes. Renaming it to `discoveredSnapshots` would break two `@testable` accesses (`ReliaBLEManagerTests.swift:1500`, `:1783`) and four internal DocC links for zero functional gain, inside an already-large commit whose review budget is the scarce resource. If the rename is wanted for clarity, make it a separate trailing commit.

No process-global registry. Two managers → two registries → two independent handles for the same physical device, per the one-stack-per-manager rule.

### D9 — One shared id-resolution helper

Factor the logic currently duplicated at `handlePeripheralDiscovered` (`BluetoothActor.swift:876`) and `handleWillRestoreState` into one private actor method:

```swift
/// Resolves the app-facing id and upserts the discovered snapshot list. Returns the resolved id.
/// Does NOT broadcast and does NOT emit discovery events — callers keep those responsibilities.
/// Merge rule: a nil `name` / `rssi` / `advertisement` means "keep the existing value,
/// falling back to nil / empty when there is none".
private func resolveAndUpsertDiscovered(
    cbPeripheral: CBPeripheral,
    name: String?,
    rssi: Int?,
    lastSeen: Date,
    advertisement: AdvertisementData?
) -> String
```

Id resolution is identical at both sites: `identifier = cbPeripheral.name ?? advertisement.localName ?? cbPeripheral.identifier.uuidString`; match by `id`, then by `cbIdentifier`, else append.

**The update branches are not identical, and the helper must not flatten them.** Restore preserves prior values where discovery overwrites:

| Field | Discovery (`:930`) | Restore (`:742`, `:744`, `:751`, `:754`) |
|-------|--------------------|------------------------------------------|
| `rssi` | new value | **keeps** `discoveredPeripherals[idx].rssi` |
| `advertisement` | new value | **keeps** prior, `?? emptyAdvertisement` |
| `name` | overwrites | `name ?? existing` in the `cbIdentifier`-match branch |

A helper that made restore pass `nil` rssi and a fresh empty `AdvertisementData` would **regress restore**: a device discovered before termination and then restored would have its RSSI and last advertisement wiped from the snapshot list *and*, now that Option A promotes them, from its handle metadata. That is a user-visible behavior change disguised as a refactor, and no existing test would catch it. Hence the explicit nil-means-keep merge rule above, with discovery always passing non-nil so the rule is a no-op there. **Add a test** asserting a restored, previously-discovered peripheral keeps its RSSI and advertisement.

**No `emitDiscoveryEvent` flag.** `PeripheralDiscoveryEvent` is broadcast at `:886-890`, *before* id resolution begins, from data the helper never receives. Leaving that broadcast at the discovery call site preserves the "restored peripherals never hit the ad feed" invariant for free.

**The helper does not broadcast.** Discovery broadcasts once per advertisement (`:953`); restore broadcasts **once after its loop**, guarded by `didMutatePeripherals` (`:722`, `:771`, `:804`), specifically to avoid N broadcasts of partially-updated lists for N restored peripherals. Both callers keep their existing broadcast placement.

**`lastSeen` on restore.** Today restore stamps `lastSeen: now` for a device that has not actually advertised (`:744-766`). Harmless while it is an internal list field; once Option A makes it a public my-devices field it renders as "Last seen: just now" for a device last heard from before the app was killed. **Decision: keep `now`, and document `lastSeen` as "last bound or seen"** — changing it to preserve the prior value would make restored-but-never-discovered peripherals show nil, which is worse for the list UI. Revisit if it confuses users.

**`refreshPeripherals()` (`:999-1016`) needs no bridge call.** It re-binds live references after a power cycle but resolves no new ids and changes no metadata. Named here so the "single id-resolution site" claim is accurate and an implementer grepping for snapshot mutation sites does not have to guess.

### D10 — Connection state: cached sync property on the handle; the stream stays id-keyed

Issue #56 explicitly leaves this to planning ("stream on handle and/or existing manager streams keyed by id—planning chooses"). The choice:

- **`public var connectionState: ConnectionState? { get }`** on `Peripheral` — a cached, `Mutex`-backed sync read, mirrored from the actor's `connectionStates` through the same bridge, via `applyConnectionState(id:state:)`.
- **`ConnectionStateChange.peripheralId: String` and `connectionStateChanges` are unchanged.** Apps observe with the existing stream and filter on `change.peripheralId == peripheral.id`.
- **No per-handle `AsyncStream` this phase** — that needs its own broadcaster lifecycle tied to handle deallocation, and is a follow-up.

Rationale for doing the cached property *now* rather than in a later PR: "is it connected?" is the single most important field on the my-devices row this phase exists to enable, and FR-2.3.1 says connection-state consumption should migrate to `Peripheral` as the handle model lands. The bridge, the lock, and the actor-ordered write path are all already being built here — mirroring a second field costs one protocol method and one property, whereas deferring means reopening the identical seam later. Mirror it wherever `connectionStates[id]` is written on the actor.

The same change-notification caveat from D2 applies: re-read it inside a `connectionStateChanges` loop.

### D11 — Public `Peripheral(id:)` is removed

`manager.peripheral(id:)` replaces it. This is the point: `Peripheral(id:)` today produces an unregistered value with no manager, which can only ever fail to connect. The handle's init becomes internal and is callable only from the registry. Tests and the Demo migrate to `manager.peripheral(id:)`.

### D12 — Logging unchanged

Keep `LogTag.peripheral(String)` carrying the handle id. No changes to `LoggingService` or tag shapes.

### D13 — FR-10 attachment point

The class choice reserves a home for the future sticky discovery filter, command queue, and readiness state on the handle. **Do not add any public filter or readiness API now, and do not add storage for it** — a comment noting the intended location is sufficient. FR-10 is #52, out of scope.

### D14 — Registry lifecycle: strong values, cleared on `shutdown()`

The registry holds handles **strongly**, keyed by resolved id, populated on every discovery. Nothing in the design evicts them, and each handle retains a full `AdvertisementData` (`manufacturerData: Data`, `serviceData: [CBUUID: Data]`, three UUID arrays). For a library whose headline feature is continuous background scanning, unbounded growth is a real leak class: in a crowded environment every distinct advertised name — and every nameless device's UUID string — mints a permanent handle.

**Decision: clear the registry in `shutdown()`**, matching what the actor already does with `cbPeripherals` / `discoveredPeripherals` / `connectionStates` (`BluetoothActor.swift:255-261`). This costs two lines and harms nothing: handles the app still holds keep working (orphaned, throwing `.bluetoothUnavailable`), and the stack is dead anyway.

`invalidatePeripherals()` behaves differently and deliberately: it **keeps** handles and their last-known metadata, because the handle must survive a radio reset.

Weak-value storage (`[String: WeakBox<Peripheral>]` with prune-on-insert) was considered as a stronger answer — interning identity would then last exactly as long as the app holds a reference, which is the only window in which `===` is observable. It is **deferred**: it changes the registry's type, raises a metadata side-cache question (a re-created handle would start empty), and is not needed to ship this phase. Revisit alongside FR-8.5 / #51 if profiling shows growth matters.

## Proposed signatures

### `Sources/ReliaBLE/Models/DiscoveredPeripheral.swift` (new)

```swift
public struct DiscoveredPeripheral: Sendable, Identifiable, Hashable {
    public let id: String
    public let cbIdentifier: UUID?
    public let name: String?
    public let rssi: Int?
    public let lastSeen: Date?
    public let advertisement: AdvertisementData?

    /// The interned control handle for the manager that produced this snapshot.
    public var peripheral: Peripheral { get }

    // internal — no app-facing init; excluded from ==/hash
    let registry: PeripheralHandleRegistry
    init(id:cbIdentifier:name:rssi:lastSeen:advertisement:registry:)
}
```

### `Sources/ReliaBLE/Models/Peripheral.swift` (rewrite)

```swift
public final class Peripheral: Sendable, Identifiable, Hashable {
    public let id: String

    public var cbIdentifier: UUID? { get }
    public var name: String? { get }
    public var rssi: Int? { get }
    public var lastSeen: Date? { get }
    public var advertisement: AdvertisementData? { get }

    /// Last-known connection state, mirrored from the actor. See D10.
    public var connectionState: ConnectionState? { get }

    public func connect(autoReconnect: Bool = true) async throws
    public func disconnect() async throws

    public static func == (lhs: Peripheral, rhs: Peripheral) -> Bool   // id only
    public func hash(into hasher: inout Hasher)                        // id only

    // internal
    init(id: String, manager: ReliaBLEManager?)
    func applyMetadata(cbIdentifier:name:rssi:lastSeen:advertisement:)
    func applyConnectionState(_ state: ConnectionState)
}
```

// New file: Sources/ReliaBLE/PeripheralHandleRegistry.swift

```swift
final class PeripheralHandleRegistry: PeripheralRegistryBridge, Sendable {
    struct Storage {
        weak var manager: ReliaBLEManager?
        var handles: [String: Peripheral] = [:]
    }
    private let storage: Mutex<Storage>

    init()                                               // no manager yet — see D6
    func attach(manager: ReliaBLEManager)                // phase two of construction
    func peripheral(id: String) -> Peripheral            // intern (create or return)
    func removeAll()                                     // called from shutdown() — D14

    // PeripheralRegistryBridge — invoked only from the actor's executor
    func applyDiscovery(id:cbIdentifier:name:rssi:lastSeen:advertisement:)
    func applyConnectionState(id:state:)
}
```

Note that `Peripheral`'s init is `internal`, which does **not** enforce "only the registry constructs handles" — anything in the module can call it, including the actor, which is exactly the divergence hazard the registry exists to prevent. Either co-locate `Peripheral` and `PeripheralHandleRegistry` in one file and mark the init `fileprivate`, or keep `internal` and treat the single-construction-site rule as a review-enforced convention. Say which in the code comment.

### `Sources/ReliaBLE/ReliaBLEManager.swift`

```swift
// ADD
public func peripheral(id: String) -> Peripheral

// CHANGED ELEMENT TYPE
public var discoveredPeripherals: AsyncStream<[DiscoveredPeripheral]> { get }

// REMOVED
// public func connect(to:autoReconnect:) async throws
// public func disconnect(from:) async throws

// INTERNAL
let handleRegistry: PeripheralHandleRegistry   // constructed then attach(manager: self) — D6
// `let bluetooth: BluetoothActor` is ALREADY internal (:46); handles call
// `manager.bluetooth.ensureCentralManager()` directly. No access widening, no new helper.
```

Final public stream surface: `state: AsyncStream<BluetoothState>`, `peripheralDiscoveries: AsyncStream<PeripheralDiscoveryEvent>`, `discoveredPeripherals: AsyncStream<[DiscoveredPeripheral]>`, `connectionStateChanges: AsyncStream<ConnectionStateChange>`.

## State and data flow

**Known-id path.** `manager.peripheral(id: "band-1")` → registry lock → create `Peripheral(id:, weak manager)` with empty metadata → return. No CB, no actor hop. Later, when discovery resolves to `"band-1"`: `resolveAndUpsertDiscovered` → `registry.applyDiscovery` updates that same instance's metadata → `cbPeripherals["band-1"] = cb`. Then `try await p.connect()` → manager ensures central → `actor.connect(id: "band-1")`.

**Scan / nearby path.** `didDiscover` → `PeripheralDiscoveryEvent` broadcast → `resolveAndUpsertDiscovered` upserts a registry-carrying `DiscoveredPeripheral` → `registry.applyDiscovery` → broadcast `[DiscoveredPeripheral]`. The apply **precedes** the broadcast (invariant, see Concurrency). `discovered.peripheral` returns the same instance `manager.peripheral(id:)` would.

**Restore path.** `willRestoreState` → `resolveAndUpsertDiscovered` per peripheral (nil rssi/advertisement → prior values kept, per the D9 merge rule; no ad-feed emission because the caller simply doesn't broadcast one) → `registry.applyDiscovery` → seed `connectionStates` and re-arm reconnect intent from persistence → **one** broadcast after the loop, guarded by `didMutatePeripherals`.

**Shutdown / manager deinit.** `shutdown()` clears actor maps and finishes streams. Handles may remain alive in app code with `manager == nil`; `connect`/`disconnect` then throw `.bluetoothUnavailable`.

**Duplicate / out-of-order ads.** Latest wins for both the snapshot list and handle metadata; handle identity stays stable; the cb map is last-writer-wins — the same known same-name collapse as today.

## Error handling and edge cases

| Case | Behavior |
|------|----------|
| `connect()` on a handle never discovered (no live CB ref) | `PeripheralError.notFound` — actor path unchanged |
| Manager deallocated, or `shutdown()` already ran | `PeripheralError.bluetoothUnavailable` |
| Bluetooth unavailable / unauthorized | `.bluetoothUnavailable` via the existing ensure path |
| Device name changes, same CB UUID | Resolves by `cbIdentifier`, preserving the original `id` (today's behavior) |
| Two devices advertising the same name | Collapse to one id — known limitation, document, FR-8.5 later |
| Handle from manager A used while B also runs | Handle only talks to its own weak manager; it cannot reach B's CB map |
| `discovered.peripheral` after its manager was freed | Orphan handle; `connect` throws `.bluetoothUnavailable` |
| `manager.peripheral(id: "")` | Allowed, treated as a normal id — no special case |
| Two managers, same id string | `==` is `true`, `===` is `false`; documented as an app-level hazard |
| `invalidatePeripherals()` (`:956-968`) | Clears `cbPeripherals` and connection state; **keeps** handles and their last-known metadata — the handle must survive a radio reset |
| `shutdown()` (`:255-261`) | Clears the actor's maps **and** the handle registry (D14). Handles the app still holds keep working, orphaned, throwing `.bluetoothUnavailable` |
| Restored peripheral previously discovered | Keeps its prior RSSI and advertisement (D9 merge rule); `lastSeen` is stamped to now and documented as "last bound or seen" |
| Explicit disconnect | Unchanged nil-reason contract |

## Concurrency and lifecycle

- The handle's `Mutex` guards metadata only; the registry's guards the handle table. `Mutex.withLock` is non-async, so `await` cannot appear inside — the "never suspend under the lock" rule is enforced structurally.
- **Lock order: registry → handle, never the reverse.** Better still, avoid nesting entirely: `applyDiscovery` should copy the handle reference out under the registry lock, **release**, then call `handle.applyMetadata(...)`.
- **Bridge contract.** Direct actor re-entry is already impossible — the protocol methods are synchronous and non-throwing, so calling back into the actor would require `await`, which cannot appear. The rules that *are* reachable and therefore matter: implementations must be non-blocking and allocation-light (the actor's executor thread stalls behind whoever holds the registry lock); must **not** spawn `Task { await actor… }`, which compiles fine inside a sync function and reorders arbitrarily against the discovery stream; must not invoke app-supplied callbacks under a lock; and must observe the lock order above.
- **Apply-before-broadcast invariant.** `registry.applyDiscovery(...)` must run **before** the snapshot list is broadcast, so a consumer receiving snapshot *N* never reads handle metadata older than *N*. This is a requirement, not an incidental ordering — a later "broadcast early to cut latency" change would silently break it. Covered by a test (see Verification).
- Streams continue to retain the actor (existing design, unchanged).
- **Retain graph — the complete rule:** manager → registry (strong) → handles (strong) → manager (**weak**); manager → actor → registry-as-bridge (strong) → manager (**weak**); snapshot → registry (strong). App code holds handles strong.

  **Nothing reachable from the actor may hold the manager strongly.** This is the one place a real leak can hide: the actor stores the bridge, so a bridge capturing the manager strongly makes the cycle manager → actor → bridge → manager. And because live stream subscribers retain the actor, a single un-terminated `for await` would then pin the manager, its central, and every handle for the process lifetime — making the entire orphan-handle contract unreachable in production *and* in tests. Having the registry conform to `PeripheralRegistryBridge` itself (D6) satisfies this automatically, since the registry's manager reference is already weak.

## File-by-file impact

| File | Change | Driver |
|------|--------|--------|
| `Sources/ReliaBLE/Models/Peripheral.swift` | Rewrite as the `final class` handle; remove public `init(id:)` | D1–D3, D11 |
| `Sources/ReliaBLE/Models/DiscoveredPeripheral.swift` | **New** — snapshot struct carrying the registry + `.peripheral` sugar | D4, D7 |
| `Sources/ReliaBLE/PeripheralHandleRegistry.swift` | **New** — intern registry + `PeripheralRegistryBridge` adapter | D6, D8 |
| `Sources/ReliaBLE/BluetoothActor.swift` | Snapshot list element type (**property name unchanged**); accept `registry:` in `init`; factor `resolveAndUpsertDiscovered` with merge semantics; call bridge from discovery + restore; mirror connection-state writes through the bridge; clear the registry in `shutdown()`; stream element type | D6, D8, D9, D10, D14 |
| `Sources/ReliaBLE/ReliaBLEManager.swift` | Add `peripheral(id:)`; remove connect/disconnect; change stream element type; construct registry then `attach(manager:)` in `init` (two-phase — see D6) | D3–D6 |
| `Sources/ReliaBLE/Models/Events/PeripheralDiscoveryEvent.swift` | Doc only — clarify `id` is the CoreBluetooth identifier | D5 |
| `Sources/ReliaBLE/Models/PeripheralError.swift` | Doc only — errors now surface from handle calls | Docs |
| `Sources/ReliaBLE/Models/ConnectionState.swift` | Doc only — `peripheralId` is the handle's id | Docs |
| `Sources/ReliaBLE/ReliaBLEConfig.swift` | Doc only — references to the connect path | Docs |
| `Tests/ReliaBLETests/ReliaBLEManagerTests.swift` | Migrate all `Peripheral`/connect/disconnect sites; add interning tests | Verification |
| `Sources/ReliaBLE/Documentation.docc/**` | Rewrite the Peripheral narrative across all five files | CI docc gate |
| `Demo/.../Central/DeviceStoreActor.swift:68` | `syncDevices(_ peripherals: [DiscoveredPeripheral])` | Demo compiles |
| `Demo/.../Central/CentralView.swift:282,286` | Connect/disconnect via `reliaBLE.peripheral(id:)` handle | D3, D11 |
| `PRD.md` | **Already updated** during planning: FR-2.4.3 no longer prescribes "manager-stamped" (D7 carries the registry instead); new FR-8.1.4 (ad-feed id contract) and FR-8.5.4 (correlation deferral). Remaining: check off FR-2.4 items once landed | Product |
| `Package.swift:9` | `.macOS(.v10_15)` → `.macOS(.v15)` | D0 |
| `Sources/ReliaBLEMock/CoreBluetoothMockAliases.swift`, `README.md` | **No change** | — |

## Work items

Single branch `50-peripheral-handle-type-model`. Each commit must leave `swift build && swift test` green.

**0 — Platform declarations · Trivial · Depends on: nothing**
- Goal: replace the `platforms:` block in `Package.swift:7-10` with all five Apple platforms pinned to their `Synchronization` floors (D0), unlocking `Mutex` for the types added in item 1.
- Also add the compile-only CI matrix leg for iOS/tvOS/watchOS/visionOS to `.github/workflows/ci.yml`, so the new declarations are actually enforced.
- Done when: `swift build` and `swift test` pass unchanged on macOS, and the new CI legs compile on each declared platform.
- Its own first commit — keeps item 1's diff focused on the type work.

**1 — Library API cut (#53 + #54 + #55 + #56) · Large · Depends on: 0**
- Goal: Add `DiscoveredPeripheral`, the `Peripheral` class handle, `PeripheralHandleRegistry` + bridge; move the actor's snapshot list to `[DiscoveredPeripheral]`; add `manager.peripheral(id:)`; move connect/disconnect onto the handle and remove the manager versions; factor `resolveAndUpsertDiscovered` and wire it into both discovery and restore; migrate the whole test file in the same commit.
- Key files: `Models/Peripheral.swift`, `Models/DiscoveredPeripheral.swift`, `PeripheralHandleRegistry.swift`, `BluetoothActor.swift`, `ReliaBLEManager.swift`, `Tests/ReliaBLETests/ReliaBLEManagerTests.swift`.
- Done when: `swift build` and `swift test` pass with no manager-level connect and no public `Peripheral(id:)`.
- Note: this is deliberately one large commit. Removing the struct breaks every call site simultaneously, so there is no smaller green slice — attempts to stage it need throwaway shims that cost more than they save.

**2 — DocC migration · Medium · Depends on: 1**
- Goal: Update all five DocC files plus the doc-only source comments so no symbol link is stale.
- Key files: `Documentation.docc/Documentation.md`, `GettingStarted.md`, `Topics/Background.md`, `Topics/Concurrency.md`, `Topics/Multi-Manager.md`; doc comments in `PeripheralDiscoveryEvent.swift`, `PeripheralError.swift`, `ConnectionState.swift`, `ReliaBLEConfig.swift`.
- Done when: the DocC command below passes with `--warnings-as-errors`.
- **Items 1 and 2 must land together in the PR** — CI runs the docc gate on every PR, and stale ``Peripheral/init(id:)`` links fail it.

**3 — Demo migration · Small · Depends on: 1**
- Goal: `syncDevices(_ peripherals: [DiscoveredPeripheral])` at `DeviceStoreActor.swift:68`; in `CentralView.swift`'s private `DeviceDetailView` (:248), replace `Peripheral(id: device.id)` connect/disconnect at :282 and :286 with `reliaBLE.peripheral(id: device.id)` + handle calls. The Demo's own SwiftData `Device` and `DiscoveryEvent` types stay as-is — do not introduce a library `Device` type.
- Done when: the Demo builds. **The implementer must read `Demo/AGENTS.md` first and use XcodeBuildMCP, not raw `xcodebuild`.** The Demo is not in CI.

**4 — New behavior tests · Medium · Depends on: 1**
- Goal: Add the seven interning/sugar/isolation tests listed below.
- Done when: `swift test` green, each new test passing individually.

**5 — Docs bookkeeping · Small · Depends on: 1–4**
- Goal: Close this plan's decision log; check off PRD FR-2.4 items that are now accurate.

## Verification

### Existing tests to rewrite (`Tests/ReliaBLETests/ReliaBLEManagerTests.swift`)

| Test / helper | Change |
|---------------|--------|
| `waitForPeripheral` (`:2170`) | **Keep a snapshot-returning `waitForDiscovered(id:) -> DiscoveredPeripheral?`** and derive the handle at call sites via `discovered.peripheral`. Silently repointing this helper at the handle would leave `#expect(peripheral?.advertisement?.localName == …)` and `#expect(peripheral?.cbIdentifier != nil)` (`:336-338`) reading whatever the *latest* discovery wrote — they would still pass, but would no longer test the snapshot the stream actually emitted, which is the entire point of those assertions. Preserve at least one assertion against snapshot fields. A handle-returning variant may be added alongside |
| Peripheral Sendable proof (`:84-88`) | Capture the class handle from `manager.peripheral(id:)` across `Task.detached` |
| Equality/hash tests (`:110-126`) | Keep as an **interning** assertion only: `manager.peripheral(id: "x") === manager.peripheral(id: "x")`. Under interning these return the same object, so `==` is satisfied by *any* implementation including default identity — the id-only equality contract cannot be proven here. Move the real `==` assertion and the `Set`-count check into the two-manager test below |
| Manager Sendable proof (`:65-70`) | Stream type is `AsyncStream<[DiscoveredPeripheral]>`; use `peripheral(id:)`; drop the `connect(to: Peripheral(id: "unused"))` reference at `:70` |
| All 36 `connect(to:)` / `disconnect(from:)` sites | `try await handle.connect(autoReconnect:)` / `try await handle.disconnect()`. Full list in Background; the multi-manager and restoration clusters at `:1455`, `:1550`, `:1596`, `:1655`, `:1808` are easy to miss |
| Stale/unknown-peripheral connect (`:445-462`) | The existing test deliberately accepts `.notFound || .bluetoothUnavailable`, because `makeManager()` does not bring the central online (authorization pinned `.notDetermined`, `:2049`) and `init`'s fire-and-forget `Task { await bluetooth.ensureCentralManager() }` may not have completed. **To assert `.notFound` deterministically the test must first `await Mock.ensureReady(manager)`** — otherwise keep the either-or assertion |
| Restoration tests | List element type is `DiscoveredPeripheral`; assert restored handle metadata; `testContainsCBPeripheral` assertions unchanged |
| Multi-manager isolation tests (`:1808`) | Discover on A; `a.peripheral(id:) === listElement.peripheral`; B's same-id handle is `!==` **but** `==`, with the `Set` count check; only A holds the live ref |

### New tests

1. `peripheralIdInternsSingleInstance` — `manager.peripheral(id: "x") === manager.peripheral(id: "x")`.
2. `discoveredPeripheralSugarReturnsInternedHandle` — scan, take a snapshot from the stream, assert `snap.peripheral === manager.peripheral(id: snap.id)`.
3. `knownIdHandleReceivesMetadataOnDiscovery` — create the handle *first*, then scan until match; assert `rssi`/`lastSeen`/`advertisement` become non-nil on that **same** instance.
4. `connectOnHandleNeverSeenThrowsNotFound` — ready manager, handle with no discovery; connect throws `.notFound` (central exists, live ref does not).
5. `twoManagersIndependentHandleRegistries` — same id string on both; `a.peripheral(id:) !== b.peripheral(id:)`; discover only on A; only A holds a live ref.
6. `handleConnectDisconnectLifecycle` — full `connecting → connected → disconnecting → disconnected` through handle APIs, asserting the cached `peripheral.connectionState` tracks it (may fold into an existing lifecycle test).
7. `discoveredPeripheralsStreamElementType` — the replayed list is `[DiscoveredPeripheral]` and contains the test id.
8. `restorePathInternsSameHandle` — pre-create `manager.peripheral(id:)`, drive restore via `bluetooth.testHandleWillRestoreState` (the hook already used at `:1628`, `:1679`, `:1704`, `:1745`), assert the **same instance** received `cbIdentifier` and that `testContainsCBPeripheral` holds. Per D9, also assert a previously-discovered peripheral **keeps** its prior RSSI and advertisement across restore — this is the regression guard for the merge rule.
9. `handleMetadataAppliedBeforeBroadcast` — subscribe to `discoveredPeripherals`; on the **first** element containing the test id, immediately assert `manager.peripheral(id: testId).rssi != nil`. No polling — that is what makes it a real ordering assertion (invariant in the Concurrency section).
10. `handleOrphansWhenManagerDeallocates` — create a manager in an inner scope, take a handle, drop the manager and end all stream subscriptions, then assert `handle.connect()` throws `.bluetoothUnavailable`. **This test is the leak detector** for the retain-graph rule: if anything reachable from the actor holds the manager strongly, it fails.

### Commands

```sh
swift build
swift test
swift test --filter ReliaBLETests.peripheralIdInternsSingleInstance
swift test --filter ReliaBLETests.handleOrphansWhenManagerDeallocates

# DocC gate — same invocation CI uses (.github/workflows/ci.yml:65-72)
swift package --allow-writing-to-directory ./user-docs \
  generate-documentation --target ReliaBLE \
  --disable-indexing \
  --transform-for-static-hosting \
  --hosting-base-path ReliaBLE \
  --output-path ./user-docs \
  --warnings-as-errors
```

Demo build is not in CI — verify via XcodeBuildMCP per `Demo/AGENTS.md`.

### DocC migration checklist

- `Documentation.md` — Peripherals topic lists `Peripheral`, `DiscoveredPeripheral`, `PeripheralDiscoveryEvent`.
- `GettingStarted.md` — remove the snapshot narrative, `Peripheral(id:)`, and manager connect; teach `manager.peripheral(id:)`, scan → `discovered.peripheral`, handle connect, and Option A metadata. **Must state that handle metadata carries no change notification** (D2): apps re-read it inside the `discoveredPeripherals` loop, which doubles as the "something changed" tick. Without this, the my-devices example teaches a list that renders once and goes stale.
- `Topics/Background.md` — restored devices surface on `discoveredPeripherals` as `DiscoveredPeripheral`; connect intent still persists and re-arms.
- `Topics/Concurrency.md` — value types are `DiscoveredPeripheral`, `AdvertisementData`, and the events; the **handle is a `Sendable` class whose mutable metadata lives in a `Mutex`**, with the D1 contract spelled out (no CB on the handle, writes only from actor-ordered paths, lock never held across a suspension).
- `Topics/Multi-Manager.md` — per-manager registry; the same physical device yields two distinct handles.

## Risks

| Risk | Mitigation |
|------|------------|
| Retain cycle manager ↔ handle | Handle holds `weak` manager (inside its `Mutex<State>`); registry holds handles strong; manager holds registry strong |
| Raising the macOS floor breaks macOS consumers | Pre-release library, breaking changes expected (AGENTS.md); call it out in the PR body. The declared 10.15 floor was already inconsistent with the iOS 18 floor |
| `Mutex` misuse (holding across suspension) | Structurally prevented — `withLock` is non-async; reviewers check no CB calls and no `Task { }` inside the closure |
| Manager leaks via a bridge that captures it strongly | Registry conforms to the bridge protocol itself and holds the manager weakly; `handleOrphansWhenManagerDeallocates` is the regression test |
| Registry grows unbounded during long background scans | Cleared on `shutdown()` (D14); weak-value eviction deferred with a documented trigger |
| Extracting `resolveAndUpsertDiscovered` silently regresses restore | Explicit nil-means-keep merge rule (D9) plus a restore-preserves-metadata assertion in test 8 |
| Contributors on macOS 14 can no longer build the library | Consequence of D0; call it out in the PR body |
| DocC gate fails the PR | DocC updates land in the same PR as the API cut (work items 1+2 together) |
| Commit 1 is unavoidably large | Accepted; the alternative is throwaway shim APIs. Commits 2–4 stay small and reviewable |
| Bridge accidentally invoked off-actor | Bridge is internal, called only from actor-isolated methods, and documented as such on the protocol |
| Identity still name-derived | Unchanged from today; FR-8.5 will revisit interning and matching |
| Apps carrying the old snapshot mental model | README and GettingStarted lead with handles |

**Rollback:** revert the PR. No persistence schema change — restore intent still keys on String ids.

## Decisions (resolved at mid-flow check-in, 2026-07-31)

| Question | Decision |
|----------|----------|
| One PR vs. four | **One PR** closing #50, four sequential green commits |
| `Package.swift` macOS floor | **Leftover** — raise to `.macOS(.v15)`, use `Synchronization.Mutex`, checked `Sendable` throughout |
| Manager `connect(to:)` / `disconnect(from:)` | **Removed outright** — no deprecation shim, not retained internally |
| Option A metadata access | **Sync cached properties** on the handle |

Decisions carried from `docs/designs/discovered-peripheral-vs-peripheral-2026-07-15.md` and resolved in the design section above: `Peripheral` is a `final class` (D1); `discoveredPeripherals` vends `[DiscoveredPeripheral]`, not handles (D4); both discovery feeds survive (D5); `peripheral(id:)` is sync/nonisolated over a manager-owned registry (D6); discovery and restore share one id-resolution helper (D9); public `Peripheral(id:)` is removed (D11); a tracked-peripherals feed stays deferred (D4).

### Resolved by the design critique

`docs/reviews/peripheral-handle-type-model-plan-critique-2026-07-31.md`. Findings applied:

| Question | Decision |
|----------|----------|
| Registry ↔ manager wiring | **Two-phase `attach(manager:)`** — the naive `PeripheralHandleRegistry(manager: self)` does not compile (D6) |
| `ManagerStamp` vs. registry reference in the snapshot | **Registry reference** — deletes a type, removes an injection dependency, and keeps interning valid after manager death (D7) |
| Bridge shape | **One `applyDiscovery` method** (create-or-update) plus `applyConnectionState`; registry conforms to the protocol directly, no adapter type (D6) |
| `peripheral.connectionState` now or later | **Now** — #56 leaves the choice to planning, and it is one extra method on a bridge already being built (D10) |
| SwiftUI change signal for handle metadata | **Documentation-only** — `discoveredPeripherals` is the "something changed" tick; no new API (D2) |
| Registry growth / eviction | **Strong values, cleared on `shutdown()`**; weak-value eviction deferred (D14) |
| Rename actor's `discoveredPeripherals` | **No** — element type changes, property name stays (D8) |
| PoweredOn gating in `handle.connect()` | **No** — preserves today's ensure-then-throw; FR-1.4/FR-8.6 arrive with #57 (Out of scope) |
| `lastSeen` semantics on restore | **Keep `now`**, documented as "last bound or seen" (D9) |

### Resolved after the critique

| Question | Decision |
|----------|----------|
| Platform support | **All five Apple platforms declared**, each pinned to its `Synchronization.Mutex` floor — iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2. Compile-verified per platform; CI gains a compile-only matrix leg (D0) |
| `PeripheralDiscoveryEvent.peripheralId` correlation field | **Deferred to FR-8.5**, which redefines advertisement→id identity; adding it now would bake in today's name-derived resolution and change again (D5). Recorded in the PRD as FR-8.5.4 |

## Open Questions


*(None blocking. Both questions carried out of the design critique are now resolved — see the decisions table above.)*

## Definition of done

- [ ] Public API matches the signatures above; no manager connect/disconnect; no public `Peripheral(id:)`.
- [ ] One handle instance per id per manager; the `.peripheral` sugar returns that instance, including after the manager is deallocated.
- [ ] Discovery, restore, and `refreshPeripherals` all accounted for; one id-resolution helper; restore preserves prior RSSI/advertisement; no synthetic offline discoveries.
- [ ] Connect/disconnect on the handle; lifecycle and reconnect tests green; cached `connectionState` tracks the stream.
- [ ] Registry cleared on `shutdown()`; `handleOrphansWhenManagerDeallocates` passes — nothing reachable from the actor holds the manager strongly.
- [ ] `swift build`, `swift test`, and the DocC `--warnings-as-errors` gate all green.
- [ ] Demo builds and uses handle-centric connect.
- [ ] `Package.swift` declares all five Apple platforms at their `Synchronization` floors, and CI compiles each one.
- [ ] PR closes #50, references #53–#56 as delivered checkpoints, and calls out both breaking changes: the type split and the platform-floor bump.

## References

- Design: `docs/designs/discovered-peripheral-vs-peripheral-2026-07-15.md`
- Design: `docs/designs/bluetoothactor-instance-isolation-2026-07-19.md`
- Plan: `docs/plans/background-scanning-state-restoration-2026-07-13.md`
- `PRD.md` — Architecture "Public types", FR-2.1, FR-2.4, FR-2.5, FR-8.2.1, NFR-1.2, NFR-1.3; FR-1.4/FR-8.6 and FR-10 for downstream Phase 2/3 needs
- `AGENTS.md` — three-target SPM mocking trick, `CBCentralManagerFactory` constraint, `BluetoothActor` isolation rules
