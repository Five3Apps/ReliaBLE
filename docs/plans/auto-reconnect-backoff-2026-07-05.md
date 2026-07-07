# Automatic Reconnection with Exponential Backoff: Plan
*Issue #37 · 2026-07-05*

## Goal

Deliver ReliaBLE's headline reliability feature: when a connected peripheral drops unexpectedly (or an initial connect fails transiently), reconnect automatically instead of forcing the integrating app to retry. **Lean on iOS's own daemon-level auto-reconnect first** (`CBConnectPeripheralOptionEnableAutoReconnect`, always available on this iOS 18+ library) and **supplement it with app-side exponential backoff** only where the OS doesn't help. Enable/disable is a per-connect choice; backoff tuning lives in config. Surface progress — system-driven vs. library-driven, with attempt/next-retry timing where known — through the existing `connectionStateChanges` stream. Ship a Demo that makes it observable.

Covers **FR-1.2** (auto-reconnect with exponential backoff) and the reconnection half of **FR-1.3.1** (connection-stability status). Builds directly on #36. Background operation (state restoration + `bluetooth-central`) is a deliberate **follow-up**, not in scope here.

## Background

#36 is fully merged (commit `e8d3a4e`, "Added full connection handling and state reporting"). All state below verified by exploration.

### Library — connection lifecycle (`Sources/ReliaBLE/`)
- All BLE state lives in `@globalActor actor BluetoothActor` (`BluetoothActor.swift:81`). No `BluetoothManager.swift` — that name in AGENTS.md refers to this actor.
- Connect / disconnect entry points: `connect(id:)` (`BluetoothActor.swift:703`) sets `.connecting`, broadcasts, calls `centralManager.connect(cbPeripheral, options: nil)` — **no connect options today**. `disconnect(id:)` (:730) sets `.disconnecting`, broadcasts, calls `cancelPeripheralConnection`.
- Public connect surface is `ReliaBLEManager.connect(to:)` — a single-argument signature that this plan changes.
- Delegate shim (`BluetoothDelegateShim`, :775–792) yields `DelegateEvent`s drained by one long-lived `delegateEventTask` through `process(_:)` (:342). Handlers:
  - `handleDidConnect` (:656) → `.connected`
  - `handleDidDisconnect` (:666) → `.disconnected(reason:)`. Receives the 5-param `didDisconnectPeripheral:timestamp:isReconnecting:error:`; **`isReconnecting` is currently ignored**, `error` is mapped `CBError? → PeripheralError?`.
  - `handleDidFailToConnect` (:682) → `.failed(reason:)`
- **iOS auto-reconnect (iOS 17+, always available here).** `CBConnectPeripheralOptionEnableAutoReconnect` asks the system to re-establish a link that drops **after a successful connection** (not initial-connect failures, not app-initiated cancels). When active, the drop arrives via the 5-param delegate with `isReconnecting == true`, and a later `didConnect` follows if the system succeeds; the system's give-up is a *second* `didDisconnect` with `isReconnecting == false`. The OS give-up budget/timing is not publicly documented (verify on-device). The library passes this option nowhere today and always runs its own logic.
- `ConnectionState` (`Models/ConnectionState.swift:30`): `.connecting`, `.connected`, `.disconnecting`, `.disconnected(reason: PeripheralError?)`, `.failed(reason: PeripheralError?)`. **No `.reconnecting` case; no attempt/retry metadata.** `ConnectionStateChange { peripheralId: String; state: ConnectionState }` (:54).
- Stream: `connectionStateChangesStream()` (:190) → shared `AsyncStream<ConnectionStateChange>`, **no replay**. Snapshot: `currentConnectionStates: [String: ConnectionState]` (actor :247, façade `ReliaBLEManager.swift:105`). Public property `connectionStateChanges` (`ReliaBLEManager.swift:98`).
- Peripheral tracking: live refs `cbPeripherals: [String: CBPeripheral]` (:116, never escape actor); state registry `connectionStates: [String: ConnectionState]` (:129), same key.
- **Config does not reach the actor today.** `ReliaBLEManager.init` (`ReliaBLEManager.swift:52`) passes only a `LoggingService` in via `Task { await BluetoothActor.shared.ensureInitialized(log:) }` (:63). `ReliaBLEConfig` (`ReliaBLEConfig.swift:35`) is a flat `Sendable` struct of `public var` fields + no-arg `init()`; backoff policy will need a new path into the actor.
- No `Task.sleep`, `Timer`, or `Clock` exists inside `@BluetoothActor` today — only continuations (`withCheckedThrowingContinuation` for auth) and the delegate drain `Task`.

### Tests / mock harness (`Tests/ReliaBLETests/`, `Sources/ReliaBLEMock/`)
- `@Suite(.serialized)` (`ReliaBLEManagerTests.swift:56`) — process-wide singleton state. `Mock.makeManager()` → `SimulationConfig.ensureConfigured()` (:806) does one-time `simulateInitialState(.poweredOn)` / `simulatePeripherals` / `simulateAuthorization`.
- Unexpected-drop primitive already used: `Mock.connectionTestSpec.simulateDisconnection()` (:568, 580, 588, 594) triggers the `didDisconnect` path. Connect outcome controlled by `ConnectionTestDelegate.connectionResult: Result<Void, Error>` (:686).
- `CoreBluetoothMock` exposes `CBConnectPeripheralOptionEnableAutoReconnect` as an alias (`Sources/ReliaBLEMock/CoreBluetoothMockAliases.swift`), but whether it **simulates** the OS auto-reconnect state machine (`isReconnecting: true → didConnect`, or `true → false` give-up) is unconfirmed — a prerequisite check for Tier-0 test coverage.
- **No injected clock.** Timed behavior is observed with real-time `Task.sleep` and `pollUntil(timeout: 3.0)` (:929). Mock connection callback fires on a ~0.045 s async timer (:599). `Tests/ReliaBLETests/Mocks/` is empty.

### Demo (`Demo/ReliaBLE Demo/`)
- Separate project — read `Demo/CLAUDE.md` first, use XcodeBuildMCP. #36 added connect/disconnect + connection-state consumption in the Central detail UI (commit `b6371b8`). The `connect(to:)` call site and `SettingsView.swift` are the touch points.

## Approach

**Two-tier model: OS-managed reconnect is primary; the library supplements.** iOS 18+ means `CBConnectPeripheralOptionEnableAutoReconnect` is always available, so we defer to the daemon-level reconnect first and add app-side backoff only where the OS option doesn't reach.

- **Tier 0 — OS-managed (primary).** A connection requested with auto-reconnect on passes `[CBConnectPeripheralOptionEnableAutoReconnect: true]`. After an unexpected drop, iOS re-establishes the link itself — daemon-held, power-efficient, and it keeps trying across app suspension. `handleDidDisconnect` **must honor `isReconnecting`** (ignored today): `true` → emit `.reconnecting(source: .system, …)` and **do not** arm the library ladder (a later `didConnect` is coming); `false` + unexpected → the OS gave up → hand off to Tier 1.
- **Tier 1 — library-managed (supplement).** Exponential backoff covers what the OS option does not: initial `connect()` failures (`handleDidFailToConnect`; the OS option only applies after a link existed) and post-OS-give-up drops. This is where `maxAttempts`, the terminal give-up state, and the UI countdown live. It's the deterministic, observable safety net beneath the OS's undocumented budget.

**Enable/disable is per-connect; behavior is config.** Reconnection *intent* is a property of a connection (a persistent lock vs. a one-shot sensor), and CoreBluetooth models it per-`connect()`, so it belongs on the public API rather than global config:

- Public API: **`connect(to peripheral: Peripheral, autoReconnect: Bool = true)`** (`ReliaBLEManager.swift`). Default `true` delivers the headline promise; opt out per call. **Breaking change** to the existing `connect(to:)` signature (pre-1.0, acceptable). The flag gates **both** tiers for that peripheral: whether the OS option is passed *and* whether the library ladder may arm.

**Config — behavior only.** Nested `ReconnectPolicy: Sendable` beside `ReliaBLEConfig` (`ReliaBLEConfig.swift`) holds *how* the supplement retries: `maxAttempts`, `initialDelay: TimeInterval`, `maxDelay: TimeInterval`, `jitter: Double`, with sane defaults. `ReliaBLEConfig` gains `var reconnectPolicy = ReconnectPolicy()`. **No `enabled` field** (superseded by the per-connect flag) and **no OS/library strategy toggle** — the tiers compose, and library-only has no use case. Plumb the policy into the actor by extending `ensureInitialized` (today it carries only `LoggingService`).

**State.** Add one non-terminal public case: `ConnectionState.reconnecting(source: ReconnectSource, attempt: Int?, nextRetryAt: Date?)` with `public enum ReconnectSource { case system, library }` (`Models/ConnectionState.swift`). OS-driven reconnects are `.system` with `nil` attempt/date (iOS exposes neither); library-driven are `.library` with both populated (`Date` gives the Demo a countdown target). Stays `Sendable`/`Equatable`/`Hashable`. Breaking change the Demo's `switch` handles.

**Scheduler.** On `@BluetoothActor`, add isolated state: `reconnectPolicy: ReconnectPolicy`, `reconnectEnabled: Set<String>` (per-connect intent — the Tier-1 gate), `reconnectAttempts: [String: Int]` (attempt counter across delegate events), `reconnectTasks: [String: Task<Void, Never>]` (cancellable pending retry).

- **`connect(id:autoReconnect:)`.** If `autoReconnect`: insert `id` into `reconnectEnabled` and pass `[CBConnectPeripheralOptionEnableAutoReconnect: true]`; else remove `id` and pass `options: nil`.
- **`handleDidDisconnect` (:666).** Honor `isReconnecting`: `true` → emit `.reconnecting(source: .system, attempt: nil, nextRetryAt: nil)`, return (OS owns it). `false` → if `id ∈ intentionalDisconnects`, clear it and stop; else the OS is done → `armReconnect(id:)`.
- **`handleDidFailToConnect` (:682).** Initial-connect failure (OS option never applies) → `armReconnect(id:)`.
- **`armReconnect(id:)` — single choke point (Tier 1).** Return early if `id ∉ reconnectEnabled`, or `reconnectAttempts[id] >= maxAttempts` (give-up: leave the terminal state, clear `reconnectAttempts[id]`). Otherwise increment `reconnectAttempts[id]` and call `scheduleReconnect(id:attempt:)`.
- **`scheduleReconnect(id:attempt:)`.** Cancel+replace any `reconnectTasks[id]`; compute the backoff delay; emit `.reconnecting(source: .library, attempt: attempt, nextRetryAt: now + delay)`; store a `Task` that `Task.sleep`s, then — only if `!Task.isCancelled` and `cbPeripherals[id]` still exists — calls `connect(id:autoReconnect: true)` (re-passing the OS option so a successful retry re-arms Tier 0). Actor isolation + cancel-before-replace + post-sleep guards close the double-schedule and stale-fire races.
- **Recovery.** `handleDidConnect` (:656) clears `reconnectAttempts[id]` and `reconnectTasks[id]`, discards stale `intentionalDisconnects[id]`. Leaves `reconnectEnabled` intact — intent persists across drops.
- **Explicit disconnect.** `disconnect(id:)` (:730) inserts `id` into `intentionalDisconnects`, removes it from `reconnectEnabled`, cancels+removes `reconnectTasks[id]`/`reconnectAttempts[id]`, then sets `.disconnecting`.
- **Teardown.** `invalidatePeripherals` (:619, clears `connectionStates` today) also cancels all `reconnectTasks` and clears `reconnectEnabled`/`reconnectAttempts`.

**Backoff math** — exponential `initialDelay * 2^(attempt-1)` capped at `maxDelay`, then `±jitter` via `Double.random`; two lines, not elaborated.

**Tests.** Mock-driven where possible. **First verify CoreBluetoothMock capability**: does it honor `CBConnectPeripheralOptionEnableAutoReconnect` and emit the `isReconnecting: true → didConnect` / `true → false` give-up sequence? If not, drive Tier-0 by injecting delegate events directly (or accept it as device/manual-only). Tier 1, intentional-disconnect, and initial-failure paths stay fully mock-testable. Use a tiny `ReconnectPolicy` (Q4) and assert emission *sequence and count*, not exact timing. Cover: initial-failure ladder → recovery; give-up after `maxAttempts` (terminal, no further `.reconnecting`); explicit `disconnect` does **not** reconnect; `isReconnecting: true` suppresses the library ladder; OS give-up (`isReconnecting: false`) hands off to Tier 1.

**Demo (separate project — read `Demo/CLAUDE.md`, delegate).** v1: render `.reconnecting` in device detail, distinguishing `.system` ("System reconnecting…") from `.library` (attempt + `nextRetryAt` countdown); update the `connect(to:)` call site for the new `autoReconnect` parameter; add a `SettingsView` section binding the `ReconnectPolicy` fields. The explicit-disconnect vs. unexpected-drop distinction then falls out visibly. List-row badge optional/stretch.

**DocC.** Extend the connection-stream example in `GettingStarted.md` for the OS/library tiers, the `.reconnecting` shape, and `connect(to:autoReconnect:)`.

## Work Items

> **Orchestration status (2026-07-06):** Items 1–4 ✅ DONE — migrated the earlier single-tier implementation to the two-tier model. `ReconnectPolicy.enabled` removed; `ConnectionState.reconnecting(source:attempt:nextRetryAt:)` + `ReconnectSource{.system,.library}` added; `connect(to:autoReconnect:)` public API; `BluetoothActor` now threads `isReconnecting` through `ConnectionPayload`, emits `.system` reconnecting on OS-driven drops, gates Tier-1 ladder on `reconnectEnabled: Set<String>`, passes `CBConnectPeripheralOptionEnableAutoReconnect`, re-arms Tier 0 on retry. Library `swift build` clean (both targets). Item 5: `GettingStarted.md` documents both tiers, `.reconnecting` shape, and `connect(to:autoReconnect:)`. Item 6: tests migrated to new shapes + new coverage (`autoReconnectFalseDoesNotArmLadder`, `osGiveUpHandsOffToTier1`, `systemReconnectOnUnexpectedDrop`); added internal `testInjectDisconnect(for:isReconnecting:error:)` hook because CoreBluetoothMock hardcodes `isReconnecting: true` for auto-reconnect connects (documented finding). Item 7 (Demo): renders `.system` vs `.library` reconnecting, removed the `enabled` toggle from `SettingsView`, builds clean. Item 8: **all 38 tests pass**, `forceMock`/lazy-init/`id(for:)` untouched. **ALL ITEMS ✅ COMPLETE.**

1. `ReliaBLEConfig.swift` — add behavioral `ReconnectPolicy` (`maxAttempts`, `initialDelay`, `maxDelay`, `jitter`) + `reconnectPolicy` property with defaults. Independent, compiles alone.
2. `Models/ConnectionState.swift` — add `ReconnectSource` + `.reconnecting(source:attempt:nextRetryAt:)`. Independent, compiles alone.
3. `ReliaBLEManager.swift` — change `connect(to:)` → `connect(to:autoReconnect:)` (breaking public API); forward `config.reconnectPolicy` into `ensureInitialized`. Lands with #4.
4. `BluetoothActor.swift` — core work item: add `reconnectPolicy`/`reconnectEnabled`/`reconnectAttempts`/`reconnectTasks`; pass the OS option in `connect(id:autoReconnect:)`; honor `isReconnecting` in `handleDidDisconnect`; add `armReconnect(id:)` + `scheduleReconnect(id:attempt:)`; edit `handleDidFailToConnect`, `handleDidConnect`, `disconnect`, `invalidatePeripherals`; extend `ensureInitialized` to stash the policy. Lands atomically with #3.
5. `Documentation.docc/GettingStarted.md` — document the tiers, the `.reconnecting` shape, and `connect(to:autoReconnect:)`.
6. `ReliaBLEManagerTests.swift` — first verify mock auto-reconnect capability; then add the coverage above using a fast test policy.
7. Demo — render `.reconnecting` (system vs. library), update the `connect` call site, add `SettingsView` backoff controls. Delegate to a sub-agent told to read `Demo/CLAUDE.md` first.
8. `swift build && swift test`; confirm `forceMock`, lazy central init, and the FR-8.5 `id(for:)` breadcrumb are untouched.

## Decisions (resolved)

- **Enable/disable is per-connect.** `connect(to:autoReconnect: Bool = true)` — reconnection intent lives on the API (mirroring CoreBluetooth's per-connect option), default on. Config carries behavior only.
- **OS auto-reconnect is primary (Tier 0); library supplements (Tier 1).** Pass `CBConnectPeripheralOptionEnableAutoReconnect` on every auto-reconnect connect; `isReconnecting` gates whether the library ladder arms. The library covers initial-connect failures and post-OS-give-up drops.
- **Trigger scope & intent.** The library ladder arms on initial-connect failures and post-OS-give-up unexpected drops. Clean vs. unexpected is decided by an explicit `intentionalDisconnects` set, not the `error` value.
- **`.reconnecting(source: ReconnectSource, attempt: Int?, nextRetryAt: Date?)`.** `.system` carries `nil` metadata (iOS exposes none); `.library` carries the attempt count and next-retry `Date`.
- **`ReconnectPolicy` = behavior only** — `maxAttempts`, `initialDelay`, `maxDelay`, `jitter`. No `enabled`, no OS/library strategy toggle.
- **Real-time tests.** No injected `Clock`; tiny test policy, assert emission *sequence and count* via the existing `firstConnectionStateChange` / `pollUntil` helpers. Verify CoreBluetoothMock honors the OS option before relying on it for Tier-0 coverage.

## Deferred / follow-up
- **Background reconnection** — daemon-held standing connects, `CBCentralManagerOptionRestoreIdentifierKey` + `willRestoreState:`, `bluetooth-central` background mode, and connect options like `NotifyOnConnection`/`NotifyOnDisconnection`. The Tier-1 scheduler's `Task.sleep` does not survive app suspension/termination; the OS tier (Tier 0) partially covers backgrounded reconnects but is weaker than full state restoration. Own issue.

## References
- Issue #37; builds on #36 (`docs/plans/connection-lifecycle-stream-2026-06-30.md`).
- PRD: FR-1.2, FR-1.3.1.
- Apple: `CBConnectPeripheralOptionEnableAutoReconnect` (iOS 17+) + `didDisconnectPeripheral:timestamp:isReconnecting:error:`; WWDC23 "What's new in Core Bluetooth". **OS auto-reconnect give-up budget/timing is undocumented — verify on-device.**
- Architecture: root `AGENTS.md` (`@BluetoothActor`, three-target mock harness, `ReliaBLEConfig` lazy init).
- Demo: `Demo/CLAUDE.md`; `Demo/ReliaBLE Demo/ReliaBLE Demo/Settings/SettingsView.swift`.
