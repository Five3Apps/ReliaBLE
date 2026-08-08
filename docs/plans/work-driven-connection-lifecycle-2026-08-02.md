# Phase 2: Work-Driven Connection Lifecycle (Approach B) — Plan

Tracking: [#51](https://github.com/Five3Apps/ReliaBLE/issues/51) (parent) with sub-issues
[#57](https://github.com/Five3Apps/ReliaBLE/issues/57) PoweredOn await,
[#58](https://github.com/Five3Apps/ReliaBLE/issues/58) Idle + Manual connect hold,
[#59](https://github.com/Five3Apps/ReliaBLE/issues/59) Approach B reconnect gating,
[#60](https://github.com/Five3Apps/ReliaBLE/issues/60) Work-driven auto-connect.

## Goal

Make work drive the link: a `Peripheral` connects because pending work needs a connection (not because the app called `connect`), tears the link down after a configurable idle interval (default 5s) when no work and no manual-connect hold remain, gates Approach B reconnect tiers on that same work/hold signal, and awaits a usable radio instead of silently no-op'ing when Bluetooth is not `poweredOn`.

## Background

Curated from Phase 2 exploration. All `file:line` refs are against the `50-peripheral-handle-type-model` branch (Phase 1 landed here).

### PRD requirements in scope

- **Architecture / Connection model (work-driven primary):** non-empty per-`Peripheral` command queue causes auto-connect; empty queue + no manual-connect hold starts idle disconnect (global config, default 5s); Manual connect uses the *same* ensure-linked path — "not a second connection stack or either-or mode enum".
- **FR-1.2 (Approach B):** Tier-0 = OS `CBConnectPeripheralOptionEnableAutoReconnect`, enabled on work-driven connects while linked, **ended** when idle teardown or intentional disconnect cancels the connection. Tier-1 = library exponential-backoff ladder, armed on unexpected disconnect **only while** work pending (or a manual-connect hold with reconnect). Disarmed when quiet. Accepted gap: during the idle grace window Tier-0 may reconnect once with an empty queue — if still quiet and no manual-connect hold, cancel again. On reconnection, services/characteristics must be re-discovered (FR-10.6/FR-10.3) — *Phase 3 work, not this plan*.
- **FR-1.3.1 / FR-11.5:** connection-state observation remains; must distinguish intentional disconnect, unexpected drop, and reconnecting.
- **FR-1.4 / FR-8.6:** scan, connect, and command submission **await** `PoweredOn` rather than silently no-op'ing. Terminal unusable states fail promptly with typed errors. Bluetooth state remains observable for UI gating.
- **FR-1.5:** idle disconnect when no pending/queued commands and no manual-connect hold; **default 5 seconds**; configuration is **global**, not per-peripheral.
- **FR-4.4:** enqueueing/running a command on a disconnected `Peripheral` must auto-connect (and run discovery to ready as needed) without a prior Manual `connect`, "unless product policy for never-seen ids chooses fail-fast (implementation planning)".
- **FR-5.2.1:** minimum viable command queue is **serial (one-wide) per peripheral** — ship that before prioritization. Full FR-4/FR-5 must not ship before FR-10 (Phase 3).
- **FR-9.2:** log idle connect/disconnect and Manual connect/disconnect (connection/disconnection and scan start/stop logging already done).
- **FR-11.1–11.5:** work-driven connect without prior Manual `connect`; `Peripheral.connect(autoReconnect:)` sets a manual-connect hold suppressing idle, `Peripheral.disconnect()` clears the hold and intentionally cancels; idle teardown cancels the connection (dropping Tier-0); **single ensure-linked state machine** shared by both paths; connection-state observation distinguishes intentional/unexpected/reconnecting.
- **NFR-2.1:** unit tests for all public API methods, ≥80% of code paths. **NFR-1.3:** all CoreBluetooth objects stay in one internal isolation domain; public handles forward by id; no per-peripheral actors owning `CBPeripheral`.

Concrete numbers the PRD actually names: idle default **5s**, coverage **80%**. It names **no** backoff intervals, retry caps, idle-grace duration, or connect/discovery timeouts — those are implementation choices for this plan.

### Current implementation surface

**`Sources/ReliaBLE/BluetoothActor.swift`** (single per-manager `actor`, owns all CB objects):

- Connect/disconnect: `func connect(id:autoReconnect:) throws` (:1068), `func disconnect(id:) throws` (:1106). Guards are `!isShutdown`, `centralManager != nil` (→ `PeripheralError.bluetoothUnavailable`), and a live `cbPeripherals[id]` (→ `notFound`, :1116). **Neither checks `centralManager.state`.** The full connect path is: `Peripheral.connect` → `ensureCentralManager()` → actor `connect` → guards → mutate `reconnectEnabled` / `intentionalDisconnects` → optimistic `.connecting` → `centralManager.connect` with the optional Tier-0 option → delegate → `handleDidConnect` / `handleDidFailToConnect` / `handleDidDisconnect` → `setConnectionState` and, if `reconnectEnabled`, `armReconnect`.
- Tier-0 today: `connect` sets `[CBConnectPeripheralOptionEnableAutoReconnect: true]` under `#available(macOS 14.0, iOS 17.0, *)` when `autoReconnect == true` (:1093), then `centralManager.connect(cbPeripheral, options:)` (:1095). There is **no** path that later cancels Tier-0 on idle.
- Connection state: `var connectionStates: [String: ConnectionState]` (:201); single write path `setConnectionState(_:for:)` (:1136) which mirrors to the handle registry and broadcasts a `ConnectionStateChange`; `clearConnectionStates()` (:1158).
- Reconnect state: `reconnectEnabled: Set<String>` (:211), `intentionalDisconnects: Set<String>` (:212), `reconnectAttempts: [String: Int]` (:213), `taskRegistry` (`nonisolated let`, NSLock-protected `[String: Task<Void, Never>]`, :149).
- Tier-1 ladder: `armReconnect(id:)` (:1245) → `scheduleReconnect(id:attempt:)` (:1263) computes jittered exponential delay, sets `.reconnecting(source: .library, attempt:nextRetryAt:)`, spawns `Task { try await Task.sleep(nanoseconds:); await performReconnect(...) }` (:1290) registered in `taskRegistry`; `performReconnect` (:1305); `clearReconnectState(for:)` (:1324) cancels the task and clears attempts/intent.
- Intentional vs unexpected: `disconnect` inserts into `intentionalDisconnects` (:1120); `handleDidDisconnect` removes + early-returns to `.disconnected(reason: nil)` (:1173); otherwise arms Tier-1. `payload.isReconnecting` maps to `.reconnecting(source: .system)` (:1184).
- Radio gating today: `startScanning` has `guard centralManager.state == .poweredOn else { warn; return }` (:625) — **the silent no-op FR-1.4 targets**. `resumeRestoredScan` stashes into `pendingRestoredScanServices` and defers (:819). `updateState()` (:690) maps `CBManagerState` → `BluetoothState`. `handleCentralManagerStateUpdate()` (:837): on `.poweredOn` refreshes peripherals + resumes restored scan; on `.resetting`/`.unsupported`/`.unauthorized` calls `invalidatePeripherals()`; always calls `updateState()` + `resolvePendingAuthorization()`.
- **Existing await-until-ready precedent:** `suspendForAuthorizationDecision(id:)` (:530) uses `withCheckedThrowingContinuation` into `authorizationContinuations[id]`, resolved by `resolvePendingAuthorization()` (:586) on every state update, with cancellation wired through `cancelAuthorizationContinuation` from `ReliaBLEManager.authorizeBluetooth`'s `withTaskCancellationHandler`. This is the pattern a PoweredOn await should mirror.
- Delegate plumbing: two `NSObject` shims — `BluetoothDelegateShim` (:1527) and `RestoringBluetoothDelegateShim` (:1581, adds `willRestoreState` at :1624) — forward via `DelegateEventForwarder` into an `AsyncStream<DelegateEvent>` drained by a single consumer `Task` calling `process(event)` (:478/:502/:521). Shims must be kept in sync.

**Other files:**

- `Sources/ReliaBLE/ReliaBLEConfig.swift`: `ReliaBLEConfig` (:48) — `logLevels`, `logWriters`, `logQueue`, `loggingEnabled`, `reconnectPolicy`, `restoreIdentifier`. `ReconnectPolicy` (:83) — `maxAttempts = 5`, `initialDelay = 1.0`, `maxDelay = 30.0`, `jitter = 0.2`. No idle-interval knob yet.
- `Sources/ReliaBLE/Models/Peripheral.swift`: `public final class Peripheral: Sendable, Identifiable, Hashable` (:104) with sync `Mutex`-backed metadata (`cbIdentifier`, `name`, `rssi`, `lastSeen`, `advertisement`, `connectionState`), `public func connect(autoReconnect: Bool = true) async throws` (:165) and `public func disconnect() async throws` (:176), each doing `await manager.bluetooth.ensureCentralManager()` then forwarding by id (:170/:181).
- `Sources/ReliaBLE/PeripheralHandleRegistry.swift`: `peripheral(id:)` (:140) interns one `Peripheral` per id per manager behind a `Mutex<Storage>`; `applyDiscovery(...)`, `applyConnectionState(id:state:)` (skips interning on `nil` clear); `removeAllHandles` on shutdown.
- `Sources/ReliaBLE/Models/PeripheralError.swift` (:32): `public enum PeripheralError: Error, Sendable, Equatable` — `notFound`, `bluetoothUnavailable`, `connectionFailed`, `connectionTimeout`, `peripheralDisconnected`, `unknown`, plus `fromCBError(_:)`. `ReliaBLEManager.swift:296`: `public enum AuthorizationError` — `denied`, `restricted`, `unknown`. These are the only error types.
- `Sources/ReliaBLE/ReliaBLEManager.swift`: public surface is `loggingService` (:39), `state` (:101), `currentState` (:108), `connectionStateChanges` (:122), `currentConnectionStates` (:128), `authorizeBluetooth()` (:142), `peripheralDiscoveries` (:165), `discoveredPeripherals` (:172), `startScanning(services:)` (:183), `stopScanning()` (:189), `peripheral(id:)` (:219). `BluetoothState` enum (:236): `scanning`, `ready`, `poweredOff`, `resetting`, `unauthorized(AuthorizationStatus)`, `unsupported`, `unknown`.
- **No time/clock abstraction exists.** The only scheduling call sites in `Sources/` are `scheduleReconnect` (:1263) and its `Task.sleep(nanoseconds:)` (:1290).

**Test harness** — `Tests/ReliaBLETests/ReliaBLEManagerTests.swift` (single 2689-line file; `Tests/ReliaBLETests/Mocks/` is empty):

- swift-testing (`import Testing`, :28), `@Suite(.serialized)`, `@testable import ReliaBLEMock`.
- `Mock.makeManager(loggingEnabled:reconnectPolicy:restoreIdentifier:tearDownPrevious:)` (:2445); one-time `SimulationConfig.ensureConfigured()` (:2529) doing `CBMCentralManagerMock.simulateInitialState(.poweredOn)` + `simulatePeripherals([...])` + authorization.
- Peripheral specs via `CBMPeripheralSpec.simulatePeripheral(proximity:).advertising(...).connectable(name:services:delegate:).build()` (:2494/:2505); connection outcomes driven by `ConnectionTestDelegate` (:2230) whose `connectionResult` is a settable `Result`.
- Timing is all wall-clock: `pollUntil(timeout:)` (:2604), `firstEvent(from:withinNanoseconds:)` (:2623/:2640), `drainConnectionStateChanges(...)` (:2655), ~50 raw `Task.sleep` / `withinNanoseconds` sites. No `confirmation()`, no XCTest expectations.
- `Package.swift`: three targets (`ReliaBLE`, `ReliaBLEMock` excluding `CBCentralManagerFactory.swift` + `Documentation.docc`, `ReliaBLETests` depending only on `ReliaBLEMock`), all with `.swiftLanguageMode(.v6)` + `.enableExperimentalFeature("StrictConcurrency")`.

### Prior-art decisions that constrain this work

- **`docs/plans/auto-reconnect-backoff-2026-07-05.md`**: established the two-tier model, `ConnectionState.reconnecting(source:attempt:nextRetryAt:)`, `armReconnect` as the single choke point, and `intentionalDisconnects` for clean-vs-unexpected. Explicitly left open: `handleDidDisconnect` honoring `isReconnecting`, and the OS give-up budget (undocumented, needs on-device verification). Its critique (`docs/reviews/auto-reconnect-backoff-plan-critique-2026-07-05.md`) flagged `reconnectTasks` races (cancel during sleep + second schedule) and incomplete `intentionalDisconnects` clearing paths on fail/give-up/success — both still relevant to the gating work.
- **`docs/plans/connection-lifecycle-stream-2026-06-30.md`**: `connectionStateChanges` is the no-replay primary stream, `currentConnectionStates` the snapshot; optimistic `.connecting`/`.disconnecting` before the CB call; ordering guaranteed by actor serialization; only `PeripheralError` surfaces (never raw `Error`).
- **`docs/plans/background-scanning-state-restoration-2026-07-13.md`**: `willRestoreState` re-wires delegate-less `CBPeripheral`s, seeds `connectionStates` from `peripheral.state`, and **re-arms `reconnectEnabled`** for standing connects (persisted in `UserDefaults` keyed by `restoreIdentifier`). Restored links are not re-issued. Any work/hold gating must decide what a restored link means when there is no work and no hold.
- **`docs/plans/peripheral-handle-type-model-2026-07-31.md`** (Phase 1, just landed): handles interned per id per manager; `connect`/`disconnect` moved onto `Peripheral` and the manager-level methods were **removed outright**; connection state mirrored to the handle; registry cleared on shutdown; lock order registry-then-handle; retain graph is actor → bridge → registry → **weak** manager. It explicitly deferred to #57: "connect does NOT await; preserves today's ensure-then-throw".
- **Mock limitations (`docs/plans/corebluetoothmock-upstream-gaps-2026-07-21.md`, issues [#40](https://github.com/Five3Apps/ReliaBLE/issues/40) / [#42](https://github.com/Five3Apps/ReliaBLE/issues/42))**: CoreBluetoothMock simulates `isReconnecting: true` but **never emits the true→false give-up transition** (#40), so "OS gave up → hand off to Tier-1" is untestable through normal mock disconnects; the accepted workaround is an internal `testInjectDisconnect(for:isReconnecting:error:)` hook that bypasses the shim. `willRestoreState` cannot be synthesized post-init (#42). Simulating connection-cancel semantics and timers is called out as *not* provided by the mock — library-side timing is ours to control.

## Design

### D-0 Resolved decisions

Every open question this plan started with is resolved here. Decisions marked **(user)** were confirmed directly and override the generated draft; the rest are plan defaults with their rationale.

| ID | Decision | Rationale |
|----|----------|-----------|
| **D-deliv** **(user)** | **One branch `51-work-driven-connection-lifecycle`, one PR** closing #51, with #57–#60 as ordered green commits referenced as checklist items in the PR body. | #58/#59/#60 all read the same link-demand signal and the same `ensureLinked` path. Splitting them forces a throwaway dual connect path between merges. #57 is separable in commits but its only call sites are scan/connect, which the same PR rewrites. |
| **D-work** **(user)** | Interim work signal is an **internal, actor-isolated refcounted work lease**: `acquireWorkLease(id:)` / `releaseWorkLease(_:)`. **No public API this phase.** Test access via `@testable` hooks. | Zero public surface to un-ship when FR-4/FR-5 land. The lease refcount is the exact dual of "command queue non-empty", so Phase 3 makes the queue one lease source without redesigning `ensureLinked`. #60's "documented way for work to drive connect" is satisfied by internal docs + tests until the queue ships. |
| **D-radio** **(user)** | **Fail fast, typed:** `.poweredOff` → `PeripheralError.bluetoothPoweredOff`; `.unsupported` → `PeripheralError.bluetoothUnsupported`; `.unauthorized` → `PeripheralError.bluetoothUnavailable`; no central / shut down → `.bluetoothUnavailable`. **Await:** `.resetting`, `.unknown`, and the pre-first-`centralManagerDidUpdateState` window. **No timeout** on the await; task cancellation is the exit. A waiter parked on `.resetting`/`.unknown` that resolves to `.poweredOff` **fails** with `bluetoothPoweredOff` rather than continuing to wait. | User-disabled Bluetooth is a decision the app must surface, not a condition to hang on — a scan that silently blocks forever is the same usability failure as today's silent no-op, just relocated. `.resetting`/`.unknown` are genuinely transient and self-resolve, satisfying #57's "transient unknown/resetting can complete when PoweredOn arrives". |
| **D-restore** **(user, revised 2026-08-05)** | **Manual-connect holds are durable; work leases are not.** Persistence stores a **hold map** (`id → reconnectDesired`), not a reconnect-enabled set, and `handleWillRestoreState` **reads it back**. Four cases: (1) OS restores a peripheral **and** a hold is persisted for that id → rehydrate `manualConnectHold[id]` with its `reconnectDesired`, sync intent, **no idle timer**, `reevaluateLink` if not linked. (2) OS restores a link with **no** persisted hold → **idle timer** starts. (3) Work leases **never** survive process death. (4) A persisted hold with `reconnectDesired: false` survives: it suppresses idle but arms neither tier and is not re-issued on radio return. | A manual `connect` is an explicit "keep this link" instruction; when the app has configured state restoration, that instruction should outlive relaunch, otherwise restoration cannot deliver the standing-session behavior it exists for. NFR-3.2 is still honored where it matters — restored links the app never explicitly asked for (residual or Tier-0 links) still idle out. Work is inherently process-scoped, so leases must not be resurrected. **This reverses the earlier decision that restoration never re-applies a hold and that the restore-time read should be deleted.** |
| **D-never** | Work-driven connect (and lease acquisition) on an id with no live `CBPeripheral` **fails fast** with the existing `PeripheralError.notFound`. No await-for-discovery, no implicit scan, **and no scan-on-`notFound` retry loop**. Recovery after an invalidate is **retrieve-only** — `refreshPeripherals()` → `retrievePeripherals(withIdentifiers:)` recovers known ids after a power cycle and ids still in the CoreBluetooth system cache; anything not retrievable is terminal for the automatic path. | FR-4.4 explicitly delegates this to implementation planning. Awaiting discovery couples the work path to scan policy and creates an unbounded wait with no cancellation story distinct from D-radio's. **Library-owned continuous or demand-driven scanning is FR-8.2 / FR-4 territory, deliberately not Phase 2** — inventing a "scan until found" stack here would be the second connection stack FR-11.4 forbids. The door stays open: FR-8.2 can later add scan policy and call `reevaluateLink` on discovery, which is purely additive. |
| **D-idle** | `ReliaBLEConfig.idleDisconnectInterval: TimeInterval = 5.0`, global (FR-1.5). The Tier-0 grace window reuses the **same** interval — one knob, not two. | PRD names 5s and names no grace duration. A second knob would be unexplained configuration surface. |
| **D-time** | **No `Clock` protocol this phase.** Add a test-only `setIdleDisconnectInterval(_:)` actor hook mirroring the existing `setReconnectPolicy(_:)`; production reads the value from config at init. Tests run idle at 0.05–0.2s using the existing `pollUntil` / `drain*` helpers. | The only scheduling in `Sources/` today is `scheduleReconnect`'s `Task.sleep`, and `ReconnectPolicy` already proves the interval-override pattern works for timing tests. A full injectable clock is a larger refactor than this phase needs and would touch every existing reconnect test. |
| **D-hold** **(user, revised 2026-08-05)** | `Peripheral.connect(autoReconnect:)` sets a manual-connect hold whose `reconnectDesired` is the `autoReconnect` argument. `Peripheral.disconnect()` clears the hold and intentionally cancels. Work leases **never** set a hold. **The hold is registered *before* the radio wait, not after** — see D-3 for the normative call sequence. The public parameter name stays `autoReconnect`. | FR-11.2 verbatim, keeping "hold" and "work" as two independent demand sources feeding one derived signal. The ordering matters: if the hold were set only after `waitUntilPoweredOn()` succeeded, calling `connect(autoReconnect: true)` while Bluetooth is off would throw and leave **no** demand behind, so the radio returning would do nothing. That contradicts what `autoReconnect: true` means — connect whenever this peripheral is available. Setting the hold first makes the throw informational rather than destructive. |
| **D-tier** | Tier-0 (`CBConnectPeripheralOptionEnableAutoReconnect`) is passed on every connect issued through `issueConnect` when `wantsReconnect(id)` is true. Tier-1 `armReconnect` is gated on the same predicate. Idle teardown and intentional disconnect both cancel the connection, which is what ends Tier-0. | FR-1.2 / FR-11.3. Replaces today's meaning of `reconnectEnabled` ("the last connect asked for autoReconnect") with "demand currently wants a link back". |
| **D-ensure** | A single `ensureLinked(id:)` / `reevaluateLink(id:)` path. Manual connect and work-lease acquisition both call it. `centralManager.connect` is called from exactly one private function, `issueConnect(id:enableAutoReconnect:)`. | FR-11.4 — "no parallel connection stacks" is enforceable only if there is one call site. |

### D-1 The ensure-linked state machine

All state and mutation is actor-isolated on `BluetoothActor`. Per peripheral id:

**Demand is derived, never stored directly:**

```swift
// demand(id)        = workCount[id, default: 0] > 0 || manualConnectHold[id] != nil
// wantsReconnect(id) = workCount[id, default: 0] > 0 || manualConnectHold[id]?.reconnectDesired == true
```

**New per-id bookkeeping on the actor:**

```swift
struct ManualConnectHold: Sendable {
    var reconnectDesired: Bool
}

/// Live lease IDs per peripheral. `workCount(id)` is `activeLeases[id]?.count ?? 0`.
/// A `Set<UUID>` rather than a bare `Int` so an already-released token is *detectable*:
/// a refcount alone cannot distinguish a double-release of token A from a legitimate
/// release of token B, and would tear down a link that still has work outstanding.
private var activeLeases: [String: Set<UUID>] = [:]
private var manualConnectHold: [String: ManualConnectHold] = [:]
private var idleGeneration: [String: UInt64] = [:]
private nonisolated let idleTaskRegistry = TaskRegistry()
```

**Why `reevaluateLink` needs a reason.** A hold created by `connect(autoReconnect: false)` makes `demand` true but `wantsReconnect` false. If the connect-issuing arm were gated on bare `demand`, the radio-return sweep would silently reconnect a link the app explicitly declined to auto-reconnect — while events 9–11 refuse to. If it were gated on `wantsReconnect`, the *initial* `connect(autoReconnect: false)` would never link at all. The caller's reason disambiguates:

```swift
enum LinkReason: Sendable {
    case explicitConnect     // Peripheral.connect — always issues
    case workAcquired        // lease taken — wantsReconnect is true by construction
    case radioReturned       // sweep after .poweredOn
    case relinkAfterIntentional  // Manual disconnect that raced pending work
    case discoveredWhileDemanded // optional polish — see event 15
}

private func reevaluateLink(id: String, reason: LinkReason) throws
```

The issue arm requires `wantsReconnect(id) || reason == .explicitConnect`. Bare `demand` governs idle suppression only.

`reconnectEnabled` stops being the gate and becomes a value **synced** from `wantsReconnect(id)` by `syncReconnectIntent(id:)` after every demand change. `intentionalDisconnects`, `reconnectAttempts`, and the existing `taskRegistry` keep their current meaning.

**Phases** (conceptual — deliberately not a public enum; the app-visible surface stays `ConnectionState`):

| Phase | Meaning |
|-------|---------|
| `Quiet` | No demand. May still be CB-connected during a grace window. |
| `AwaitingRadio` | Demand present, parked on a PoweredOn continuation, or waiting for the radio to return after an invalidate. **Publicly visible as `.reconnecting(source: .library, attempt: nil, nextRetryAt: nil)` when `wantsReconnect(id)`** — see event 13. |
| `Linking` | Connect in flight — `.connecting`, or `.reconnecting` from either tier. |
| `Linked` | `.connected` with demand present. |
| `IdleGrace` | Was linked or linking; demand dropped to zero; idle timer running. |
| `TearingDown` | Intentional cancel in flight — `.disconnecting`. |

**Events and transitions (normative):**

1. **`acquireWorkLease(id:)`** — await radio per D-radio; fail `notFound` if no live `CBPeripheral`; insert a fresh `UUID` into `activeLeases[id]`; cancel any idle timer; `syncReconnectIntent`; `reevaluateLink(id:reason: .workAcquired)`; return the token.
2. **`releaseWorkLease(_:)`** — remove `token.leaseID` from `activeLeases[token.id]`; if it was not present, **no-op** (unknown or already-released token) and return. Otherwise `syncReconnectIntent`, and if demand is now false → `beginIdleGrace(id:)`.
3. **`applyManualConnectHold(id:reconnectDesired:)`** — hold registration **only**: set `manualConnectHold[id] = ManualConnectHold(reconnectDesired:)`; cancel any idle timer; clear `intentionalDisconnects[id]`; `syncReconnectIntent` (the **sole** persistence writer — see D-4). It deliberately does **not** wait for the radio and does **not** issue a connect. `Peripheral.connect` calls this *before* `waitUntilPoweredOn()`, then calls `reevaluateLink(id:reason: .explicitConnect)` after the wait succeeds (D-hold, D-3). Splitting the two is what lets a `connect` that throws `bluetoothPoweredOff` still leave durable demand behind.
4. **`applyManualDisconnect(id:)`** — clear `manualConnectHold[id]` **unconditionally**; `syncReconnectIntent`; cancel the idle timer and the Tier-1 ladder; then tear down per the settling rule: if the peripheral is `.connected`, run the intentional-cancel path (`intentionalDisconnects.insert`, `.disconnecting`, `cancelPeripheralConnection`); otherwise settle synchronously to `.disconnected(reason: nil)`. **Returns success when there is no live `CBPeripheral` or nothing to cancel** — dropping a hold during a radio outage must not throw `notFound`, because that is the only way to drop demand while the radio is down. Does not start an idle timer.
5. **`reevaluateLink(id:reason:)`** — the single ensure-linked entry point.
   - If `!demand(id)` → return.
   - Re-check `centralManager.state` per D-radio. A waiter resumed at `.poweredOn` runs on a later actor turn, by which time the radio may have flipped again; on regression, throw the matching typed error rather than issuing against a dead radio.
   - No `cbPeripherals[id]` → throw `notFound`.
   - Already `.connected` → verify against `cbPeripherals[id]?.state`, not the cached `connectionStates` value (see D-7's radio-cycle row); if genuinely connected, `syncReconnectIntent` only. **Tier-0 cannot be flipped on a live link** — CoreBluetooth has no API to change connect options mid-connection. If a link is up without Tier-0 and demand now wants it, the option applies on the next connect issue. Documented limitation, not a bug.
   - Already `.connecting`, or `.reconnecting(source: .system)` → `syncReconnectIntent` only.
   - Otherwise → issue only if `wantsReconnect(id) || reason == .explicitConnect`, via `issueConnect(id:enableAutoReconnect: wantsReconnect(id))`.
   - **Error surfacing:** two callers (event 9's relink branch and event 12's sweep) run in delegate context and cannot propagate a throw. They must publish `.failed(reason: .notFound)` through `setConnectionState` rather than logging and dropping — otherwise a work lease is stranded with no signal on any stream.
   - **`notFound` is terminal for the automatic path.** There is no scan and no retry loop behind it (D-never). Crucially, **demand is retained** — the lease or hold stays exactly as the app left it, and is dropped only by an explicit `disconnect()` or lease release. If the app later scans and the peripheral is rediscovered, event 15 relinks it. Phase 3 should treat `.failed(reason: .notFound)` as a *command* failure, decided independently of lease lifetime.
6. **`beginIdleGrace(id:)`** — only when `!demand(id)` **and** the peripheral is `.connected`, `.connecting`, or `.reconnecting(source: .system)`. If the state is library-`.reconnecting`, `.disconnected`, or `.failed`, there is nothing to tear down: cancel the ladder task and settle to `.disconnected(reason: nil)` synchronously, with no timer and no CB cancel. Otherwise increment `idleGeneration[id]`, capture it, cancel any prior idle task, and schedule `Task { try await Task.sleep(for: .seconds(idleDisconnectInterval)); await fireIdle(id:generation:) }` in `idleTaskRegistry`. Log at info per FR-9.2.
7. **`fireIdle(id:generation:)`** — no-op if the generation is stale or demand returned. Otherwise log the idle disconnect and run the intentional-cancel path (which drops Tier-0). Resulting state is `.disconnecting` → `.disconnected(reason: nil)` — indistinguishable from an app disconnect to the reconnect policy, which is exactly FR-11.5's "intentional".
8. **`handleDidConnect`** — clear reconnect attempts as today. If `!demand(id)` → `beginIdleGrace(id:)` immediately (this is the accepted Tier-0 blip path from FR-1.2). Else remain Linked and `syncReconnectIntent`.
9. **`handleDidDisconnect`** —
   - Intentional → clean `.disconnected(reason: nil)`, clear attempts. **Then, if any lease is live for that id, call `reevaluateLink(id:reason: .relinkAfterIntentional)`** so a Manual `disconnect()` that races pending work does not strand it (see the edge-case table).
   - `isReconnecting == true` (Tier-0 in progress) → if `wantsReconnect(id)`, publish `.reconnecting(source: .system)` and let the OS work. If **not**, do not trust Tier-0: publish `.disconnected(reason: nil)` immediately and call `cancelPeripheralConnection` as fire-and-forget suppression. Per the settling rule, do **not** insert into `intentionalDisconnects` — the peripheral is already physically disconnected, so there is no `.disconnecting` to settle, and a late callback classified as unexpected is harmless because `armReconnect` is gated off by `wantsReconnect`. This branch cannot loop: `!wantsReconnect` implies no live leases, so the relink branch above is unreachable from it.
   - Otherwise unexpected → set disconnected with the mapped reason, and `armReconnect(id:)` **only if `wantsReconnect(id)`**.
10. **`handleDidFailToConnect`** — `.failed`, then `armReconnect(id:)` only if `wantsReconnect(id)`.
11. **`armReconnect(id:)`** — gate changes from `reconnectEnabled.contains(id)` to `wantsReconnect(id)`. `ReconnectPolicy` (attempts, delay, jitter) is unchanged. `performReconnect` routes through `issueConnect(id:enableAutoReconnect: wantsReconnect(id))`.
12. **Radio reaches `.poweredOn`** — resume PoweredOn waiters; for every id with demand that is not linked, `reevaluateLink(id:reason: .radioReturned)`; for restored links with no demand, `beginIdleGrace(id:)` (D-restore).

15. **Discovery upserts an id that already has demand** *(optional Phase 2 polish — implement if cheap, otherwise defer to FR-8.2)* — call `reevaluateLink(id:reason: .discoveredWhileDemanded)`. This starts **no** scan of its own; it only links opportunistically when something else (an app-driven scan, typically) discovers a device that demand is already waiting on. It is the cheap recovery path for the `notFound` terminal case above, and it is the exact hook FR-8.2 will reuse when library-owned scanning arrives.
13. **`invalidatePeripherals()`** — the normative per-id sequence, in order:
    1. For each tracked id, emit `.disconnected(reason: .bluetoothUnavailable)`. The link really is dead; observers must be told.
    2. Clear the CB maps; cancel idle and ladder tasks; **preserve `activeLeases` and `manualConnectHold`**. Demand survives a radio outage — this mirrors how handles keep their metadata across invalidation.
    3. For each id where `wantsReconnect(id)`, immediately publish `.reconnecting(source: .library, attempt: nil, nextRetryAt: nil)`. This is the public projection of the `AwaitingRadio` phase and holds until `issueConnect` moves it to `.connecting`, the ladder supplies real attempt values, the link succeeds, or demand is cleared.
    4. Ids with demand but **not** `wantsReconnect` — i.e. a `connect(autoReconnect: false)` hold — get **no** `.reconnecting` signal. Settling at disconnected is the honest state: nothing will re-issue for them (event 12's issue gate refuses), so claiming "reconnecting" would be a lie.
    5. Ids with no demand are simply untracked: the handle's `connectionState` goes `nil` after the clear, and step 1's emission is the only stream event.
    6. On radio return, event 12 drives `issueConnect` → `.connecting` → `.connected` / failure / ladder exactly as today.

    **Why step 3 exists.** Without it, a radio drop leaves every auto-relinking peripheral looking permanently gone — `.disconnected(.bluetoothUnavailable)` on the stream and `nil` on the handle — with no way for the app to distinguish "the library will bring this back" from "this is over." There is no public demand API in Phase 2 (D-work), so `ConnectionState` is the *only* channel that can carry that distinction. This likely means splitting or replacing the current bulk `clearConnectionStates()` with a per-id policy rather than a blanket nil-out.

    Three changes to the existing implementation are required:
    - **Add `.poweredOff` to the invalidate triggers.** Today `handleCentralManagerStateUpdate` (near `:849`) invalidates on `.resetting` / `.unsupported` / `.unauthorized` and explicitly skips `.poweredOff`. CoreBluetooth invalidates `CBPeripheral` objects across a power cycle, and without this the cached `connectionStates[id]` still reads `.connected` after off→on, so event 12's `reevaluateLink` takes the already-connected arm and a demanded link is **never** re-established. Existing tests that power-cycle will observe the new emissions and need updating.
    - **Stop writing persistence from invalidate.** `invalidatePeripherals` currently does `reconnectEnabled.removeAll()` followed by `persistReconnectIntent()` (near `:1000`), which writes an *empty* payload to UserDefaults — so a transient `.resetting` blip erases the persisted hold map and breaks D-restore across a relaunch. Drop that call entirely; **invalidate must never touch disk.**
    - **Preserve the deferred restored scan.** `invalidatePeripherals` currently nils `pendingRestoredScanServices` and its options, so a warm power-off can silently drop a restored scan that had not yet resumed. On the `.poweredOff` / `.resetting` paths, **preserve** them. This is a deliberately minimal change: it does not create continuous-scan demand and does not make a lease or hold imply "keep scanning" — that policy is FR-8.2's. If preserving turns out to require inventing scan-demand semantics, leave the clearing as-is and record a one-line open item owned by FR-8.2: *power-cycle may drop a deferred restored scan until continuous-scan demand is defined.*
14. **`shutdown()`** — additionally fail all pending PoweredOn waiters, clear holds and leases, and clear both task registries. **`shutdown()` clears volatile state only and must never write to UserDefaults.** In particular, clearing the in-memory hold map must not route through `syncReconnectIntent` or any other persistence writer — an empty flush at shutdown would erase exactly the restore intent D-restore depends on, and a manager torn down in the background would silently destroy the app's standing session. The existing `testClearPersistedReconnectIntent` hook remains for tests; an explicit public reset API, if ever wanted, is out of scope here.

**Invariant to assert in review:** `centralManager.connect(_:options:)` appears exactly once in the codebase, inside `issueConnect`. This is achievable today — `connect` (`BluetoothActor.swift:1095`) is the only call site, the restore path deliberately never connects (see its "Do not reconnect here" comment near `:764`), and `performReconnect` reaches CoreBluetooth through `connect`. **The extraction must be side-effect free:** today's `connect` body also mutates `reconnectEnabled` (`:1083`–`:1085`), calls `persistReconnectIntent()` (`:1087`), and clears `intentionalDisconnects` (`:1088`). If `performReconnect` routed through an un-stripped extraction, every ladder attempt on a *work-driven* link would persist reconnect intent and violate D-4's hold-driven-only persistence rule. `issueConnect` must be exactly: optimistic `.connecting` → build options → `centralManager.connect`. Nothing else.

**Settling optimistic states.** Three paths cancel a connection that may not be in a state CoreBluetooth acknowledges — idle fire, the untrusted-Tier-0 branch, and idle grace armed during `.connecting`. CoreBluetooth does not guarantee a `didDisconnect` callback for a cancel issued against a pending connect or a peripheral in OS-reconnect limbo. **Rule: never publish an optimistic `.disconnecting` unless the peripheral is currently `.connected`.** Where it is not, settle synchronously to `.disconnected(reason: nil)` and do **not** insert into `intentionalDisconnects` — if CoreBluetooth does deliver a late `didDisconnect`, it is then classified as unexpected, and `armReconnect` is already gated off by `wantsReconnect`, so the late callback is a no-op instead of a stranded flag.

### D-2 PoweredOn await (#57)

**New actor API:**

```swift
/// Suspends until the central is usable, or fails with a typed error for terminal states.
/// - Throws: `PeripheralError.bluetoothPoweredOff`, `.bluetoothUnsupported`,
///           `.bluetoothUnavailable`, or `CancellationError`.
func waitUntilPoweredOn() async throws
```

**Implementation** — mirrors the existing authorization continuation pattern (`suspendForAuthorizationDecision` at `BluetoothActor.swift:530` / `resolvePendingAuthorization` at `:586`):

- `private var poweredOnContinuations: [UUID: CheckedContinuation<Void, Error>]`.
- On entry: shut down → `bluetoothUnavailable`. No central → `bluetoothUnavailable` (callers reach here only after `ensureCentralManager()`). Then switch on `centralManager.state`: `.poweredOn` → return immediately; `.poweredOff` → throw `bluetoothPoweredOff`; `.unsupported` → throw `bluetoothUnsupported`; `.unauthorized` → throw `bluetoothUnavailable`; `.resetting` / `.unknown` → park a continuation.
- `resolvePoweredOnWaiters()` runs from `handleCentralManagerStateUpdate` (`:837`) alongside `resolvePendingAuthorization()`: `.poweredOn` resumes every waiter successfully; `.poweredOff` / `.unsupported` / `.unauthorized` **fail** every waiter with the matching typed error; `.resetting` / `.unknown` leave them parked.
- Cancellation: façade methods wrap the call in `withTaskCancellationHandler` with a `cancelPoweredOnContinuation(id:)` onCancel, exactly as `ReliaBLEManager.authorizeBluetooth` (`:142`) does today.
- **Resumed waiters re-check before acting.** A continuation resumed from the state handler runs at a later actor turn, so the radio may have flipped again before the caller issues `scanForPeripherals` or `issueConnect`. Both resumption paths re-read `centralManager.state` and either re-park (transient) or throw the matching typed error (terminal). `reevaluateLink` does the same check for the connect path (D-1 event 5).
- **Scan filter precedence.** A restored scan (`pendingRestoredScanServices`) and an awaited `startScanning` can both fire at `.poweredOn`, and CoreBluetooth has a single scan — last writer wins. **The app-requested filter wins:** resolve the app waiter after the restored scan resumes, and clear `pendingRestoredScanServices` when an app scan supersedes it.
- **A parked scan waiter has four distinct outcomes, and only one of them throws `CancellationError`.** Model this with an explicit resume reason (`.poweredOn` / `.superseded` / `.stopped` / `.failed(PeripheralError)`) rather than overloading cancellation:

| Cause | `startScanning` result |
|-------|------------------------|
| Radio reaches `.poweredOn` | Success — scan starts |
| `stopScanning()` called while parked | **Success** (void), no scan started. The app asked for a scan and then asked to stop; that sequence completed as requested and is not an error |
| Superseded by a later `startScanning` | Earlier waiter completes **successfully** without scanning (or is coalesced with the newer request — document whichever the implementation picks) |
| The calling task is cancelled (`Task.cancel`) | **`CancellationError`** — the only throwing-cancellation case |
| Radio resolves to `.poweredOff` (or another terminal state) | **`bluetoothPoweredOff`** / matching typed error — not success |

**Call sites:**

| API | Today | After |
|-----|-------|-------|
| `ReliaBLEManager.startScanning` | `ensureCentralManager()` then scan; **silently returns** if not `poweredOn` (`BluetoothActor.swift:625`) | `ensureCentralManager()` → `waitUntilPoweredOn()` → scan; propagates typed errors |
| `ReliaBLEManager.stopScanning` | ensure + stop | No radio wait, but it now **resolves any parked scan waiter successfully** — otherwise a `startScanning` suspended on `.resetting` would start scanning after the app said stop. The waiter returns void without scanning; it does **not** throw (see the resume-reason table below). |
| `Peripheral.connect` | ensure + forward (`Peripheral.swift:165`) | ensure → **`applyManualConnectHold`** → wait → `reevaluateLink(.explicitConnect)`. The hold is registered before the wait so a `bluetoothPoweredOff` throw still leaves durable demand (D-hold) |
| `acquireWorkLease` | n/a | ensure → wait → acquire → `reevaluateLink` |
| Future FR-4/5 command submission | n/a | same wait at submission |
| `resumeRestoredScan` (`:819`) | stashes into `pendingRestoredScanServices`, defers | unchanged — this is an internal deferral, not an app-visible no-op |

**Signature changes:**

```swift
// ReliaBLEManager — breaking, acceptable pre-release
public func startScanning(services: sending [CBUUID]? = nil) async throws
```

**Error additions** in `Sources/ReliaBLE/Models/PeripheralError.swift`:

```swift
case bluetoothPoweredOff
case bluetoothUnsupported
```

Both go on `PeripheralError` rather than a new type or `AuthorizationError`: `bluetoothUnavailable` already lives there and is already thrown from the scan-adjacent paths, so splitting radio errors across two enums would make `startScanning` throw from two unrelated domains. `AuthorizationError` stays scoped to `authorizeBluetooth()`.

The Bluetooth state stream (`ReliaBLEManager.state`, `:101`) is unchanged and remains the supported way to gate UI — FR-1.4 requires both.

### D-3 Idle disconnect and Manual connect (#58)

**Config** — `Sources/ReliaBLE/ReliaBLEConfig.swift`:

```swift
public var idleDisconnectInterval: TimeInterval = 5.0
```

Validate finite and `>= 0` at actor init; `0` means "tear down as soon as demand hits zero". `BluetoothActor.init` takes it alongside `reconnectPolicy`.

**Handle methods** — `Sources/ReliaBLE/Models/Peripheral.swift`:

```swift
public func connect(autoReconnect: Bool = true) async throws {
    // 1. ensureCentralManager()
    // 2. applyManualConnectHold(id:reconnectDesired: autoReconnect)  — hold set FIRST
    // 3. try await waitUntilPoweredOn()   — may throw bluetoothPoweredOff / unsupported / unavailable
    // 4. try await reevaluateLink(id:reason: .explicitConnect)
}

public func disconnect() async throws {
    // applyManualDisconnect(id:)  — no radio wait; cancelling is always allowed
}
```

**Ordering is normative (D-hold).** Registering the hold at step 2 rather than after step 3 changes what a failed connect leaves behind:

| `autoReconnect` | Wait throws | App sees | When the radio returns |
|-----------------|-------------|----------|------------------------|
| `true` | Hold is already set and persisted | The typed error (e.g. `bluetoothPoweredOff`) | Event 12 re-issues — `wantsReconnect` is true |
| `false` | Hold is already set (demand true, `wantsReconnect` false) | The typed error | **No** re-issue — the issue gate refuses; idle stays suppressed |

The throw is informational, not destructive: the app learns Bluetooth is off *and* its intent is recorded.

**Logging (FR-9.2)** — info level, tagged `.category(.connection)` + `.peripheral(id)`, with distinct messages so the three causes are separable in Console: idle timer armed, idle disconnect fired, Manual connect, Manual disconnect. Connection/disconnection and scan start/stop logging already exist and is unchanged.

**DocC** — `GettingStarted.md` leads with the work-driven model and presents `connect`/`disconnect` as the Manual connect pair with an explicit "expected to be rare" framing, noting that a manual `connect` is **durable across relaunch** when `restoreIdentifier` is configured. `Topics/Background.md` documents the restore matrix (D-restore): a persisted manual-connect hold rehydrates and keeps the link; a restored link without a hold idles out; work never survives process death. It also states in one sentence that true continuous background scanning is FR-8.2 territory, not something a hold or lease implies.

### D-4 Reconnect gating (#59)

- Introduce `syncReconnectIntent(id:)`, called after every demand change: when `wantsReconnect(id)` is true, insert into `reconnectEnabled`; when false, remove and cancel the ladder task. When the change is **hold-driven** and `restoreIdentifier != nil`, it also writes the persisted hold map. **`syncReconnectIntent` is the sole persistence writer** — no other call site writes to disk. (Prose may call this "sync persisted holds" where that reads more clearly.)

**Persistence model (D-restore).** What is persisted is a **hold map**, not a reconnect-enabled set:

- **Encoding:** a dictionary `id → reconnectDesired: Bool`, namespaced by `restoreIdentifier`. A set of true-only ids is **insufficient** — it cannot represent a `connect(autoReconnect: false)` hold, which must survive restore as "suppress idle, but arm nothing." The existing array-of-ids encoding therefore changes shape; since a stale old-format value is simply not decodable as the new map, treat a decode failure as "no persisted holds" and move on. No migration shim.
- **Meaning:** "the app made a manual `connect` for this id and has not disconnected it," together with the `autoReconnect` value it asked for. This is durable demand, not a hint.
- **The restore-time read stays.** `handleWillRestoreState` (near `:768`–`:777`) reads the map back and rehydrates `manualConnectHold`. This reverses the earlier plan's "delete the restore-time read" — that reasoning depended on holds never being restored, which D-restore now requires.
- **Only three call sites touch disk, and two of them are removals:** `syncReconnectIntent` writes; `invalidatePeripherals` must **stop** writing (D-1 event 13); `shutdown()` must **never** write (D-1 event 14). Idle-timing out one restored link removes that id from the map — and must leave every other id's entry untouched, which the earlier bulk `removeAll()`-then-persist pattern did not guarantee.
- Rewrite the restore expectations `willRestoreSeedingReconnectOnlyForConnectedOrConnecting` and `willRestoreDoesNotRearmReconnectWithoutPersistedIntent` against hold rehydration rather than deleting them — the second in particular still has a job: a restored link with no persisted hold must **not** come back armed.
- `armReconnect` gates on `wantsReconnect(id)`, so a quiet peripheral never runs the ladder — the #59 acceptance criterion.
- Tier-0 ends because idle teardown routes through the intentional-cancel path, not because of any separate option-clearing call (none exists in CoreBluetooth).
- The grace-window blip that FR-1.2 explicitly accepts is handled by event 8: a Tier-0 reconnect landing with zero demand immediately re-arms the idle timer and is cancelled again.

**Carry-over from the prior critique** (`docs/reviews/auto-reconnect-backoff-plan-critique-2026-07-05.md`) that this work must close, since it is touching the same code: the `taskRegistry` cancel-during-sleep race (a cancel landing while the ladder task is sleeping, followed by a second schedule) and the incomplete `intentionalDisconnects` clearing paths on fail / give-up / success. The `idleGeneration` counter is the same defense applied to the idle timer.

### D-5 Work-driven auto-connect (#60)

**Internal types** on `BluetoothActor`:

```swift
struct WorkLeaseToken: Sendable, Hashable {
    let id: String
    let leaseID: UUID
}

func acquireWorkLease(id: String) async throws -> WorkLeaseToken
func releaseWorkLease(_ token: WorkLeaseToken) async

// Test-only hooks, matching the existing setReconnectPolicy / testInjectDisconnect style
func testWorkCount(for id: String) -> Int
func testHasManualConnectHold(for id: String) -> Bool
func setIdleDisconnectInterval(_ interval: TimeInterval)
```

Releasing an unknown or already-released token is a no-op (plus a debug log). This is enforceable only because `activeLeases` stores lease UUIDs (D-1): a bare `Int` refcount cannot tell a double-release of token A from a legitimate release of token B, and clamping at zero does not help — with two leases held, a double-release would drop the count to zero and tear down a link that still has work.

**Lease holders get no completion or failure signal.** `acquireWorkLease` returns once the connect has been *issued*, not completed; if the connect fails and the ladder exhausts, the holder learns nothing except through the connection-state stream. That is acceptable for an internal primitive whose only Phase-2 consumers are tests, but it is a deliberate limitation, not an oversight. **Phase 3 note:** the command queue will need an *await-linked* primitive (or per-command failure delivery) layered on top of the lease — do not let `ensureLinked`'s fire-and-forget shape get baked into the queue design by default.

Optional `@testable`-visible wrappers on `Peripheral` so lease tests read naturally without reaching through `manager.bluetooth`.

**Behavior:** acquiring a lease creates demand, which drives `reevaluateLink` — an auto-connect with no prior Manual `connect`, satisfying FR-11.1. Releasing the last lease drops demand and starts the idle grace, satisfying FR-1.5's "no pending work" clause.

**Leases are never persisted and never survive process death** (D-restore). Work is inherently process-scoped: a relaunched app has no in-flight commands, so resurrecting a lease would fabricate demand nobody asked for. Only manual-connect holds are durable.

**Phase 3/4 replacement path:** the per-peripheral serial command queue (FR-5.2.1) acquires a lease when it becomes non-empty and releases when it drains — either one queue-lifetime lease or per-command leases against the same refcount. `ensureLinked`, idle, and both reconnect tiers need no change; the queue simply becomes a second lease source alongside any future internal work.

### D-6 Concurrency and cancellation

- All demand, idle, and reconnect state is actor-isolated; no new locks and no cross-actor coordination. `Peripheral`'s `Mutex` state is untouched by this phase beyond the existing `connectionState` mirroring.
- **Two task registries, not one.** Idle tasks go in a separate `idleTaskRegistry` (same `TaskRegistry` type) rather than sharing keys with the reconnect ladder in `taskRegistry` — a peripheral can legitimately have both a ladder task and an idle task pending, and key collision would silently cancel the wrong one.
- Idle tasks capture `[weak self]` and re-check `idleGeneration` on wake, so a cancelled-then-rescheduled timer cannot fire from a stale task.
- PoweredOn waiters unwind on task cancellation and on `shutdown()`.
- Lease release after shutdown is a no-op.
- Actor serialization already guarantees `ConnectionStateChange` ordering (established in `docs/plans/connection-lifecycle-stream-2026-06-30.md`); nothing here introduces a second emission path — `setConnectionState` remains the sole write.

### D-7 Errors and edge cases

| Case | Behavior |
|------|----------|
| Scan while `.poweredOff` | Throws `bluetoothPoweredOff` immediately (D-radio) |
| Scan while `.resetting` / `.unknown` | Awaits; resolves to scanning on `.poweredOn`, or throws the matching typed error if the transient resolves to a terminal state |
| Scan while `.unsupported` | Throws `bluetoothUnsupported` |
| Scan while unauthorized | Throws `bluetoothUnavailable` (authorization is `authorizeBluetooth()`'s domain) |
| Waiting scan task cancelled via `Task.cancel` | `CancellationError`; continuation removed; no scan started |
| `stopScanning()` while a scan is parked on a transient state | Waiter resolves **successfully** (void), no scan starts — not an error (D-2) |
| A second `startScanning` supersedes a parked one | Earlier waiter completes successfully without scanning, or is coalesced — documented either way (D-2) |
| Connect / lease on never-seen id | `notFound` (D-never), raised after the radio gate |
| Connect on an orphaned handle (manager deallocated) | `bluetoothUnavailable` — existing Phase 1 behavior, unchanged |
| Last lease released while `.connecting` | Idle grace starts; if the connect completes, event 8 re-arms the timer and the link is cancelled |
| Manual `disconnect()` while work leases are held | Hold clears and the link is intentionally cancelled **once**; on the intentional `handleDidDisconnect` branch, a live lease triggers `reevaluateLink`, so work re-drives the connection. "Drop the hold" must not mean "strand pending work." |
| `connect(autoReconnect: false)` | Hold with `reconnectDesired == false`: suppresses idle, no Tier-0 option, no Tier-1 ladder — matching today's `autoReconnect: false` semantics |
| Demand present but radio drops to `.poweredOff` | Requires the D-1 event 13 change adding `.poweredOff` to the invalidate triggers: CB state and `connectionStates` clear (emitting `.disconnected(reason: .bluetoothUnavailable)`), demand is preserved, and `reevaluateLink` re-issues when the radio returns. **Without that change this path silently fails** — the stale `.connected` cache makes event 12 a no-op |
| Tier-1 gives up at `maxAttempts` | Existing terminal behavior; demand may still be present, and no stuck `.reconnecting` state (existing test coverage) |
| `connect(autoReconnect: false)` hold, then an unexpected drop, then a radio cycle | The link stays down. `reason == .radioReturned` with `wantsReconnect == false` does not satisfy the issue gate, so the sweep does not resurrect a link the app declined to auto-reconnect (D-1) |
| Restored link, no persisted hold | Idle timer starts at `.poweredOn`; link tears down after the interval (D-restore case 2) |
| Restored link **with** a persisted manual-connect hold | Hold rehydrates with its `reconnectDesired`; **no** idle timer; `reevaluateLink` if not already linked (D-restore case 1) |
| Restored persisted hold with `reconnectDesired: false` | Rehydrates: idle suppressed, but no Tier-0/Tier-1 arming and no radio-return re-issue (D-restore case 4) |
| Work leases at relaunch | Never restored — leases do not survive process death (D-restore case 3) |
| `connect(autoReconnect: true)` while `.poweredOff` | Hold is set and persisted, **then** the call throws `bluetoothPoweredOff`; when the radio returns, event 12 re-issues (D-hold) |
| `connect(autoReconnect: false)` while `.poweredOff` | Hold is set, then the call throws; the radio returning does **not** re-issue, but idle stays suppressed (D-hold) |
| Radio drops while a manual hold or lease wants reconnect | Event 13 emits `.disconnected(reason: .bluetoothUnavailable)` then `.reconnecting(source: .library, attempt: nil, nextRetryAt: nil)` — the app can tell "coming back" from "gone" |
| Radio drops with a `reconnectDesired: false` hold | Settles disconnected with **no** `.reconnecting` signal — nothing will re-issue, so claiming otherwise would be false |
| Peripheral not retrievable after `refreshPeripherals` | `.failed(reason: .notFound)` on the stream; **no scan, no retry loop**; the lease or hold is **retained** until the app releases it (D-never) |
| Manager shutdown with a persisted hold map | Volatile state clears; the persisted map on disk is **untouched** (D-1 event 14) |
| Manual `disconnect()` during a radio outage (no live `CBPeripheral`) | Hold clears, demand drops, returns **success** — nothing to tear down is not an error (D-1 event 4) |
| Demand drops while the state is library-`.reconnecting` | Ladder cancelled, settle synchronously to `.disconnected(reason: nil)`; no idle timer, no CB cancel against a disconnected peripheral |
| `reevaluateLink` throws `notFound` in delegate context | Publish `.failed(reason: .notFound)` on the connection-state stream so a stranded lease is observable |
| Double-release of a lease token while another lease is live | Removal of an absent UUID is a no-op; the surviving lease keeps demand and no idle teardown occurs |
| Restored link, app re-declares work or a manual-connect hold inside the grace window | Idle cancelled; link retained |
| `idleDisconnectInterval == 0` | Teardown fires as soon as demand hits zero (still asynchronously, via the same task) |
| Manager shutdown with leases outstanding | Waiters fail, tasks cancel, holds and counts clear; subsequent releases no-op |

### D-8 Rejected alternatives

| Alternative | Why rejected |
|-------------|--------------|
| One PR per sub-issue | Forces a throwaway dual connect path between merges; the demand signal is read by three of the four issues (**confirmed by user**) |
| `.poweredOff` awaits indefinitely | Relocates today's silent no-op into a silent hang; the app cannot distinguish "waiting for the user" from "wedged" without the state stream anyway (**overridden by user**) |
| Bounded `radioReadyTimeout` config | Adds a knob and a timeout error the PRD does not ask for, once `.poweredOff` fails fast; `.resetting`/`.unknown` are short-lived by construction |
| Restoration never re-applies a manual-connect hold (idle-always) | **Superseded 2026-08-05.** A manual `connect` is an explicit "keep this link" instruction and should outlive relaunch when restoration is configured; idle-always made restoration unable to deliver the standing-session behavior it exists for. NFR-3.2 is preserved for restored links the app never explicitly requested, which still idle out |
| Persisting a true-only set of reconnect-enabled ids | Cannot represent a `connect(autoReconnect: false)` hold, which must survive restore as "suppress idle, arm nothing". The hold map `id → reconnectDesired` can |
| Registering the manual-connect hold only after the radio wait succeeds | **Superseded 2026-08-05.** A `connect(autoReconnect: true)` issued while Bluetooth is off would throw and leave no demand, so the radio returning would do nothing — contradicting what `autoReconnect: true` promises |
| Throwing `CancellationError` from a parked scan waiter when `stopScanning` supersedes it | **Superseded 2026-08-05.** Start-then-stop is a sequence the app requested and completed; only `Task.cancel` is a true cancellation |
| Leaving auto-relinking peripherals at `.disconnected(.bluetoothUnavailable)` with a `nil` handle after a radio drop | With no public demand API in Phase 2, `ConnectionState` is the only channel that can distinguish "will come back" from "gone"; a bulk nil-out destroys that information |
| A library-owned scan to recover a `notFound` peripheral under demand | Would be a second connection/scan stack in Phase 2, which FR-11.4 forbids; continuous and demand-driven scan policy belongs to FR-8.2 / FR-4. The additive hook (event 15) keeps the door open |
| Public work-lease API now (`Peripheral.withLink { }`) | Public surface that FR-4/FR-5 would immediately supersede; pre-release breakage is cheap but unnecessary surface is not (**confirmed by user**) |
| Await discovery for never-seen ids | Unbounded wait coupled to scan policy, with a second cancellation story |
| Full injectable `Clock` abstraction | Larger than this phase needs and would churn every existing reconnect test; `ReconnectPolicy` already proves interval override is sufficient |
| Separate idle-grace interval config | PRD names no grace duration; a second knob would be unexplained surface |
| Sharing `taskRegistry` between idle and reconnect tasks | Key collision silently cancels the wrong task when a peripheral has both pending |
| Leaving `.poweredOff` non-invalidating and instead verifying `cbPeripherals[id]?.state` inside `reevaluateLink` | A viable fix for the same bug, but it leaves `connectionStates` reporting `.connected` for a dead link on the public stream. Invalidating is both simpler and more honest to observers. The state verification is retained anyway as a belt-and-braces check |
| Tracking work as a bare `Int` refcount | Cannot distinguish a double-release of one token from a legitimate release of another; tears down links that still have work |
| Approach A (app-only explicit connect) | PRD mandates Approach B |

## File-by-file impact

| File | Change | Driven by | Depends on |
|------|--------|-----------|------------|
| `Sources/ReliaBLE/ReliaBLEConfig.swift` | Add `idleDisconnectInterval: TimeInterval = 5.0` + docs | FR-1.5 | — |
| `Sources/ReliaBLE/Models/PeripheralError.swift` | Add `bluetoothPoweredOff`, `bluetoothUnsupported`; document wait-vs-fail policy | #57 | — |
| `Sources/ReliaBLE/BluetoothActor.swift` | PoweredOn continuations + resolver (re-check on resume, resume-reason enum); `activeLeases` / `manualConnectHold` / `idleGeneration` / `idleTaskRegistry`; extract a side-effect-free `issueConnect`; add `reevaluateLink(id:reason:)`, `beginIdleGrace`, `fireIdle`, `syncReconnectIntent`, `applyManualConnectHold`, `applyManualDisconnect`, lease API; gate `armReconnect` on `wantsReconnect`; add `.poweredOff` to the invalidate triggers; **stop** writing persistence from `invalidatePeripherals` and from `shutdown()`; preserve `pendingRestoredScanServices` across power-cycle invalidate; per-id `.reconnecting(.library, nil, nil)` projection replacing the bulk `clearConnectionStates` nil-out; change persistence to a hold map and **keep** the restore-time read, rehydrating holds; replace the scan `.poweredOn` guard; `stopScanning` resolves parked waiters successfully; FR-9.2 logging; test hooks | all four issues | config, errors |
| `Sources/ReliaBLE/Models/Peripheral.swift` | `connect` becomes ensure → `applyManualConnectHold` → wait → `reevaluateLink` (hold before wait); `disconnect` routes to `applyManualDisconnect`; optional `@testable` lease wrappers | #57, #58 | actor |
| `Sources/ReliaBLE/ReliaBLEManager.swift` | `startScanning` becomes `async throws` with `withTaskCancellationHandler`; pass `idleDisconnectInterval` into `BluetoothActor.init` | #57, #58 | actor |
| `Sources/ReliaBLE/Models/ConnectionState.swift` | Docs only — idle teardown surfaces as an intentional `.disconnected(reason: nil)`; and on `.reconnecting`, a `nil` `attempt` / `nextRetryAt` means "waiting for the radio, not yet on the backoff ladder," distinct from an armed ladder step that carries real values | FR-11.5, D-1 event 13 | — |
| `Sources/ReliaBLE/Documentation.docc/GettingStarted.md` | Work-driven model first; `connect`/`disconnect` reframed as Manual connect hold; `try` on scan examples | FR-11.2 | API |
| `Sources/ReliaBLE/Documentation.docc/Topics/Background.md` | Manual-connect holds survive relaunch when restoration is configured; restored links **without** a hold idle out; work never survives process death; one sentence that true continuous background scanning is FR-8.2, not Phase 2 demand | D-restore | API |
| `Sources/ReliaBLE/Documentation.docc/Topics/Concurrency.md` | Scan now throws; cancellation unwinds a pending radio wait | #57 | API |
| `Tests/ReliaBLETests/ReliaBLEManagerTests.swift` | `try` on all `startScanning` sites; new PoweredOn, idle, lease, gating, and restore tests; short idle interval via the test hook | NFR-2.1 | all |
| `PRD.md` | Check off FR-1.4, FR-1.5, FR-11.1–11.5 as delivered | bookkeeping | after impl |
| `Demo/` | Handle `try await startScanning`; optionally surface the idle interval in Settings | compile | library |
| `Package.swift`, `CBCentralManagerFactory.swift`, `CoreBluetoothMockAliases.swift` | **No change** | — | — |

## Risks and migration

- **Breaking:** `startScanning` becomes `async throws`. Every call site in tests, the Demo, and DocC examples must add `try`. Pre-release, so no deprecation path — see AGENTS.md.
- **Persistence changes shape.** The `restoreIdentifier`-keyed UserDefaults value goes from an array of reconnect-enabled ids to a **hold map** (`id → reconnectDesired`), written only by `syncReconnectIntent` and read back at restore to rehydrate manual-connect holds (D-4). A value written by an older build will not decode as the new map; treat a decode failure as "no persisted holds". Pre-release, so no migration shim — the practical effect is that one relaunch after upgrading loses standing holds.
- **Restored holds keep links alive across relaunch.** This is the intended reversal (D-restore), but it does mean a manual `connect` now has battery consequences that outlive the process. NFR-3.2 is preserved only for links the app never explicitly requested. DocC must make the durability explicit so the cost is a choice, not a surprise.
- **`shutdown()` must never write to disk.** An empty flush at shutdown would erase the persisted hold map and silently destroy a standing session — the failure would surface only after a relaunch, making it easy to miss in review. Worth an explicit test (`shutdownLeavesPersistedHoldsIntact`).
- **Tier-0 cannot be enabled on an already-live link.** CoreBluetooth has no API to change connect options mid-connection, so a link established without Tier-0 that later gains reconnect-wanting demand only picks up the option on the next connect issue. Document; do not work around by cycling the link.
- **Idle-timing flakiness.** Mitigated by the interval override, the `idleGeneration` guard, and reusing the existing `pollUntil` helpers rather than fixed sleeps.
- **Adding `.poweredOff` to the invalidate triggers changes observable behavior.** A power-off now emits `.disconnected(reason: .bluetoothUnavailable)` and clears `cbPeripherals`, where today it emits nothing. This is required for demand to survive a radio cycle (D-1 event 13), but existing power-cycle tests will see the new emission and the recovery path depends on `refreshPeripherals` re-populating from `retrievePeripherals`.
- **Cancel-without-callback.** CoreBluetooth does not guarantee a terminal delegate callback for a cancel issued against a pending connect or a peripheral in OS-reconnect limbo. The settling rule (D-1) confines optimistic `.disconnecting` to genuinely `.connected` peripherals so that a missing callback cannot strand state, but the `.connecting`-cancel case still depends on CB delivering `didFailToConnect` or `didDisconnect` — see the unknowns table.
- **Manual disconnect racing pending work** is the subtlest behavior in the plan and needs its own test (`disconnectWithActiveLeaseRelinks`).
- **Mock coverage gaps (#40, #42)** mean the Tier-0 give-up handoff and the real grace-window blip cannot be exercised end-to-end. Use `testInjectDisconnect(for:isReconnecting:error:)` for the ladder paths and record the rest as on-device checks.
- **Rollback:** revert the PR. No persisted-data migration to undo.

## Implementation order

One branch, `51-work-driven-connection-lifecycle`. Each numbered step is a green commit (`swift build` + `swift test` pass); the whole set lands as a single PR because public connect semantics are inconsistent mid-sequence.

1. **Config + errors** — `idleDisconnectInterval`, `bluetoothPoweredOff`, `bluetoothUnsupported`. No behavior change.
2. **PoweredOn await infrastructure** — continuations, `resolvePoweredOnWaiters` wired into `handleCentralManagerStateUpdate`, cancellation helper, test hook for waiter count. Not yet called from app paths.
3. **Wire the radio gate into scan and connect** — `startScanning` becomes `async throws`; `Peripheral.connect` awaits; migrate existing call sites and Demo. → **checkpoint #57**.
4. **Demand substrate** — `activeLeases`, `manualConnectHold`, `syncReconnectIntent`, extract `issueConnect`, add `reevaluateLink(id:reason:)`, `applyManualConnectHold` / `applyManualDisconnect`, lease API and test hooks. Manual connect now sets a hold **before** the radio wait; no idle behavior yet.
5. **Idle grace and teardown** — `idleTaskRegistry`, `idleGeneration`, `beginIdleGrace` / `fireIdle`, the event-8 blip path, FR-9.2 logging, `setIdleDisconnectInterval` test hook. → **checkpoint #58**.
6. **Reconnect gating, radio-drop projection, and restore** — `armReconnect` gates on `wantsReconnect`; `handleDidDisconnect` handles the untrusted-Tier-0 and work-relink branches; `.poweredOff` joins the invalidate triggers, `invalidatePeripherals` stops writing persistence and preserves the deferred restored scan, and the per-id `.reconnecting(.library, nil, nil)` projection replaces the bulk nil-out; persistence becomes a hold map that restore reads back to rehydrate holds; `shutdown()` is audited for disk writes; close the two carry-over items from the prior reconnect critique. → **checkpoint #59, and #60's idle-cycle criterion**.
7. **DocC, Demo, PRD checkboxes.**
8. **Full `swift test` + DocC build with warnings as errors.**

## Verification

### Test cases to add or adapt — `Tests/ReliaBLETests/ReliaBLEManagerTests.swift`

| Test | Asserts |
|------|---------|
| `startScanningFailsWhenPoweredOff` | `simulatePowerOff` → `startScanning` throws `bluetoothPoweredOff`; no scan started |
| `startScanningFailsWhenUnsupported` | throws `bluetoothUnsupported` |
| `startScanningAwaitsTransientState` | parked in `.resetting`/`.unknown` → resolves on `.poweredOn` → scanning |
| `transientStateResolvingToPoweredOffFailsWaiter` | parked waiter fails `bluetoothPoweredOff` rather than hanging |
| `stopScanningCompletesParkedScanWaiterSuccessfully` | `startScanning` parked on a transient state, then `stopScanning` → waiter returns **successfully**, no scan starts, no error thrown (D-2) |
| `supersededScanWaiterCompletesWithoutScanning` | a second `startScanning` while the first is parked → the first completes successfully (or is coalesced, per implementation) |
| `connectAwaitsTransientState` | `Peripheral.connect` parked on `.resetting`/`.unknown` proceeds on `.poweredOn` — a distinct code path from scan |
| `connectPoweredOffSetsHoldAndRelinksOnPowerOn` | `connect(autoReconnect: true)` while powered off throws `bluetoothPoweredOff`, **the hold is still set and persisted**, and the link establishes when the radio returns (**D-hold**) |
| `connectAutoReconnectFalsePoweredOffDoesNotRelinkOnPowerOn` | same setup with `autoReconnect: false` → hold set, throws, and the radio returning does **not** re-issue |
| `connectTransientResolvingToPoweredOffThrows` | connect-side analog of the scan waiter failure |
| `startScanningCancellationUnblocksWaiter` | cancelling the awaiting task throws `CancellationError` and leaves no continuation |
| `connectFailsWhenPoweredOff` | same contract on `Peripheral.connect` |
| `workLeaseAutoConnectsWithoutPriorConnect` | acquire a lease on a discovered id → reaches `.connected` with no `connect()` call (**#60**) |
| `idleDisconnectAfterLastLeaseReleased` | short interval; release → clean `.disconnected(reason: nil)` within the interval (**#58**, **#60**) |
| `manualConnectHoldSuppressesIdle` | `connect()` then quiet for 3× the interval → still `.connected` |
| `manualDisconnectClearsHoldAndTearsDown` | `disconnect()` → intentional clean disconnect, no ladder armed |
| `disconnectWithActiveLeaseRelinks` | hold + lease → `disconnect()` → link cancels once then work re-drives it back to `.connected` |
| `tier1DoesNotArmWhenQuiet` | no demand → `testInjectDisconnect(isReconnecting: false)` → no `.reconnecting(.library)` emitted (**#59**) |
| `tier1ArmsWhileLeaseHeld` | lease held → injected drop → ladder runs |
| `tier0BlipDuringGraceRearmsIdle` | connect via lease, release, simulate a reconnect landing during grace → idle timer re-arms and the link is cancelled again |
| `autoReconnectFalseHoldSuppressesBothTiers` | `connect(autoReconnect: false)` → no Tier-0 option, no ladder, idle still suppressed |
| `restoredLinkWithoutHoldIdlesOut` | restore a connected peripheral with **no** persisted hold → disconnected after the short interval (**D-restore case 2**) |
| `restoredManualHoldSurvivesRelaunch` | persist a hold, restore → hold rehydrates, **no** idle teardown, link retained or re-established (**D-restore case 1**) |
| `restoredHoldWithAutoReconnectFalseSuppressesIdleButNotTier1` | persisted hold with `reconnectDesired: false` → idle suppressed, no ladder, no radio-return re-issue (**D-restore case 4**) |
| `workLeasesDoNotSurviveRelaunch` | leases are never rehydrated from disk (**D-restore case 3**) |
| `restoredLinkRetainedWhenWorkDeclared` | restore with no hold, acquire a lease inside the grace window → link retained |
| `shutdownLeavesPersistedHoldsIntact` | hold persisted → `shutdown()` → the on-disk map is unchanged (**D-1 event 14**) |
| `invalidateDoesNotWipePersistedHolds` | hold persisted → transient `.resetting` → the on-disk map is unchanged |
| `demandSurvivesRadioCycleAndRelinks` | lease held → `simulatePowerOff` → `.disconnected(reason: .bluetoothUnavailable)` → `simulatePowerOn` → link re-established without re-acquiring. Guards the D-1 event 13 `.poweredOff` invalidate fix; **automatable today** — the mock supports power cycling and existing tests already use it |
| `radioDropWithWantsReconnectShowsReconnecting` | hold or lease with reconnect → power off → stream shows `.disconnected(.bluetoothUnavailable)` **then** `.reconnecting(source: .library, attempt: nil, nextRetryAt: nil)`, and the handle is not left `nil` (**D-1 event 13 step 3**) |
| `radioDropWithoutWantsReconnectShowsNoReconnecting` | `connect(autoReconnect: false)` hold → power off → settles disconnected with **no** `.reconnecting` emission (**step 4**) |
| `deferredRestoredScanSurvivesPowerCycle` | restored scan pending, power off/on → the scan still resumes (**D-1 event 13**); skip with the FR-8.2 open item if preservation is deferred |
| `manualDisconnectDuringRadioOutageSucceeds` | hold held, radio `.resetting`, `disconnect()` returns success and drops demand |
| `noReconnectHoldIsNotResurrectedByRadioCycle` | `connect(autoReconnect: false)` → drop → power cycle → link stays down |
| `idleWhileLibraryReconnectingSettlesCleanly` | demand drops during a Tier-1 backoff sleep → ladder cancelled, `.disconnected(reason: nil)`, no stuck `.disconnecting` |
| `strandedLeaseSurfacesFailure` | lease held, peripheral no longer retrievable after invalidate → `.failed(reason: .notFound)` on the stream, **and the lease is still held afterwards** — demand must not be silently dropped, and no scan or retry loop starts (**D-never**) |
| `discoveryRelinksDemandedPeripheral` | demand held on an id that failed with `notFound` → an app-driven scan rediscovers it → `reevaluateLink` links it (**event 15**; skip if the optional polish is deferred) |
| `leaseOnNeverSeenIdThrowsNotFound` | **D-never** |
| `doubleReleaseIsNoOp` | **two** leases held; releasing token A twice leaves demand intact via lease B and triggers no idle teardown. Written with a single lease this test passes even against the broken refcount design, so two is load-bearing |
| Existing reconnect + connection-lifecycle tests | Updated for `try startScanning` and for demand-gated arming (`autoReconnect: false` ⇒ hold without `reconnectDesired`) |

### Commands

```sh
swift build
swift test
swift test --filter ReliaBLETests.workLeaseAutoConnectsWithoutPriorConnect
swift test --filter ReliaBLETests.idleDisconnectAfterLastLeaseReleased
swift test --filter ReliaBLETests.tier1DoesNotArmWhenQuiet
swift test --filter ReliaBLETests.restoredLinkWithoutDemandIdlesOut
swift package generate-documentation --target ReliaBLE --warnings-as-errors
```

Demo builds go through XcodeBuildMCP per `Demo/AGENTS.md` — delegate that to a sub-agent and have it read `Demo/AGENTS.md` first.

### Manual / on-device (non-blocking, mock-limited)

- Tier-0 OS give-up budget and the true→false `isReconnecting` handoff (blocked by #40).
- A real Tier-0 reconnect landing inside the idle grace window.
- `willRestoreState` end-to-end after a real relaunch, confirming that a persisted manual-connect hold rehydrates and keeps the link, while a restored link without a hold idles out (blocked by #42).
- Battery impact of durable holds across relaunch on a real device, since D-restore intentionally keeps those links alive (NFR-3.2).
- Cancel-callback behavior on a real radio for a pending connect and an OS-reconnecting link (the mock half is an automated exploratory test).

(The Bluetooth off/on cycle is **not** listed here — the mock supports `simulatePowerOff`/`simulatePowerOn`, so it is covered by the automated `demandSurvivesRadioCycleAndRelinks`.)

## Issue-to-work mapping

| Issue | Commits | Public API delta |
|-------|---------|------------------|
| #57 | 1–3 | `startScanning` becomes `async throws`; `bluetoothPoweredOff` / `bluetoothUnsupported` error cases |
| #58 | 1, 5, 7 | `ReliaBLEConfig.idleDisconnectInterval`; `connect`/`disconnect` reframed as a Manual connect hold; FR-9.2 logging; DocC |
| #59 | 6 | No new API — behavioral reconnect gating and restore semantics |
| #60 | 4, 6 | None (internal lease + test hooks only, per D-work) |

## Unknowns to validate during implementation

| Unknown | How to settle it |
|---------|------------------|
| Callback guarantees for `cancelPeripheralConnection` against a **pending connect** and against a peripheral in **OS-reconnect limbo** — on the mock *and* on device | One exploratory test for the mock during commit 5; on-device check for the OS. The settling rule (D-1) already covers the limbo case by settling synchronously; the open half is whether cancelling during `.connecting` reliably produces `didFailToConnect`/`didDisconnect`, and if not, whether `.disconnecting` needs a watchdog |
| Whether `refreshPeripherals` reliably re-populates `cbPeripherals` after a `.poweredOff` invalidate | Covered by `demandSurvivesRadioCycleAndRelinks`; if `retrievePeripherals` does not return the id, the `.failed(reason: .notFound)` surfacing path (D-1 event 5) is what the app sees — terminal, with demand retained and no scan |
| Whether preserving `pendingRestoredScanServices` across a power-cycle invalidate is achievable without inventing scan-demand semantics | Attempt during commit 6. If it is not clean, leave today's clearing behavior and file the one-line open item owned by FR-8.2: *power-cycle may drop a deferred restored scan until continuous-scan demand is defined* |
| Whether any existing persistence writer is reachable from `shutdown()` | Audit during commit 6; `shutdownLeavesPersistedHoldsIntact` is the regression guard |
| Whether `startScanning` should throw `bluetoothUnavailable` or an authorization error when the central cannot be created due to authorization | Match `connect`'s existing contract — `bluetoothUnavailable` — and keep `AuthorizationError` on `authorizeBluetooth()` only |
| Whether `resumeRestoredScan`'s deferral needs to become a real waiter now that scan awaits | Read the restore path during commit 3; if the deferral and the waiter can both be pending, collapse to one mechanism |
| DocC symbol-link fallout from `startScanning` gaining `throws` | The docs build in step 8 |

> Line numbers in `## Background` were captured on the `50-peripheral-handle-type-model` branch and will drift. Navigate by symbol name.

## References

- `PRD.md` — Architecture (Connection model), FR-1.2/1.3.1/1.4/1.5, FR-4.4–4.7, FR-5.2, FR-8.2.1/8.6, FR-9.2, FR-11, NFR-1.3/2.1/3.2
- GitHub: [#51](https://github.com/Five3Apps/ReliaBLE/issues/51), [#57](https://github.com/Five3Apps/ReliaBLE/issues/57), [#58](https://github.com/Five3Apps/ReliaBLE/issues/58), [#59](https://github.com/Five3Apps/ReliaBLE/issues/59), [#60](https://github.com/Five3Apps/ReliaBLE/issues/60); blocked-by [#50](https://github.com/Five3Apps/ReliaBLE/issues/50), next [#52](https://github.com/Five3Apps/ReliaBLE/issues/52); mock gaps [#40](https://github.com/Five3Apps/ReliaBLE/issues/40), [#42](https://github.com/Five3Apps/ReliaBLE/issues/42)
- `docs/plans/auto-reconnect-backoff-2026-07-05.md` + `docs/reviews/auto-reconnect-backoff-plan-critique-2026-07-05.md`
- `docs/plans/connection-lifecycle-stream-2026-06-30.md`
- `docs/plans/background-scanning-state-restoration-2026-07-13.md`
- `docs/plans/peripheral-handle-type-model-2026-07-31.md` + `docs/reviews/peripheral-handle-type-model-plan-critique-2026-07-31.md`
- `docs/plans/corebluetoothmock-upstream-gaps-2026-07-21.md`
- `docs/reviews/work-driven-connection-lifecycle-poweredoff-feedback-2026-08-05.md` — user review of the powered-off behavior, rolled into this plan on 2026-08-05. It **reverses** the original D-restore (holds are now durable and the restore-time read stays), moves manual-hold registration ahead of the radio wait, adds the `.reconnecting(.library, nil, nil)` projection on radio drop, changes parked-scan-waiter resolution, preserves the deferred restored scan, and hardens `shutdown()` against disk writes. Where it conflicts with the earlier critique, this feedback wins.
- `docs/reviews/work-driven-connection-lifecycle-plan-critique-2026-08-02.md` — the design critique of this plan. Its five confirmed findings (stale `.poweredOff` state, self-erasing persisted intent, the `reconnectDesired: false` contradiction, lease double-release bookkeeping, and cancel-against-not-connected teardown) are all resolved inline above; the critique is retained for the code-level evidence behind each correction.
- DocC catalog: `Sources/ReliaBLE/Documentation.docc/` — `GettingStarted.md`, `Topics/Background.md`, `Topics/Concurrency.md`, `Topics/Multi-Manager.md`
