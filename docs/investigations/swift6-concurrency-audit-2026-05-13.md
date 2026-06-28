# Investigation: Swift 6 Concurrency Audit of `Sources/ReliaBLE`

> **Update — 2026-06-01 (post-audit).** While this audit was being written, the
> repo merged PR #16 (commit `3657f45`) bringing in **Willow 7.0**, which is
> fully Swift 6 / strict-concurrency clean upstream. All `@preconcurrency
> import Willow` directives have been removed; `LogMessage.attributes` is now
> `[String: any Sendable]`; `LogTag`/`LogTag.Category` are explicit `Sendable`;
> `OSLogWriter` is `final`. **This obsoletes Cluster 4 ("Logging stack pinned
> to non-`Sendable` Willow") and the "drop Willow → `os.Logger`" recommendation
> in §C below.** See the *Post-Willow-7.0 Revision* note at the end of each
> affected section. Clusters 1–3 (BLE state races, Combine surface, `@unchecked
> Sendable` peripheral classes) are unchanged and still drive the bulk of the
> recommended refactor.

## Summary
Audit of the ReliaBLE library's three core files (`BluetoothManager.swift`,
`ReliaBLEManager.swift`, `PeripheralManager.swift`) against modern Swift 6.1
strict-concurrency / iOS 18 best practices. The library is greenfield, so the
audit is unconstrained by API backward compatibility.

Design constraints the recommendations must respect:
- Callable from `@MainActor` (SwiftUI) without `await` ceremony being painful,
  but **not required** to live on the main actor.
- Callable entirely from background actors / nonisolated contexts.
- Three-target SPM trick must keep working (`CBCentralManagerFactory` swap).
- `forceMock: true` is load-bearing — must not be "cleaned up".
- DocC catalog & public API surface need to be maintained.

## Symptoms / Issues Suspected (a priori)
- `BluetoothManager` is a plain `NSObject` class with mutable state (`centralManager`,
  Combine subjects). State reads/writes are not all routed through its private
  `DispatchQueue`. Delegate callbacks come in on the queue; public methods are
  callable from any thread.
- `PeripheralManager` is `@unchecked Sendable` with `queue.sync`-based
  serialization. Mutating callbacks happen on the **BluetoothManager queue**, not
  the `PeripheralManager` queue, so concurrency is sound by "single producer"
  rather than by isolation.
- `Peripheral` is `@unchecked Sendable` using a manual `NSLock`. It exposes
  `CBPeripheral?` and `[String: Any]?` — neither is `Sendable`.
- `ReliaBLEManager` is a non-`final`, non-`Sendable` `class`. With Swift 6
  strict concurrency, sharing it across actors will warn/error.
- Combine `PassthroughSubject` / `CurrentValueSubject` are not `Sendable` in
  Swift 6. The public API surfaces `AnyPublisher<...>` which has the same
  issue. Modern equivalent: `AsyncStream` / `Observation`.
- `@preconcurrency import Willow` papers over Willow's non-`Sendable` Logger.
- `ReliaBLEConfig` has stored mutable properties (struct is fine) but
  `[LogWriter]` and `DispatchQueue` `Sendable` posture should be checked.
- `authorize()` is a synchronous throwing method — may race with delegate
  callbacks if state changes mid-call.
- `BluetoothManager.startScanning/stopScanning` read `centralManager.isScanning`
  off-queue (CB API contract is queue-affined).

## Background / Prior Research

External research (Swift 6.1 / iOS 18, CoreBluetooth + concurrency) — summary from
Phase 1.5 explore agent.

**Apple guidance / state of the ecosystem (mid-2024 → 2025):**
- WWDC24 "Migrate your app to Swift 6" (session 10169) endorses **actors** as
  the primary tool for serializing state behind callback-style APIs.
- Apple has **not** shipped `AsyncSequence` / `Observation`-flavored
  CoreBluetooth APIs through iOS 18. `CBCentralManagerDelegate` and the
  delegate-queue model are still the only mechanism. `CBCentralManager` and
  `CBPeripheral` are not `Sendable`.
- `CBCentralManager.authorization` remains a synchronous class property; no
  async authorization API exists.

**Current best-practice patterns for a Swift 6 BLE library:**
1. **Global actor + delegate shim** — declare a `@globalActor BluetoothActor`,
   put all BLE state on it, and use a small `NSObject` "shim" that adopts
   `CBCentralManagerDelegate`. Each delegate callback is `nonisolated` and
   immediately `Task { @BluetoothActor in … }`'s into the actor. This avoids
   `@unchecked Sendable`, eliminates manual queue/lock dances, and gives the
   compiler real isolation guarantees.
2. **Custom serial executor** (Swift 5.9+) — alternatively, an `actor` can
   adopt a `SerialExecutor` backed by the CoreBluetooth `DispatchQueue`, so
   the actor *is* the delegate queue. Eliminates the hop in delegate
   callbacks. Slightly more advanced but ideal for hot paths like discovery.
3. **AsyncSequence / AsyncStream for events** — replace
   `PassthroughSubject` / `CurrentValueSubject` (non-Sendable in Swift 6).
   `AsyncStream` is itself `Sendable`; its continuation can be yielded from
   an actor. `Observation` (`@Observable`) is the right tool for "current
   snapshot" state for SwiftUI; less appropriate for high-volume event
   streams like advertisement bursts (use AsyncStream there).
4. **Snapshot/value peripherals** — keep mutable peripheral state inside an
   actor; hand consumers a `Sendable` `struct Peripheral` snapshot. Avoids
   leaking `CBPeripheral` or `[String: Any]` across actor boundaries. For
   long-lived "handles" (e.g., to connect/read later), expose an opaque
   `Sendable` ID (e.g., a wrapped `UUID`).

**Anti-patterns in 2026:**
- `@unchecked Sendable` + manual `NSLock` for ad-hoc data classes — defeats
  Swift 6's whole point and is brittle when the API surface grows.
- Publishing `AnyPublisher<…, Never>` as the supported public event API in a
  Swift 6 library. Combine subjects/publishers are not `Sendable`; consumers
  on different actors get warnings and `@preconcurrency` hacks. (Combine
  itself is on a slow deprecation path for new code.)
- `@preconcurrency import` of a transitive dependency *and* re-exposing
  types from it — fine for internal use, problematic if it leaks into the
  public surface.

**Survey of comparable open-source libraries** (per explore agent): Most
pre-Swift-6 BLE libraries (Bluejay, RxBluetoothKit, BlueCapKit) have not yet
been ported. Newer entrants and forks (e.g. `swift-async-bluetooth`-style)
trend toward `actor`-based managers and `AsyncStream` event APIs. No widely
adopted Swift 6 BLE library has settled into a clear "winning" public API
shape — there is room for ReliaBLE to set a sensible one.

**Citations:** WWDC24 session 10169 (Migrate to Swift 6); Apple iOS 18
release notes (no CoreBluetooth async additions); Swift Forums discussions
on CoreBluetooth + actors (queue-sync race patterns).

## Investigator Findings

### 1. `BluetoothManager.swift` — Isolation Domain & Mutable State Audit

#### Mutable State Inventory

| Property | Line | Type | Read From | Written From | Synchronization |
|---|---|---|---|---|---|
| `centralManager` | 41 | `CBCentralManager?` | `startScanning`, `stopScanning`, `updateState`, `authorize`, `setupCentralManager` | `setupCentralManager` | **None** |
| `stateSubject` | 81 | `CurrentValueSubject<BluetoothState, Never>` | `currentState` (line 90) | `updateState` | **None** (Combine internal) |
| `discoverySubject` | 199 | `PassthroughSubject<PeripheralDiscoveryEvent, Never>` | (sink subscribers) | `centralManager(_:didDiscover:...)` | **None** (Combine internal) |
| `peripheralManager` | 39 | `PeripheralManager` | delegate callbacks | init only (immutable ref) | OK (immutable `let`) |
| `log` | 38 | `LoggingService` | all methods | init only | OK (immutable `let`) |
| `queue` | 42 | `DispatchQueue` | — | — | Only passed to CBCentralManager; **not used to protect own state** |

#### Methods: Isolation-Domain Analysis

- **`init(loggingService:peripheralManager:)`** :55 — Runs on **caller's thread** (unknown domain). Calls `setupCentralManager()` and `updateState()` synchronously. The `guard centralManager == nil` check on :69 has a **TOCTOU race**: two caller threads could both pass the nil check and create duplicate managers.

- **`setupCentralManager()`** :68 — Runs on **caller's thread** (called from `init` and `authorize()`). Reads/writes `centralManager` without queue protection. The factory call `CBCentralManagerFactory.instance(delegate: self, queue: queue, ...)` on :74 creates a real `CBCentralManager` with the `queue` dispatch queue. After this point, delegate callbacks will arrive on `queue`.

- **`state`** :85 — Computed property, returns `AnyPublisher<BluetoothState, Never>`. Callable from any thread. The `AnyPublisher` itself is **non-Sendable** under Swift 6. Subscribers on different actors will produce concurrency warnings.

- **`currentState`** :90 — Reads `stateSubject.value` synchronously on caller's thread. `CurrentValueSubject.value` is documented as thread-safe for reads but can race with concurrent `send(...)` in Swift 6 strict mode since the subject is not `Sendable`.

- **`updateState()`** :93 — Runs on **three different threads**:
  1. Caller's thread (from `init`:105)
  2. Caller's thread (from `startScanning`:172, `stopScanning`:197)
  3. **`queue` dispatch queue** (from `centralManagerDidUpdateState`:230)
  
  Reads `centralManager?.isScanning` (:108) and `centralManager?.state` (:113) — these are CoreBluetooth properties that Apple documents must be accessed from the **delegate queue**. When `updateState()` is called from `startScanning`/`stopScanning` (caller's thread), this **violates the CoreBluetooth API contract**. Sends on `stateSubject` from all three threads → `CurrentValueSubject` receive on multiple threads without isolation.

- **`authorize()`** :137 — Runs on **caller's thread**. Reads `CBCentralManager.authorization` (class property — OK from any thread) and calls `setupCentralManager()`. If `authorize()` is called from a SwiftUI button (`@MainActor`) while a delegate callback fires on `queue`, both touch `centralManager` and `stateSubject` concurrently. **Race condition**.

- **`startScanning(services:)`** :155 — Runs on **caller's thread**. Guards on `centralManager` (:156) and `centralManager.state` (:162) **off-queue**. After `centralManager.scanForPeripherals(...)` on :168, reads `centralManager.isScanning` (:170) **off-queue** — violates CoreBluetooth contract that these should be read on the delegate queue. Calls `updateState()` → sends on `stateSubject` from the caller's thread.

- **`stopScanning()`** :179 — Same pattern as `startScanning`. Reads `centralManager`, calls `centralManager.stopScan()`, reads `centralManager.isScanning` (:195) — all **off-queue**.

#### Delegate Callbacks — The "Queue Bridge"

- **`centralManagerDidUpdateState(_:)`** :206 — `CBCentralManagerDelegate` callback. Arrives on **`queue`** (dispatch queue, not an actor). Calls `peripheralManager.refreshPeripherals(using:)` or `peripheralManager.invalidatePeripherals()`, then `updateState()`. These are `nonisolated` calls to methods on `PeripheralManager`/`BluetoothManager` — they execute on the calling queue's thread. This is the **only domain** where CoreBluetooth contract is satisfied for `updateState()`.

- **`centralManager(_:didDiscover:advertisementData:rssi:)`** :226 — Arrives on **`queue`**. Constructs a `PeripheralDiscoveryEvent` (:227), sends on `discoverySubject` (:237), then calls `peripheralManager.discoveredPeripheral(...)` (:239). The `PassthroughSubject.send(...)` on :237 dispatches to Combine subscribers — if subscribers are on `@MainActor` (as in the Demo via `.receive(on: DispatchQueue.main)`), the subscriber closure hops to main. The Combine pipeline itself is **non-Sendable** and would emit concurrency warnings in Swift 6 if the subscriber closure is actor-isolated.

#### Under `-strict-concurrency=complete` — Compile-Time Predictions

1. **`BluetoothManager` is not `Sendable` and not actor-isolated**: Any cross-actor reference to a `BluetoothManager` instance would generate a warning (e.g., captured in a `Task` or passed between actors).

2. **`CurrentValueSubject` / `PassthroughSubject` are non-Sendable stored properties**: The compiler will flag these as requiring `@MainActor` isolation or `@unchecked Sendable` on the class.

3. **`state` and `peripheralDiscoveries` return `AnyPublisher<..., Never>`**: External consumers subscribing from actor-isolated contexts will get warnings because `AnyPublisher` is non-Sendable.

4. **`CBCentralManagerDelegate` conformance on a non-`@MainActor` `NSObject`**: This compiles fine (CoreBluetooth delegates are not `@MainActor`-constrained). The `centralManager?` property is weakly referenced but the delegate callbacks are dispatched on the queue — this works at the type level but not at the data-race level.

5. **The `queue` dispatch queue**: `DispatchQueue` is `Sendable`, so storing it is fine, but it's not used for any internal synchronization.

#### Summary: Root Cause

`BluetoothManager` has **three concurrency domains** touching the same mutable state:
- **Domain 1**: Caller's thread (unknown — could be `@MainActor`, background `actor`, or `nonisolated`) — `init`, `authorize`, `startScanning`, `stopScanning`, and the `updateState()` calls they trigger.
- **Domain 2**: The private `queue` dispatch queue — all `CBCentralManagerDelegate` callbacks.
- **Domain 3**: Combine subscribers' threads (e.g., `DispatchQueue.main` via `.receive(on:)`) — downstream effects of `stateSubject.send(...)` and `discoverySubject.send(...)`.

None of these domains are synchronized. The `queue` only governs CoreBluetooth callback delivery, not the class's own mutable state.

---

### 2. `PeripheralManager.swift` — `queue.sync` Single-Producer Verification

#### Call-Site Trace

| Method | Called From | Calling Thread | Sync Mechanism |
|---|---|---|---|
| `discoveredPeripheral(_:advertisementData:rssi:)` :49 | `BluetoothManager.centralManager(_:didDiscover:...)` :239 | `BluetoothManager.queue` dispatch queue | `queue.sync` :52 |
| `invalidatePeripherals()` :74 | `BluetoothManager.centralManagerDidUpdateState` :219 | `BluetoothManager.queue` dispatch queue | `queue.sync` :75 |
| `refreshPeripherals(using:)` :81 | `BluetoothManager.centralManagerDidUpdateState` :213 | `BluetoothManager.queue` dispatch queue | `queue.sync` :82 |

All three call sites originate from `BluetoothManager`'s `queue`, which is a **different** dispatch queue than `PeripheralManager`'s `queue`. So the pattern is:
```
BluetoothManager.queue (dispatch)
  → calls PeripheralManager.discoveredPeripheral(...)
    → PeripheralManager.queue.sync { ... }
```

This means the calling thread (BluetoothManager's queue) **blocks** waiting for PeripheralManager's queue to execute the block. The `queue.sync` provides actual thread-safety regardless of who calls it — it's not merely "safe by coincidence." If any other thread called these methods, `queue.sync` would still serialize access.

#### `discoveredPeripheralsSubject.send(...)` Under the Lock

All three methods call `discoveredPeripheralsSubject.send(discoveredPeripherals)` **inside** the `queue.sync` block (:62, :69, :78, :90, :99). This is correct: the array snapshot is captured while holding the queue, so subscribers receive a consistent `[Peripheral]`.

However, **`PassthroughSubject.send(...)` synchronously invokes downstream subscribers** on the calling thread (unless a `.receive(on:)` operator is in the pipeline). This means PeripheralManager's queue thread runs subscriber closures:
- If a subscriber does `.receive(on: DispatchQueue.main)`, the actual work hops to main → fine.
- If a subscriber does **not** specify a scheduler, it runs on PeripheralManager's queue thread. Heavy work in the subscriber (e.g., SwiftData operations, as the Demo does) would **block the PeripheralManager queue**, delaying subsequent discovery processing.
- Under Swift 6, if the subscriber closure is actor-isolated (e.g., `@MainActor`), the compiler will flag this because `PassthroughSubject` is non-Sendable and the closure crosses isolation boundaries.

#### Risks with `@unchecked Sendable`

`PeripheralManager` is `@unchecked Sendable` (:38). This tells the compiler "trust me, I'm thread-safe." However:
- `discoveredPeripheralsSubject` is a non-Sendable `PassthroughSubject` stored as a property. The compiler accepts this because of `@unchecked Sendable`, but Swift 6 strict mode may still warn about non-Sendable stored properties in Sendable types.
- `discoveredPeripherals` array is non-Sendable (contains `Peripheral` which is `@unchecked Sendable` — itself problematic, see §3). Protected by `queue.sync`, so runtime safe but type-level unsafe.

---

### 3. `Peripheral.swift` — Locking Audit & Sendable Violations

#### Lock Coverage Matrix

| Property | Backing | Getter Line | Getter Locks? | Setter Line | Setter Locks? | Comment |
|---|---|---|---|---|---|---|
| `id` | `let id: String` | 56 | N/A (immutable) | init | N/A | Fine |
| `peripheral` | `_peripheral` | 73 | **Yes** | `update` :128, `invalidate` :142, init :118 | **Yes** | OK |
| `rssi` | `_rssi` | 91 | **Yes** | `update` :130, init :119 | **Yes** | OK |
| `advertisementData` | `_advertisementData` | 99 | **Yes** | `update` :129, init :120 | **Yes** | OK |
| `lastSeen` | `_lastSeen` | 108 | **Yes** | `update` :133, init :123 | **Yes** | OK |
| `peripheralIdentifier` | computed | 63 | **Indirect** (via `peripheral` getter) | — | — | Lock released before `.identifier` read |
| `name` | computed | 79 | **Indirect** (via `peripheral` + `advertisementData` getters) | — | — | Two separate lock acquisitions |
| `serviceUUIDs` | computed | 84 | **Indirect** (via `advertisementData` getter) | — | — | Lock released before dictionary subscript |

#### `peripheralIdentifier` — Double-Lock / Race Analysis

:63: `peripheral?.identifier` — calls `peripheral` getter (:73), which locks, returns `_peripheral`, unlocks. Then `.identifier` is read on the **now-unlocked** `CBPeripheral` reference. Is this a race?

- `CBPeripheral.identifier` is a `UUID` property that is stable for the lifetime of the `CBPeripheral` object.
- The `CBPeripheral` reference is kept alive by ARC even if `invalidateCBPeripheral()` concurrently sets `_peripheral = nil` — the already-returned reference is independently retained.
- **Verdict**: No race on the identifier value itself. The comment "No lock needed here since this is a computed property that accesses `peripheral` which already handles its own synchronization" is **misleading** — it *does* acquire the lock (indirectly), then reads the identifier outside it. But the read is safe because `CBPeripheral.identifier` is monotonic/immutable.

#### `name` — Two Separate Lock Acquisitions

:79: `peripheral?.name ?? advertisementData?[CBAdvertisementDataLocalNameKey] as? String`

This acquires the `mutationLock` **twice**: once in `peripheral` getter, once in `advertisementData` getter. Between the two acquisitions:
- `peripheral` could be invalidated (set to nil) by `invalidateCBPeripheral()` on another thread — but the returned reference is independently retained, so `?.name` is safe.
- `advertisementData` could be replaced by `update()` on another thread — but the returned dictionary is independently retained, so the subscript is safe.
- **Verdict**: Functionally safe but inefficient. The two separate lock acquires mean the combined read is not atomic — `peripheral?.name` and `advertisementData?[...]` could reflect different states of the object.

#### Sendable Violations (Type-Level)

`Peripheral` is `@unchecked Sendable` (:42). The following publicly exposed types violate Sendable:

1. **`advertisementData: [String: Any]?`** (:99) — `[String: Any]` is fundamentally non-Sendable (`Any` can contain non-Sendable values). Exposing this in a `@unchecked Sendable` type means callers can extract non-Sendable data across actor boundaries under a false Sendable promise.

2. **`peripheral: CBPeripheral?`** (:73) — `CBPeripheral` is not `Sendable`. The getter returns the raw CoreBluetooth object. If a consumer on `@MainActor` holds a reference while a `BluetoothManager.queue` callback invalidates it, the consumer has a dangling but ARC-retained `CBPeripheral` — not a crash, but semantically stale.

3. **`serviceUUIDs: [CBUUID]?`** (:84) — `CBUUID` is a CoreBluetooth reference type, unlikely to be `Sendable`. The array of `CBUUID` objects extracted from the advertisement dictionary carries the same non-Sendable risk.

#### `hash(into:)` and `==`

- `hash(into:)` :147 is `nonisolated` and only accesses `id` (immutable `let String`). Safe.
- `==` :152 only compares `lhs.id == rhs.id`. Safe.

---

### 4. `ReliaBLEManager.swift` — Cross-Actor Sharing Risk Analysis

#### Type-Level Posture

- **Non-`final` class** (:43) — can be subclassed. Subclass could add mutable state unprotected.
- **No `Sendable` conformance** — under `-strict-concurrency=complete`, passing a `ReliaBLEManager` instance between actors/domains produces a warning.
- **No actor isolation** — not `@MainActor`, not a `@globalActor`, not an `actor`. Executes on the caller's context.

#### Effective Concurrency Contract of Each Public Member

| Member | Line | Caller Thread | Thread-Safety Mechanism | Cross-Actor Risk |
|---|---|---|---|---|
| `init(config:)` | 56 | Caller's thread | None needed (creates child objects) | Creates `BluetoothManager` which can start `CBCentralManager` — see §1 |
| `loggingService` | 45 | Caller's thread | `LoggingService` is `Sendable` | `enabled` setter on Willow's non-Sendable `Logger` races if toggled from two actors |
| `state` | 63 | Caller's thread | Returns non-Sendable `AnyPublisher` | Subscribers on different actors get warnings |
| `currentState` | 68 | Caller's thread | Reads `CurrentValueSubject.value` — see §1 | May race with `send` from delegate queue |
| `authorizeBluetooth()` | 76 | Caller's thread | Delegates to `BluetoothManager.authorize()` — see §1 | Race with delegate callbacks |
| `peripheralDiscoveries` | 82 | Caller's thread | Returns non-Sendable `AnyPublisher` | Same as `state` |
| `discoveredPeripherals` | 87 | Caller's thread | Returns non-Sendable `AnyPublisher` | Same as above; `[Peripheral]` elements are `@unchecked Sendable` — see §3 |
| `startScanning(services:)` | 97 | Caller's thread | Delegates to `BluetoothManager.startScanning` — see §1 | All the §1 races |
| `stopScanning()` | 102 | Caller's thread | Delegates to `BluetoothManager.stopScanning` — see §1 | All the §1 races |

#### Cross-Actor Sharing Scenario

Consider the Demo's pattern:
- `ReliaBLE_DemoApp` (:65) creates a `ReliaBLEManager` on `@MainActor` (SwiftUI `App` is `@MainActor`).
- The instance is injected into `CentralViewModel` (an `@Observable` class, `@MainActor`-isolated by SwiftUI convention).
- All usage is from `@MainActor` — **currently no cross-actor sharing**.

But if a hypothetical consumer:
1. Creates `ReliaBLEManager` on `@MainActor` (SwiftUI)
2. Passes it to a background `actor` for off-main work

Then:
- **Compiler**: warns that non-Sendable `ReliaBLEManager` crosses actor boundary (unless `@preconcurrency import ReliaBLE`)
- **Runtime races**:
  - Actor A calls `startScanning()` while Actor B calls `authorizeBluetooth()` — both touch `BluetoothManager.centralManager` unsynchronized :41
  - Actor A reads `currentState` while delegate callback on `queue` calls `updateState()` → `stateSubject.send(...)` — **data race** on CurrentValueSubject internal state
  - Subscriber on Actor A's Combine pipeline receives from the delegate queue's `PassthroughSubject.send(...)` — **three-domain fan-out** (caller actor, delegate queue, subscriber actor)

#### `loggingService` Public Exposure Risk

:45: `public let loggingService: LoggingService` — while `LoggingService` is `Sendable`, it wraps Willow's non-Sendable `Logger`. The `enabled` property (:43 in LoggingService.swift) reads/writes `willowLogger.enabled` without synchronization. Two actors toggling `enabled` simultaneously on the same instance would race on Willow's internal state.

---

### 5. Mock Target Parity — `CoreBluetoothMockAliases.swift`

#### Typealias Coverage

All CoreBluetooth types used by the library have corresponding `CBM*` mock typealiases (lines 41–69):
- `CBCentralManager` → `CBMCentralManager` (:48)
- `CBCentralManagerDelegate` → `CBMCentralManagerDelegate` (:49)
- `CBPeripheral` → `CBMPeripheral` (:50)
- `CBUUID` → `CBMUUID` (:43)
- `CBCentralManagerFactory` → `CBMCentralManagerFactory` (:42)
- All `CBManagerState`, `CBPeripheralState`, `CBError`, `CBATTError`, advertisement data keys, connection options, etc.

#### Compatibility with Actor-Based Refactor

If the library moves to an `actor`-based design:

1. **`CBCentralManagerFactory.instance(...)`** — the mock factory (`CBMCentralManagerFactory`) must accept the same `(delegate:queue:options:forceMock:)` signature. The mock factory typealiased at :42 presumably does. **No issue expected**.

2. **Delegate = Actor** — If the `BluetoothManager` becomes a `@globalActor` or `actor`, the delegate must be `nonisolated` to conform to `CBCentralManagerDelegate` (an `NSObjectProtocol`). The shim pattern (a small `NSObject` that forwards callbacks into the actor via `Task { @BluetoothActor in ... }`) works identically with both real and mock `CBCentralManager`. **No issue expected**.

3. **`CBPeripheral` → `CBMPeripheral` typealias** — If `Peripheral` is replaced with a `Sendable` struct snapshot (as recommended by best practices), the internal reference to `CBPeripheral` goes away, and the typealias becomes irrelevant for that data path. The struct would hold a `UUID` identifier instead of a reference. **No issue expected**.

4. **`AsyncStream` over Combine** — The mock target doesn't use Combine subjects directly; it swaps the delegate and factory. Switching to `AsyncStream` for event delivery removes the non-Sendable `AnyPublisher` problem from the public API. The mock's `simulatePeripheral(...)` / `simulateStateChange(...)` APIs would still drive the same delegate callbacks, which flow into `AsyncStream.Continuation.yield(...)`. **No issue expected**.

5. **Subtlety: `CBMPeripheral.identifier`** — In CoreBluetoothMock, `CBMPeripheral.identifier` returns a mock-generated UUID. This is the same shape as the real `CBPeripheral.identifier`. If the refactor stores UUIDs instead of `CBPeripheral` references, mock and real paths remain consistent. **No issue expected**.

6. **Subtlety: `retrievePeripherals(withIdentifiers:)`** — Called in `PeripheralManager.refreshPeripherals` :82. `CBMCentralManager` provides `retrievePeripherals(withIdentifiers:)` that returns mock `CBMPeripheral` instances. This works identically to the real path. **No issue expected**.

#### Verdict

The three-target SPM trick and `CoreBluetoothMock` integration are **fully compatible** with any of the three modernization patterns (global actor + shim, custom serial executor, or AsyncStream). No mock surface adjustments needed.

---

### 6. Public API Shape Changes — Modernization Impact Catalog

#### `ReliaBLEManager` — Members and Modernization Effect

| Member | Current Signature | Modernized Signature | Breaking? |
|---|---|---|---|
| `init(config:)` | `public init(config: ReliaBLEConfig = ReliaBLEConfig())` | Same (class) or `public init(config:)` (actor) | **No** |
| `state` | `public var state: AnyPublisher<BluetoothState, Never>` | `public var state: AsyncStream<BluetoothState>` or `AsyncPublisher` | **BREAKING** — Combine → concurrency |
| `currentState` | `public var currentState: BluetoothState` | `public var currentState: BluetoothState` (if actor, requires `await` to read) | **BREAKING** — synchronous → async |
| `authorizeBluetooth()` | `public func authorizeBluetooth() throws` | `public func authorizeBluetooth() async throws` (if actor) | **BREAKING** — synchronous → async |
| `peripheralDiscoveries` | `public var peripheralDiscoveries: AnyPublisher<PeripheralDiscoveryEvent, Never>` | `public var peripheralDiscoveries: AsyncStream<PeripheralDiscoveryEvent>` | **BREAKING** — Combine → concurrency |
| `discoveredPeripherals` | `public var discoveredPeripherals: AnyPublisher<[Peripheral], Never>` | `public var discoveredPeripherals: AsyncStream<[Peripheral]>` | **BREAKING** — Combine → concurrency + `Peripheral` type change |
| `startScanning(services:)` | `public func startScanning(services: [CBUUID]?)` | Same (or `async` if actor) | **Potentially BREAKING** if `async` |
| `stopScanning()` | `public func stopScanning()` | Same (or `async` if actor) | **Potentially BREAKING** if `async` |
| `loggingService` | `public let loggingService: LoggingService` | Same | **No** (but `enabled` race risk — see §4) |

#### Exposed Types — Sendable Audit for Modernization

| Type | Location | Currently Sendable? | Must Change? |
|---|---|---|---|
| `BluetoothState` | `BluetoothManager.swift:249` | `Sendable` enum | **No change needed** |
| `AuthorizationStatus` | `BluetoothManager.swift:252` (typealias) | `CBManagerAuthorization` — platform Sendable status unknown | **May need explicit `@retroactive Sendable`** |
| `AuthorizationError` | `BluetoothManager.swift:300` | Implicitly `Sendable` (no reference-type associated values) | **No change needed** |
| `PeripheralDiscoveryEvent` | `PeripheralDiscoveryEvent.swift:32` | `struct` with `[String: Any]` → **NOT Sendable** | **Must change** — remove `[String: Any]` or make it a `[String: Sendable]`; expose extracted fields |
| `Peripheral` | `Peripheral.swift:42` | `@unchecked Sendable` class with non-Sendable members | **Must change** — replace with `Sendable` struct snapshot |
| `ReliaBLEConfig` | `ReliaBLEConfig.swift:33` | `struct` with `[LogWriter]` (non-Sendable protocol type) and `DispatchQueue` | **Must change** — needs `Sendable` conformance or `@preconcurrency` |
| `LoggingService` | `LoggingService.swift:35` | `Sendable` class wrapping non-Sendable Willow `Logger` | **Fragile** — relies on `@preconcurrency import Willow` |
| `LogTag` | `LogMessage.swift:22` | Enum with `String` associated values | **Needs explicit `Sendable`** conformance |
| `LogMessage` | `LogMessage.swift:60` | Struct with `[String: Any]` in `attributes` → **NOT Sendable** | **Must change** — `[String: Any]` is non-Sendable |
| `LogLevel` | `ReliaBLEConfig.swift:32` (typealias) | Non-Sendable Willow type | **Needs `@preconcurrency` at use sites** |
| `LogWriter`, `LogModifier`, `LogModifierWriter`, `ConsoleWriter`, `OSLogWriter` | Various typealiases | Non-Sendable Willow types | **Needs `@preconcurrency` at use sites** |
| `AnyPublisher<BluetoothState, Never>` | Return type | **NOT Sendable** | **Must change** to `AsyncStream` / `AsyncSequence` |
| `AnyPublisher<PeripheralDiscoveryEvent, Never>` | Return type | **NOT Sendable** | **Must change** |
| `AnyPublisher<[Peripheral], Never>` | Return type | **NOT Sendable** | **Must change** |

#### Demo API Usage — What Actually Depends on the Public Surface

From `CentralViewModel.swift` (:51–139) and `ReliaBLE_DemoApp.swift` (:41–71):

| API Used | How Used | Modernization Impact |
|---|---|---|
| `ReliaBLEManager(config:)` init | SwiftUI `@main App` property | Minimal |
| `.state` publisher | `.receive(on: DispatchQueue.main).assign(to: \.currentState, on: self)` in an `@Observable` class | Combine pipeline → must adapt to `for await` or `AsyncStream` |
| `.peripheralDiscoveries` publisher | `.receive(on: DispatchQueue.main).sink { ... }` → SwiftData insert | Combine pipeline → must adapt |
| `.discoveredPeripherals` publisher | `.receive(on: DispatchQueue.main).sink { ... }` → SwiftData fetch/upsert | Combine pipeline → must adapt; access to `Peripheral.id`, `.name`, `.lastSeen` |
| `.authorizeBluetooth()` | `try?` synchronous call from `@MainActor` view model method | If becomes `async throws`, call site needs `Task { try? await ... }` |
| `.startScanning(services:)` | Direct call from `@MainActor` | Same as above |
| `.stopScanning()` | Direct call from `@MainActor` | Same as above |
| `Peripheral.id` | String comparison for device matching | Preserved if `Sendable` struct retains `id: String` |
| `Peripheral.name` | Display and model update | Preserved if `Sendable` struct retains `name: String?` |
| `Peripheral.lastSeen` | Model update | Preserved if `Sendable` struct retains `lastSeen: Date?` |

The Demo depends on 3 Combine publishers, 3 synchronous methods, and 3 `Peripheral` properties. All would need adaptation if the library modernizes — but the library is **greenfield (pre-1.0)** with a single consuming app (Demo), so breaking changes are acceptable per the audit's charter.

---

### 7. Additional Findings — Logging Layer & Config

#### `LoggingService` :35 — `Sendable` But Internal Dependency is Not

`LoggingService` is `final class` and `Sendable` but wraps `willowLogger: Logger` (:38) — Willow's `Logger` is **not Sendable** (confirmed via upstream source probe). The `@preconcurrency import Willow` at `ReliaBLEManager.swift:41` suppresses the compiler warning for this usage. Under `-strict-concurrency=complete` without `@preconcurrency`, this would **fail to compile**.

Additionally, `enabled` (:43) is a mutable `Bool` setter that writes to `willowLogger.enabled` — concurrent writes from two actors to the same `LoggingService` instance would race on Willow's internal non-Sendable `Logger`.

#### `ReliaBLEConfig` :33 — Non-Sendable Struct Passed Across Actor Boundaries

`ReliaBLEConfig` is passed to `ReliaBLEManager.init(config:)`. If `ReliaBLEManager` becomes an actor or is created on a background actor from a `@MainActor` context, the config struct must cross actor boundaries. But:
- `logWriters: [LogWriter]` — `LogWriter` is a Willow protocol, non-Sendable.
- `logQueue: DispatchQueue` — `DispatchQueue` is `Sendable`, fine.
- `logLevels: LogLevel` — Willow type, non-Sendable.

The struct would need `Sendable` conformance (or `@preconcurrency` suppression) to cross actor boundaries.

#### `OSLogWriter` :53 (LogWriters.swift) — Class Type Not Sendable

`OSLogWriter` stores an `os.OSLog` (:65) which is a C-backed object — not Sendable-annotated in the OSLog framework. For `ReliaBLEConfig` to be `Sendable`, `OSLogWriter` would need to be `@unchecked Sendable` or the `logWriters` array would need `@preconcurrency` treatment.

#### `LogMessage` :60 — `[String: Any]` in `attributes` Property

The `attributes` computed property returns `[String: Any]` — non-Sendable. This is passed to Willow's `Logger` methods as part of the `LogMessage` protocol conformance. Since Willow's `Logger` doesn't require `Sendable` log messages, this works currently, but the type itself can't be `Sendable`.

#### `PeripheralDiscoveryEvent` :32 — Non-Sendable `[String: Any]` Stored Property

`PeripheralDiscoveryEvent` is a `public struct` that stores `advertisementData: [String: Any]` (:49). Under `-strict-concurrency=complete`:
- The struct cannot be `Sendable` because it stores a non-Sendable value.
- It is sent through `PassthroughSubject<PeripheralDiscoveryEvent, Never>` — the subject is non-Sendable, and the element type being non-Sendable compounds the issue.
- For `AsyncStream<PeripheralDiscoveryEvent>`, the element type would need to be `Sendable` — requiring `advertisementData` to be removed or replaced with a `Sendable` representation (e.g., `[String: String]` for known keys, or wrapped in a `@unchecked Sendable` box).

#### `testFunction()` :106 (ReliaBLEManager.swift) — Dead Code in Public Surface

`func testFunction() -> String` is `internal` (no `public` modifier) so it's not part of the public API — but it's dead code in the production target. Harmless for concurrency but should be cleaned up.

## Investigation Log

**Phase 1 — Triage.** Read all three target files plus surrounding context
(`Peripheral.swift`, `PeripheralDiscoveryEvent.swift`, `LoggingService.swift`,
`ReliaBLEConfig.swift`, `CBCentralManagerFactory.swift`, `Package.swift`,
`CoreBluetoothMockAliases.swift`). Captured initial symptoms in this report.

**Phase 1.5 — External research.** Dispatched an explore agent to survey
WWDC24/25 Swift 6 + CoreBluetooth guidance, modern AsyncSequence / Observation
patterns, and comparable open-source BLE libraries. Findings recorded in
`## Background / Prior Research` above.

**Phase 2 — Context Builder.** Seeded the file selection with all relevant
production sources, mock-target shim, logging stack, and codemaps for Demo +
mock parallels. Initial oracle pass identified the same root-cause cluster
captured in this report's `## Symptoms` section.

**Phase 3 — Pair Investigator.** Detailed file:line-anchored audit appended
under `## Investigator Findings` (§§1–7). Covered: mutable state inventory in
`BluetoothManager`, three-domain race analysis, `queue.sync` cross-queue
serialization verification in `PeripheralManager`, lock-coverage matrix for
`Peripheral`, cross-actor sharing scenarios for `ReliaBLEManager`, mock-target
compatibility checks, public API impact catalogue, and logging-layer Sendable
audit.

**Phase 4 — Oracle Synthesis.** Two rounds. Round 1 produced an
architecture/migration sketch. Round 2 sharpened three design decisions:
(a) `ReliaBLEManager` should be nonisolated `Sendable`, not `@MainActor`, to
honor the "main actor not required" constraint; (b) multi-subscriber
`AsyncStream` events implemented via an in-actor broadcaster, not external
dependencies; (c) stale-`Peripheral`-handle operations should throw an
explicit error rather than auto-rescan or return optional.

**Phase 5 — Post-audit revision (Willow 7.0 integration).** Maintainer
flagged that commit `3657f45` in this repo had already pulled in Willow 7.0
(Swift 6 / strict-concurrency clean upstream) and removed every
`@preconcurrency import Willow`. Verified by fetching the upstream Willow
source at the pinned revision (`beeaf007a6` on `itsniper/Willow main`):
`Logger: @unchecked Sendable` with documented invariant; all public
protocols (`LogMessage`, `LogWriter`, `LogModifierWriter`, `LogModifier`,
`LogFilter`, `LogLevel`, `LogSource`) refine `Sendable`; closure parameters
on `Logger`'s logging APIs carry `@Sendable`. ReliaBLE's local source
changes in `7476f48`: `@preconcurrency` removed from 5 files,
`LogMessage.attributes: [String: Any]` → `[String: any Sendable]`,
`LogTag`/`LogTag.Category` marked `Sendable`, `OSLogWriter` declared
`final`. Revised: Cluster 4 in Root Cause, Recommendation §C, and the
migration order — Step 1 "Drop Willow" is removed; remaining logging work
is small polish (explicit `Sendable` on `ReliaBLEConfig`, verification
that `OSLogWriter` synthesizes `Sendable` under strict mode, DocC note on
the inherited `enabled` race). Clusters 1–3 and the rest of the
architecture recommendations are unchanged.

---

## Root Cause / Findings

The library has **three Swift 6 concurrency issue clusters**, not one. They
must be fixed together because they are mutually reinforcing — fixing one
without the others would leave the rest as `@unchecked Sendable` papering or
`@preconcurrency` import escape hatches.

### Cluster 1 — Unsynchronized BLE state (`BluetoothManager`)
`centralManager`, `stateSubject`, and `discoverySubject` are touched from
**three concurrency domains** with no synchronization:
- Caller's thread (`init`, `authorize`, `startScanning`, `stopScanning`, and
  their `updateState()` calls) — `BluetoothManager.swift:65, 137, 155, 179, 93`.
- The private `queue` `DispatchQueue` — all `CBCentralManagerDelegate`
  callbacks — `BluetoothManager.swift:206, 226`.
- Combine subscribers' threads — anywhere a downstream `.sink` runs.

`updateState()` reads `centralManager?.state` and `centralManager?.isScanning`
from the caller thread (`BluetoothManager.swift:108, 113, 170, 195`), which
**violates CoreBluetooth's documented queue-affinity contract** (these
properties must be read on the delegate queue). The private `queue` exists
only to receive delegate callbacks; it is never used to protect
`BluetoothManager`'s own mutable state.

### Cluster 2 — Non-`Sendable` event surface (Combine in the public API)
Every public event surface returns `AnyPublisher<…, Never>` which is **not
`Sendable` in Swift 6** (`ReliaBLEManager.swift:63, 82, 87`). The backing
`PassthroughSubject` / `CurrentValueSubject` instances are stored as
non-`Sendable` properties of types that are not actor-isolated. This is the
single biggest blocker to honest `Sendable` conformance: even if we fix
Cluster 1 with an actor, the public surface still leaks non-Sendable Combine
types.

`PeripheralDiscoveryEvent` cannot itself be `Sendable` because it stores
`advertisementData: [String: Any]` (`PeripheralDiscoveryEvent.swift:49`).

### Cluster 3 — `@unchecked Sendable` data classes with foreign types
`Peripheral` (`Peripheral.swift:42`) and `PeripheralManager`
(`PeripheralManager.swift:30`) both use `@unchecked Sendable` to silence the
compiler while exposing non-Sendable types:
- `Peripheral.peripheral: CBPeripheral?` — `CBPeripheral` is not `Sendable`.
- `Peripheral.advertisementData: [String: Any]?` — `[String: Any]` is not
  `Sendable`.
- `Peripheral.serviceUUIDs: [CBUUID]?` — `CBUUID` is a foreign reference type
  with no `Sendable` annotation.

`PeripheralManager`'s `queue.sync` does provide real serialization (the pair
verified this — it's not "lucky single-producer"), but the type is still
storing a non-`Sendable` `PassthroughSubject`. `Peripheral`'s manual `NSLock`
gives runtime safety per-property but not atomicity across reads (the `name`
getter acquires the lock twice; nothing prevents another writer interleaving
between the two reads). The comments in `Peripheral.swift` claiming "no lock
needed here" on certain computed properties are **misleading** — those
properties do acquire the lock indirectly via other getters.

### Cluster 4 (subordinate) — Logging stack pinned to non-`Sendable` Willow
*(Resolved by commit `3657f45` — Willow 7.0 upgrade.)*

**Historical framing (pre-Willow-7.0):** `LoggingService` was `Sendable` but
wrapped Willow's `Logger`, which was not `Sendable` upstream. Every
`import Willow` in the library carried `@preconcurrency`. `LogMessage.attributes:
[String: Any]` blocked `Sendable` conformance. `OSLogWriter` wrapped `os.OSLog`
without `Sendable` annotation. `ReliaBLEConfig` transitively held non-`Sendable`
Willow types.

**Current state (post-Willow-7.0):** Willow 7.0 makes `Logger: @unchecked
Sendable` (with documented `ExecutionMethod.perform()` invariant), and refines
`LogMessage`, `LogWriter`, `LogModifierWriter`, `LogModifier`, `LogFilter`,
`LogLevel`, and `LogSource` to `Sendable`. The repo's `3657f45` merge removed
every `@preconcurrency import Willow`, updated `LogMessage.attributes` to
`[String: any Sendable]`, made `OSLogWriter` `final`, and added `Sendable` to
`LogTag`/`LogTag.Category`. Only three nits remain:

1. **`LoggingService.enabled` is a racy `Bool`** (`LoggingService.swift:43`).
   This is *deliberately* inherited from Willow's upstream design — Willow 7.0
   documents the `Logger.enabled` race as out-of-scope for its Sendable
   migration. ReliaBLE mirrors that choice. Two actors toggling
   `loggingService.enabled` concurrently is a benign race (last write wins,
   reads may briefly observe stale value). **Recommendation: document the
   behavior in DocC and move on** — or move `enabled` inside `BluetoothActor`
   if a stricter contract is desired.
2. **`OSLogWriter` (`LogWriters.swift:47`)** is declared `public final class
   OSLogWriter: LogModifierWriter` without an explicit `Sendable` conformance.
   Since `LogModifierWriter` now refines `Sendable`, the compiler will
   synthesize conformance if all stored properties (`subsystem: String`,
   `category: String`, `modifiers: [LogModifier]`, `log: OSLog`) are `Sendable`.
   `OSLog` *is* `Sendable` on iOS 16+ (Apple annotated it in the SDK), so
   synthesis succeeds. **Verify with a clean build under
   `-strict-concurrency=complete`;** if Apple ever rolls back `OSLog`'s
   `Sendable`, add `@unchecked Sendable` (matches upstream `Willow.OSLogWriter`).
3. **`ReliaBLEConfig` (`ReliaBLEConfig.swift:33`)** doesn't have an explicit
   `Sendable` conformance. All its members are now `Sendable` (`LogLevel`,
   `[LogWriter]`, `DispatchQueue`, `Bool`), so the compiler synthesizes
   `Sendable` for the public struct, but explicit conformance is preferable
   for a public API surface — **add `public struct ReliaBLEConfig: Sendable`**.

### Architectural conclusion

These four clusters cannot be fixed incrementally without producing a worse
intermediate state. The audit recommends a single coordinated rewrite of the
core, sequenced to keep the build green at each step (see Recommendations,
Migration Order).

---

## Recommendations

### Chosen architecture

**Global actor + delegate shim + AsyncStream broadcaster + nonisolated
`Sendable` façade.**

This is the right shape for a greenfield iOS 18+ Swift 6.1 BLE library. It
yields true compile-time isolation, eliminates every `@unchecked Sendable`,
removes Combine from the public surface, and — critically — works equally
well from `@MainActor` SwiftUI code and from background actors, with no
forced MainActor hop.

#### Isolation graph

| Component | Isolation | Responsibility |
|---|---|---|
| `@globalActor BluetoothActor` | global actor | Owns `CBCentralManager`, peripheral registry, scanning state, all delegate callbacks. Single source of truth. |
| `BluetoothDelegateShim` | `nonisolated final class : NSObject` | Adopts `CBCentralManagerDelegate`. Each callback hops to `BluetoothActor` via `Task { @BluetoothActor in … }`. |
| `ReliaBLEManager` | **nonisolated** `final class`, `Sendable` | Thin public façade. Forwards `async` calls to `BluetoothActor.shared`. Exposes `AsyncStream` event surfaces. |
| `Peripheral` | `struct`, `Sendable` | Pure-value snapshot. No `CBPeripheral` reference. |
| `LoggingService` | `final class`, `Sendable` | Wraps `os.Logger` directly (Willow dropped). |

Why nonisolated `ReliaBLEManager` and **not** `@MainActor` / `@Observable`:
the user's brief explicitly states main-actor access must be supported but
not required. A `@MainActor` façade would force every background-actor
caller to hop MainActor → BluetoothActor for every call — defeating the
purpose. SwiftUI consumers integrate via `.task { for await … }`, which is
the idiomatic iOS 18 pattern; observation/`@Observable` integration belongs
in *consumer* view-models, not the library.

#### Delegate shim (code shape)

```swift
@globalActor
public actor BluetoothActor {
    public static let shared = BluetoothActor()
}

final class BluetoothDelegateShim: NSObject, CBCentralManagerDelegate {
    nonisolated let onStateUpdate:    @Sendable (CBCentralManager) -> Void
    nonisolated let onDiscover:       @Sendable (CBPeripheral, [String: Any], NSNumber) -> Void
    // ...

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onStateUpdate(central)
    }
    nonisolated func centralManager(_ c: CBCentralManager,
                                    didDiscover p: CBPeripheral,
                                    advertisementData ad: [String: Any],
                                    rssi: NSNumber) {
        onDiscover(p, ad, rssi)
    }
}
```

The shim's callbacks capture `@Sendable` closures that immediately
`Task { @BluetoothActor in … }` into the actor's internal handlers. The
shim itself owns no state and is `nonisolated final class`. Its closures
are constructed by the actor and capture an unowned/weak reference to it
to avoid retain cycles.

#### AsyncStream broadcaster (in-actor)

Each event surface (`state`, `peripheralDiscoveries`, `discoveredPeripherals`)
is implemented via a tiny **in-actor broadcaster**:

```swift
extension BluetoothActor {
    // Stored as actor state:
    var stateContinuations: [UUID: AsyncStream<BluetoothState>.Continuation] = [:]
    var currentBluetoothState: BluetoothState = .unknown

    nonisolated func stateStream() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { @BluetoothActor in
                continuation.yield(currentBluetoothState)         // replay snapshot
                stateContinuations[id] = continuation
                continuation.onTermination = { _ in
                    Task { @BluetoothActor in stateContinuations[id] = nil }
                }
            }
        }
    }

    func broadcastState(_ new: BluetoothState) {
        currentBluetoothState = new
        for c in stateContinuations.values { c.yield(new) }
    }
}
```

Each subscriber gets its own `AsyncStream` instance with replay of the
latest snapshot. No external dependencies. The same pattern handles
`peripheralDiscoveries` (no replay — pure event stream) and
`discoveredPeripherals` (replay with current list). Volume on all three is
low (BLE advertisement rate is bounded by iOS at single-digit Hz).

#### `Peripheral` redesign (value type, no `CBPeripheral`)

```swift
public struct Peripheral: Sendable, Identifiable, Hashable {
    public let id: String                  // app-supplied or CB UUID string
    public let cbIdentifier: UUID?         // CB's own identifier (for retrieval)
    public let name: String?
    public let rssi: Int?
    public let lastSeen: Date?
    public let advertisement: AdvertisementData
}

public struct AdvertisementData: Sendable, Hashable {
    public let localName: String?
    public let serviceUUIDs: [CBUUID]      // CBUUID is value-like; mark @retroactive Sendable in an extension
    public let manufacturerData: Data?
    public let txPowerLevel: Int?
    public let isConnectable: Bool?
    public let serviceData: [CBUUID: Data]
    public let overflowServiceUUIDs: [CBUUID]
    public let solicitedServiceUUIDs: [CBUUID]
}
```

`[String: Any]` is removed from the public surface entirely. The actor
performs the known-key extraction once at discovery time. The mutable
`CBPeripheral` reference stays **inside** `BluetoothActor` (in a
`[String: CBPeripheral]` registry), and never escapes.

> **Open question — unknown advertisement keys.** Some integrators will need
> access to manufacturer-specific or vendor-extension fields that the
> strongly-typed `AdvertisementData` doesn't enumerate. **Decision deferred
> to deeper planning before implementation** (see the sub-issue for Step 2).
> Candidate approaches:
> 1. Add `rawAdvertisement: [String: any Sendable]` as a secondary,
>    explicitly-typed escape hatch on `AdvertisementData` — preserves the
>    typed surface for known keys while exposing the long tail.
> 2. Provide a `manufacturerData(forCompanyID:)` -style accessor that does
>    typed parsing of the well-known unstructured fields.
> 3. Keep `[String: any Sendable]` as the *only* surface and drop the
>    typed-helper struct.
> Recommend #1 (typed convenience + raw escape hatch); finalize during
> implementation.

Operations against a peripheral go through the manager by id:

```swift
public func connect(to peripheral: Peripheral) async throws { ... }
public func disconnect(_ peripheral: Peripheral) async throws { ... }
```

If the integrating app holds a stale `Peripheral` snapshot whose id is no
longer in the actor's registry (e.g. after a Bluetooth power-cycle
invalidation), the operation throws an explicit `PeripheralError.notFound`.
Rationale: the caller already knows the stable `id`, so explicit failure
makes the contract obvious; auto-rescanning would hide stale-snapshot
issues, and returning `nil`/optional pushes nil-handling onto every call
site.

#### `ReliaBLEManager` façade (nonisolated, Sendable)

```swift
public final class ReliaBLEManager: Sendable {
    public let loggingService: LoggingService

    public init(config: ReliaBLEConfig = .init()) {
        loggingService = LoggingService(config: config)
        Task { @BluetoothActor in
            await BluetoothActor.shared.configure(logging: loggingService)
        }
    }

    // Event surfaces (each call returns a fresh subscriber stream)
    public var state:                AsyncStream<BluetoothState>            { BluetoothActor.shared.stateStream() }
    public var peripheralDiscoveries: AsyncStream<PeripheralDiscoveryEvent> { BluetoothActor.shared.discoveryStream() }
    public var discoveredPeripherals: AsyncStream<[Peripheral]>             { BluetoothActor.shared.peripheralsStream() }

    // Snapshot reads
    public var currentState: BluetoothState {
        get async { await BluetoothActor.shared.currentBluetoothState }
    }

    // Actions
    public func authorizeBluetooth()                     async throws { try await BluetoothActor.shared.authorize() }
    public func startScanning(services: [CBUUID]? = nil) async         { await BluetoothActor.shared.startScanning(services: services) }
    public func stopScanning()                           async         { await BluetoothActor.shared.stopScanning() }
    public func connect(to peripheral: Peripheral)       async throws { try await BluetoothActor.shared.connect(id: peripheral.id) }
}
```

A SwiftUI consumer typically wraps this in their own `@Observable @MainActor`
view-model, which spawns `.task { for await … in manager.state }` loops and
republishes via `@Published`-equivalent properties. The Demo's
`CentralViewModel` becomes a thin adapter.

### B. Peripheral redesign

Covered above. Key points:
- Pure `Sendable` `struct` — no manual locking, no `@unchecked Sendable`.
- Strongly-typed `AdvertisementData` replaces `[String: Any]`. Add a
  `rawAdvertisement: [String: any Sendable]` only if the maintainer wants
  to expose unknown keys (recommend: do not, for now).
- `CBPeripheral` lives only inside `BluetoothActor`'s registry.
- Equality / hashing on `id` is unchanged (already correct).
- `Peripheral` keeps `Identifiable, Hashable` for SwiftUI `ForEach` use.

### C. Logging layer — keep Willow 7.0, polish remaining nits

> **Revised post-Willow-7.0 (commit `3657f45`).** The original recommendation
> here was to drop Willow in favor of `os.Logger` directly, on the grounds
> that Willow's non-`Sendable` `Logger` was forcing `@preconcurrency` imports
> throughout the library. **That motivation no longer applies.** Willow 7.0
> is Swift 6 / strict-concurrency clean upstream and the repo has already
> integrated it (`@preconcurrency` removed from all 4 sites; `LogMessage`
> updated to `[String: any Sendable]`). Keep Willow — it's pulling its
> weight, the integration cost is now zero, and dropping it would be
> churn for churn's sake.

The remaining work in this layer is small polish:

1. **Add explicit `Sendable` to `ReliaBLEConfig`** (`ReliaBLEConfig.swift:33`).
   Compiler-synthesized, but explicit is better for a public struct that
   will cross actor boundaries:
   ```swift
   public struct ReliaBLEConfig: Sendable { ... }
   ```

2. **Verify `OSLogWriter` synthesizes `Sendable` cleanly** under
   `-strict-concurrency=complete`. If it doesn't (e.g., on a future SDK
   where `OSLog`'s Sendable status changes), follow upstream Willow's lead
   and add `@unchecked Sendable`:
   ```swift
   public final class OSLogWriter: LogModifierWriter, @unchecked Sendable { ... }
   ```
   The class is `final` with all `let` stored properties, so this is safe.

3. **`LoggingService.enabled` race — leave as-is in ReliaBLE.** The user
   requirement is that consuming apps can toggle logging at runtime, and
   the last-write-wins behavior is acceptable. A separate GitHub issue
   has been filed against `itsniper/Willow` to tighten the upstream
   `Logger.enabled` contract in a future Willow release; ReliaBLE will
   inherit the fix transparently. **No work in ReliaBLE.**

No other changes are needed in the logging layer. The `LogTag` / `LogMessage`
/ `LogWriter` / `OSLogWriter` types are already in good shape post-Willow-7.0.

### D. Migration order (build-green at every step)

> **Revised post-Willow-7.0.** Step 1 ("Drop Willow → `os.Logger`") is gone
> — Willow 7.0 is already integrated. The logging-polish work folds into a
> lightweight final step. The remaining steps are unchanged.

Each phase is a separately-mergeable PR. The build compiles and the test
suite runs after each.

1. **Introduce `@globalActor BluetoothActor` + delegate shim.** Move all
   `BluetoothManager` mutable state inside the actor. Keep public Combine
   surface unchanged for now (wrapped in `@unchecked Sendable` where
   needed to silence transitional warnings). All delegate callbacks now
   route through the actor. Fixes Cluster 1.
2. **`Peripheral` → value struct + `AdvertisementData`.** Move
   `CBPeripheral` registry inside `BluetoothActor`. Update
   `PeripheralManager` (which becomes internal to the actor). Demo must
   adapt: it currently reads `Peripheral.id`, `.name`, `.lastSeen` —
   preserved. Fixes Cluster 3.
3. **`AnyPublisher` → `AsyncStream` broadcaster.** Replace all three event
   surfaces. Remove `Combine` import from `BluetoothManager` / the actor /
   `ReliaBLEManager`. Update Demo's `CentralViewModel` to use
   `.task { for await … }`. Fixes Cluster 2.
4. **Make `ReliaBLEManager` nonisolated `Sendable` final class** and
   collapse the now-internal `BluetoothManager` / `PeripheralManager`
   types into the actor proper (or rename `BluetoothManager` →
   `BluetoothActor` with internal helper types). Delete dead code
   (`testFunction()` at `ReliaBLEManager.swift:106`,
   `AuthorizationError.unauthorized` if unused, the `forceMock: true`
   pass-through is **kept** per project rules).
5. **Logging polish + final pass.** Add explicit `Sendable` conformance to
   `ReliaBLEConfig`. Verify `OSLogWriter` synthesizes `Sendable` (add
   `@unchecked Sendable` if not, matching upstream `Willow.OSLogWriter`).
   Enable `swift-version 6` build with `-strict-concurrency=complete`
   everywhere; turn on the experimental `StrictConcurrency` upcoming
   feature in `Package.swift` if not already. Update DocC catalog with the
   new public surface (architecture & concurrency contract). Update
   `Tests/ReliaBLETests` and the Demo end-to-end. The `Logger.enabled`
   race is being addressed upstream in Willow — no DocC note needed in
   ReliaBLE.

### E. Risks / open questions for the maintainer

1. **Demo will need to be rewritten** (Combine → async). It's the only
   in-repo consumer and the user accepted breaking changes; flag it
   anyway. Estimate: ~50 lines of `.task { for await … }` patterns
   replacing the existing `.sink { }` pipelines.
2. **`CBUUID` is not declared `Sendable` upstream.** Need a
   `extension CBUUID: @retroactive @unchecked Sendable {}` declaration
   somewhere in the library, with a comment explaining why
   (`CBUUID` is effectively immutable after init).
3. **`LoggingService.enabled` is a deliberate lock-free race** inherited
   from Willow 7.0 upstream (Willow documents this as out-of-scope for its
   Sendable migration). Acceptable for a logging on/off toggle; benign
   last-write-wins behavior. Decision: **leave as-is in ReliaBLE.** A
   separate upstream issue has been filed against `itsniper/Willow` to
   tighten the contract; ReliaBLE will inherit the fix transparently when
   it lands.
4. **Whether to keep a Combine bridge for one release.** Recommended
   answer: **no**. Pre-1.0, no external consumers, dead weight that
   re-introduces `@preconcurrency`. If wanted later, ship a thin extension
   package (`ReliaBLECombine`) that adapts `AsyncStream` to Combine.
5. **Multi-subscriber semantics.** Each `manager.state`
   property access returns a *new* `AsyncStream`. This is intentional and
   correct (different SwiftUI views can each open one), but document it
   prominently — accidental "I'll subscribe once and reuse" assumptions
   will lead to confusion.
6. **`forceMock: true` parameter retention.** Per CLAUDE.md, this stays
   as a literal `true` at the call site to the factory. The audit
   confirms it remains load-bearing for the mock target after this
   refactor; it just lives inside the actor's `setupCentralManager` now.
7. **Naming.** `BluetoothActor` vs. `BLEActor` vs. `ReliaBLEActor`.
   Recommend `BluetoothActor` (clearest, namespace-disambiguated by
   module). `BluetoothManager` is renamed away — its responsibilities
   collapse into the actor; keep the file but rename the type, so DocC
   anchor links can be updated cleanly.

---

## Preventive Measures

- **Enable complete strict-concurrency** in `Package.swift` for both
  `ReliaBLE` and `ReliaBLEMock` targets:
  ```swift
  .target(
      name: "ReliaBLE",
      swiftSettings: [
          .enableExperimentalFeature("StrictConcurrency"),
          .swiftLanguageMode(.v6),
      ]
  )
  ```
  This catches regressions at compile time before review.
- **Ban `@unchecked Sendable` and `@preconcurrency import` via SwiftLint**
  outside of `Sources/ReliaBLEMock/` (where mock aliases may legitimately
  need a single `@retroactive` extension). SwiftLint's `custom_rules`
  feature handles this cleanly:
  ```yaml
  custom_rules:
    no_unchecked_sendable:
      name: "@unchecked Sendable banned"
      regex: '@unchecked\s+Sendable'
      included: "Sources/ReliaBLE/.*\\.swift"
      severity: error
    no_preconcurrency_import:
      name: "@preconcurrency import banned"
      regex: '@preconcurrency\s+import'
      included: "Sources/ReliaBLE/.*\\.swift"
      severity: error
  ```
  Wire SwiftLint into CI (see NFR 11 issue) so violations break the build,
  not review.
- **Cross-actor validation in the Demo.** Update the Demo app to perform
  SwiftData writes from a background actor (rather than `@MainActor`), so
  the Demo itself exercises the library across actor boundaries. This
  catches `@MainActor`-creep regressions earlier than the smoke test and
  doubles as a concrete pattern for library consumers to copy.
- **Document the concurrency contract in DocC** under
  `Documentation.docc/Concurrency.md` (new): "`ReliaBLEManager` is
  `Sendable` and callable from any actor. All event surfaces return fresh
  per-subscriber `AsyncStream`s. All actions are `async`. SwiftUI
  consumers should consume via `.task { for await … }`."
- **Add a smoke test** that constructs a `ReliaBLEManager` from a
  background actor and exercises every public method — guards against
  inadvertent `@MainActor` regressions.
- **Add a `Peripheral` Sendable conformance test** that captures the
  struct in a `Task.detached` closure (this fails to compile if the
  struct accidentally regains a non-`Sendable` field).
- **Pin CoreBluetoothMock minor version** in `Package.swift`
  (`upToNextMinor` already set) — any future mock API drift around
  concurrency annotations should be flagged in a controlled bump.
- **DocC build in CI** (`swift package generate-documentation`) so public
  API renames break the docs build, not silent drift. Tracked under the
  CI parent issue (NFR 11).

---

## Tracking — GitHub Issues

Parent: [**#10 — Update for Swift Concurrency in Swift 6**](https://github.com/Five3Apps/ReliaBLE/issues/10)

| Migration step | Issue | Status |
|---|---|---|
| Step 1 — `@globalActor BluetoothActor` + delegate shim | [#13](https://github.com/Five3Apps/ReliaBLE/issues/13) (reused) | Open |
| Step 2 — `Peripheral` → `Sendable` value struct + `AdvertisementData` | [#17](https://github.com/Five3Apps/ReliaBLE/issues/17) | Open |
| Step 3 — `AnyPublisher` → `AsyncStream` broadcaster | [#12](https://github.com/Five3Apps/ReliaBLE/issues/12) (reused) | Open |
| Step 4 — `ReliaBLEManager` → nonisolated `Sendable` + rename `BluetoothManager` → `BluetoothActor` | [#18](https://github.com/Five3Apps/ReliaBLE/issues/18) | Open |
| Step 5 — Logging polish + strict-concurrency flag flip + DocC update | [#19](https://github.com/Five3Apps/ReliaBLE/issues/19) | Open |
| Demo — exercise ReliaBLE from a background-actor SwiftData stack | [#20](https://github.com/Five3Apps/ReliaBLE/issues/20) | Open |

Standalone (not under #10):

| Track | Issue |
|---|---|
| NFR 11 — CI (GitHub Actions) parent | [#21](https://github.com/Five3Apps/ReliaBLE/issues/21) |
| ↳ DocC build in CI | [#22](https://github.com/Five3Apps/ReliaBLE/issues/22) |

Upstream:

| Track | Issue |
|---|---|
| Willow `Logger.enabled` data race (deferred from 7.0) | [itsniper/Willow#3](https://github.com/itsniper/Willow/issues/3) |
