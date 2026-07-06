# Automatic Reconnection with Exponential Backoff: Plan
*Issue #37 · 2026-07-05*

## Goal

Deliver ReliaBLE's headline reliability feature: when a connected peripheral drops unexpectedly (or an initial connect fails transiently), automatically retry the connection using exponential backoff with jitter and a configurable cap / max-attempt policy — instead of requiring the integrating app to retry manually. Surface reconnection progress (`.reconnecting`, attempt count, next-retry timing) through the existing `connectionStateChanges` stream. Ship a Demo that makes the backoff ladder observable.

Covers **FR-1.2** (auto-reconnect with exponential backoff) and the reconnection half of **FR-1.3.1** (connection-stability status). Builds directly on #36.

## Background

#36 is fully merged (commit `e8d3a4e`, "Added full connection handling and state reporting"). All state below verified by exploration.

### Library — connection lifecycle (`Sources/ReliaBLE/`)
- All BLE state lives in `@globalActor actor BluetoothActor` (`BluetoothActor.swift:81`).
- Connect / disconnect entry points: `connect(id:)` (`BluetoothActor.swift:703`) sets `.connecting`, broadcasts, calls `centralManager.connect`. `disconnect(id:)` (:730) sets `.disconnecting`, broadcasts, calls `cancelPeripheralConnection`.
- Delegate shim (`BluetoothDelegateShim`, :775–792) yields `DelegateEvent`s drained by one long-lived `delegateEventTask` through `process(_:)` (:342). Handlers:
  - `handleDidConnect` (:656) → `.connected`
  - `handleDidDisconnect` (:666) → `.disconnected(reason:)`. Receives the 5-param `didDisconnectPeripheral:timestamp:isReconnecting:error:`; **`isReconnecting` is currently ignored**, `error` is mapped `CBError? → PeripheralError?`.
  - `handleDidFailToConnect` (:682) → `.failed(reason:)`
- `ConnectionState` (`Models/ConnectionState.swift:30`): `.connecting`, `.connected`, `.disconnecting`, `.disconnected(reason: PeripheralError?)`, `.failed(reason: PeripheralError?)`. **No `.reconnecting` case; no attempt/retry metadata.** `ConnectionStateChange { peripheralId: String; state: ConnectionState }` (:54).
- Stream: `connectionStateChangesStream()` (:190) → shared `AsyncStream<ConnectionStateChange>`, **no replay**. Snapshot: `currentConnectionStates: [String: ConnectionState]` (actor :247, façade `ReliaBLEManager.swift:105`). Public property `connectionStateChanges` (`ReliaBLEManager.swift:98`).
- Peripheral tracking: live refs `cbPeripherals: [String: CBPeripheral]` (:116, never escape actor); state registry `connectionStates: [String: ConnectionState]` (:129), same key.
- **Config does not reach the actor today.** `ReliaBLEManager.init` (`ReliaBLEManager.swift:52`) passes only a `LoggingService` in via `Task { await BluetoothActor.shared.ensureInitialized(log:) }` (:63). `ReliaBLEConfig` (`ReliaBLEConfig.swift:35`) is a flat `Sendable` struct of `public var` fields + no-arg `init()`; backoff policy will need a new path into the actor.
- No `Task.sleep`, `Timer`, or `Clock` exists inside `@BluetoothActor` today — only continuations (`withCheckedThrowingContinuation` for auth) and the delegate drain `Task`.

### Tests / mock harness (`Tests/ReliaBLETests/`, `Sources/ReliaBLEMock/`)
- `@Suite(.serialized)` (`ReliaBLEManagerTests.swift:56`) — process-wide singleton state. `Mock.makeManager()` → `SimulationConfig.ensureConfigured()` (:806) does one-time `simulateInitialState(.poweredOn)` / `simulatePeripherals` / `simulateAuthorization`.
- Unexpected-drop primitive already used: `Mock.connectionTestSpec.simulateDisconnection()` (:568, 580, 588, 594) triggers the `didDisconnect` path. Connect outcome controlled by `ConnectionTestDelegate.connectionResult: Result<Void, Error>` (:686).
- **No injected clock.** Timed behavior is observed with real-time `Task.sleep` and `pollUntil(timeout: 3.0)` (:929). Mock connection callback fires on a ~0.045 s async timer (:599). `Tests/ReliaBLETests/Mocks/` is empty.

### Demo (`Demo/ReliaBLE Demo/`)
- Separate project — read `Demo/CLAUDE.md` first, use XcodeBuildMCP. #36 added connect/disconnect + connection-state consumption in the Central detail UI (commit `b6371b8`). `SettingsView.swift` is the target for backoff-config controls.

## Approach

Purely additive to the #36 pipeline — one new scheduler method on the actor, reusing the existing broadcaster, delegate handlers, and `connectionStates` registry. No new actor, no reconnect service. The retry loop is **event-driven**, not an inline `await`: a delegate callback lands → handler emits a terminal state → schedules a delayed `Task` → that Task emits `.reconnecting`, sleeps, and calls the existing `connect(id:)`; the next delegate callback either resets (success) or re-schedules (failure).

**Config.** Add a nested `ReconnectPolicy: Sendable` struct beside `ReliaBLEConfig` (`ReliaBLEConfig.swift`) with `enabled` (default **`true`** — Q1), `maxAttempts`, `initialDelay: TimeInterval`, `maxDelay: TimeInterval`, `jitter: Double` and sane defaults. `ReliaBLEConfig` gains one `var reconnectPolicy = ReconnectPolicy()`. Plumb it into the actor by extending `ensureInitialized` (today it carries only `LoggingService`) to also stash the policy — `ReliaBLEManager.init` already builds the config, so this is a one-line forward.

**State.** Add one non-terminal case to the public enum: `ConnectionState.reconnecting(attempt: Int, nextRetryAt: Date)` (`Models/ConnectionState.swift`). `Date` gives the Demo a countdown target for free. Stays `Sendable`/`Equatable`/`Hashable`. This is a breaking change to a public enum (pre-1.0, acceptable) that the Demo's `switch` must handle.

**Scheduler.** On `@BluetoothActor`, add three pieces of isolated state: `reconnectPolicy: ReconnectPolicy`, `reconnectAttempts: [String: Int]` (per-peripheral attempt counter, the source of truth across delegate events), and `reconnectTasks: [String: Task<Void, Never>]` (cancellable pending retry). The retry ladder is driven by these seams:

- **Arming (single choke point).** Both `handleDidDisconnect` (:666) and `handleDidFailToConnect` (:682), after emitting their terminal state, call one private `armReconnect(id:)`. It is the *only* place the `policy.enabled` guard lives, so handlers stay dumb. `armReconnect` returns early if: policy disabled, `id ∈ intentionalDisconnects` (then discards that membership), or `reconnectAttempts[id] >= maxAttempts` (give-up — leave the terminal state, clear `reconnectAttempts[id]`). Otherwise it increments `reconnectAttempts[id]` and calls `scheduleReconnect(id:attempt:)`.
- **`scheduleReconnect(id:attempt:)`.** Cancel+replace any existing `reconnectTasks[id]`; compute the backoff delay (see below); emit `.reconnecting(attempt, now + delay)`; store a `Task` that `Task.sleep`s for `delay`, then — only if `!Task.isCancelled` and `cbPeripherals[id]` still exists — calls `connect(id:)`. Actor re-entrancy across the sleep is safe because all mutation is actor-isolated; the cancel-before-replace and the post-sleep guards close the double-schedule and stale-fire races.
- **Recovery.** `handleDidConnect` (:656) clears `reconnectAttempts[id]`, cancels+removes `reconnectTasks[id]`, and discards any stale `intentionalDisconnects[id]`.
- **Explicit disconnect.** `disconnect(id:)` (:730) inserts `id` into `intentionalDisconnects`, cancels+removes `reconnectTasks[id]` and `reconnectAttempts[id]`, then sets `.disconnecting`.
- **Teardown.** `invalidatePeripherals` (:619, clears `connectionStates` today) also cancels all `reconnectTasks` and clears both new maps.

**Backoff math** is a two-line computation once the policy fields exist — exponential `initialDelay * 2^(attempt-1)` capped at `maxDelay`, then `±jitter` via `Double.random`; not elaborated further here.

**Tests.** Mock-driven, mirroring #36's harness (`simulateDisconnection()`, `ConnectionTestDelegate`, `firstConnectionStateChange`). Use a test policy with tiny delays (Q4) and assert emission *sequence and count*, not exact timing. Cover: unexpected drop → `.reconnecting` ladder → recovery; give-up after `maxAttempts` (terminal state, no further `.reconnecting`); explicit `disconnect` does **not** reconnect; transient connect-failure also arms the ladder.

**Demo (separate project — read `Demo/CLAUDE.md`, delegate).** v1 scope: render `.reconnecting` (attempt + next-retry countdown from `nextRetryAt`) in the device-detail view, and add a `SettingsView` section binding the `ReconnectPolicy` fields (both are Demo acceptance criteria). The explicit-disconnect vs. unexpected-drop distinction then falls out visibly (settle to `.disconnected` vs. enter `.reconnecting`). List-row badge is optional/stretch.

**DocC.** Extend the connection-stream example in `GettingStarted.md` to cover `.reconnecting`.

## Work Items

> **Orchestration status (2026-07-05):** Items 1–4 ✅ DONE. Item 1/2: `ReconnectPolicy` struct + `.reconnecting` case. Items 3/4: `BluetoothActor` scheduler (`armReconnect`/`scheduleReconnect`/`performReconnect`/`clearReconnectState`, new state `reconnectPolicy`/`intentionalDisconnects`/`reconnectAttempts`/`reconnectTasks`; teardown method is `invalidatePeripherals()` at :624; `ensureInitialized` extended with policy param) + `ReliaBLEManager` forwards `config.reconnectPolicy`. Library `swift build` clean. Oracle review pass applied (stale-task guard, cancellation handling, give-up cleanup, defensive backoff math). Item 5: `GettingStarted.md` covers `.reconnecting`. Item 6: 4 new tests (`reconnectAfterUnexpectedDisconnect`, `reconnectGivesUpAfterMaxAttempts`, `explicitDisconnectDoesNotReconnect`, `transientConnectFailureArmsReconnect`) via internal `setReconnectPolicy` test hook. Item 7 (Demo): `.reconnecting` rendered with attempt + `CountdownView` to `nextRetryAt`; `SettingsView` reconnect-policy section (`@AppStorage`, applied at app launch). Item 8: **all 36 tests pass**, `forceMock`/lazy-init/`id(for:)` confirmed untouched, Demo builds clean. **ALL ITEMS ✅ COMPLETE.**

1. ✅ `ReliaBLEConfig.swift` — add `ReconnectPolicy` struct + `reconnectPolicy` property with defaults. Independent, compiles alone.
2. ✅ `Models/ConnectionState.swift` — add `.reconnecting(attempt:nextRetryAt:)`. Independent, compiles alone.
3. `BluetoothActor.swift` — add `reconnectPolicy` + `reconnectAttempts` + `reconnectTasks` state; `armReconnect(id:)` (the enabled/intent/give-up guard) and `scheduleReconnect(id:attempt:)`; and the handler edits (`handleDidDisconnect`, `handleDidFailToConnect`, `handleDidConnect`, `disconnect`, `invalidatePeripherals`); extend `ensureInitialized` to stash the policy. Core work item; lands atomically with #4.
4. `ReliaBLEManager.swift` — forward `config.reconnectPolicy` into `ensureInitialized`. Lands with #3.
5. `Documentation.docc/GettingStarted.md` — document `.reconnecting` in the connection example.
6. `ReliaBLEManagerTests.swift` — add backoff-ladder, give-up, explicit-disconnect-no-reconnect, and transient-failure tests using a fast test policy.
7. Demo — surface `.reconnecting`, add `SettingsView` backoff controls, show the disconnect-semantics distinction. Delegate to a sub-agent told to read `Demo/CLAUDE.md` first.
8. `swift build && swift test`; confirm `forceMock`, lazy central init, and the FR-8.5 `id(for:)` breadcrumb are untouched.

## Decisions (resolved)

- **Q1 — enabled by default.** `ReconnectPolicy.enabled` defaults to `true`; apps set it `false` to opt out. Delivers the headline feature out of the box.
- **Q2 — both triggers, intent-set distinction.** Unexpected drops *and* transient initial-connect failures arm backoff. Clean vs. unexpected is decided by an explicit `intentionalDisconnects` set, not the `error` value.
- **Q3 — `.reconnecting(attempt: Int, nextRetryAt: Date)`.** `Date` gives the Demo a countdown target directly. `maxAttempts` stays out of the payload (the app already holds it via its policy).
- **Q4 — real-time tests.** No injected `Clock`; tests use a tiny `ReconnectPolicy` (small delays) and assert emission *sequence and count* via the existing `firstConnectionStateChange` / `pollUntil` helpers, matching the current harness.

## References
- Issue #37; builds on #36 (`docs/plans/connection-lifecycle-stream-2026-06-30.md`).
- PRD: FR-1.2, FR-1.3.1.
- Architecture: root `AGENTS.md` (`@BluetoothActor`, three-target mock harness, `ReliaBLEConfig` lazy init).
- Demo: `Demo/CLAUDE.md`; `Demo/ReliaBLE Demo/ReliaBLE Demo/Settings/SettingsView.swift`.
