# Design: Instance-Isolated BluetoothActor (retire `@globalActor`)
*Follow-up to issue #42 · 2026-07-19 · Status: revised after oracle review (grok-4.5); ready to implement*

## Goal

Replace the process-wide `@globalActor BluetoothActor.shared` singleton with a plain
`actor BluetoothActor` instance owned per `ReliaBLEManager`. This:

1. Enables **multiple, fully isolated library stacks in one process** — each with its own
   `CBCentralManager`, restore identifier, scan policy, and streams (independent restoration
   domains, SDK isolation, separate scan policies — all Apple-supported multi-central use cases).
2. Makes **state-restoration tests faithful**: each test constructs a fresh stack whose central
   is created *with* the restore identifier, so CoreBluetoothMock's `simulateStateRestoration`
   closure (PR #123, present in our pinned 1.0.6) fires `willRestoreState` during central `init`
   — the actual production event — instead of a shim-injected replay into a long-lived central.
3. Removes singleton-workaround machinery from production code
   (`restoreDeliveryWaiters`, `testDeliverWillRestoreStateThroughDelegate`,
   `testSetRestoreIdentifier`, `testClearDiscoveredSnapshotsPreservingLiveReferences`, the
   "already initialized with different restoreIdentifier" warning path, etc.).

Public API on `ReliaBLEManager` is **source-compatible**: no signatures change; the manager
remains `Sendable` and callable from `@MainActor`.

## Non-goals

- No new public API for sharing an actor between managers (first cut is one-stack-per-manager;
  a keyed registry or "two façades, one stack" type can be added later, non-breaking — sketched
  under Future so it isn't re-litigated here).
- No change to the three-target mock trick, the factory seam, `forceMock: true`, or the
  lazy-authorization contract.
- No change to the reconnect ladder, stream semantics, or logging behavior.

## Design

### 1. Actor shape

```swift
// Before
@globalActor actor BluetoothActor { static let shared = BluetoothActor(); private init() {} }

// After
actor BluetoothActor {
    init(log: LoggingService, reconnectPolicy: ReconnectPolicy, restoreIdentifier: String?) { … }
}
```

- Delete `@globalActor`, `shared`, every `@BluetoothActor` annotation, and every
  `Task { @BluetoothActor in … }` hop (grep the whole repo **including Demo** for
  `@BluetoothActor` / `BluetoothActor.shared`). This call-site purge is the risky mechanical
  core of the diff — treat it as a bulk migration, not a small edit.
- **Actor `init` sets configuration only** (log, policy, restore id) — synchronously, which is
  strictly better than today's async first-wins `ensureInitialized`. **No `CBCentralManager` is
  created in `init`**; the lazy-auth contract is unchanged.
- **Stream factories stay `nonisolated`.** `ReliaBLEManager.state` (and the other stream
  properties) are synchronous getters; `BluetoothActor.stateStream()` etc. must remain
  `nonisolated` methods that capture `self` in `Task { await self.register(…) }`. Accidentally
  making them actor-isolated would force `await` on the public getters — a source break. Add a
  compile-time proof to the Sendable test.
- The `restoreIdentifier`-mismatch warning is deleted — it can no longer occur. Config is
  immutable after actor init; changing restore id or policy means creating a new manager (fine
  for v1).

### 2. Ownership, lifetime & teardown

```swift
public final class ReliaBLEManager: Sendable {
    private let bluetooth: BluetoothActor   // strong; created synchronously in init
}
```

**Retain graph:** manager → actor → central → shim (as delegate); shim → event continuation
only (no actor reference — no cycle). `delegateEventTask` and `reconnectTasks` capture
`[weak self]`. Registration `Task`s are short-lived. Each live subscriber's `onTermination`
closure retains the actor until the stream terminates — **deliberate**: a stream being consumed
must keep the stack alive. Consequence (stated explicitly): the actor deinits only after the
manager *and every subscriber stream* are gone; deinit-based teardown never runs while anyone
is subscribed.

**Teardown — compiler-legal design (oracle must-fix, r2).** Actor `deinit` is nonisolated and
must not touch actor-isolated state. A `let` cannot be assigned after actor init, so the
pipeline is created **at stored-property initialization**, not in `setupCentralManager()`:

  ```swift
  /// Nonisolated box so the actor's nonisolated deinit may finish the pipeline.
  final class EventPipeline: @unchecked Sendable {
      let stream: AsyncStream<DelegateEvent>
      let continuation: AsyncStream<DelegateEvent>.Continuation
      init() {
          (stream, continuation) = AsyncStream.makeStream(of: DelegateEvent.self,
                                                          bufferingPolicy: .unbounded)
      }
      func finish() { continuation.finish() }   // thread-safe, idempotent
  }

  actor BluetoothActor {
      private nonisolated let eventPipeline = EventPipeline()
      deinit { eventPipeline.finish() }
  }
  ```

  `setupCentralManager()` then starts `delegateEventTask` from `eventPipeline.stream`, creates
  the shim with `eventPipeline.continuation`, and calls the factory. Deinit reads only an
  immutable `nonisolated let` — no `nonisolated(unsafe)`, no post-init write. Finishing the
  stream ends the `[weak self]` consumer loop; ARC then releases central → shim. (The pipeline
  existing before the central is also what makes the consumer-before-factory ordering in §3
  trivial.)
- **Reconnect tasks must also be cancellable from `deinit`** (oracle r2): `reconnectTasks`
  are actor-isolated, so a `[weak self]` retry sleeping through a long delay could outlive the
  actor uncancelled. Add a second nonisolated box:

  ```swift
  /// Thread-safe (internal lock) registry of unstructured task handles.
  final class TaskRegistry: @unchecked Sendable {
      func insert(_ id: String, _ task: Task<Void, Never>) { … }
      func cancel(_ id: String) { … }
      func cancelAll() { … }
  }

  private nonisolated let taskRegistry = TaskRegistry()
  deinit { eventPipeline.finish(); taskRegistry.cancelAll() }
  ```

  The registry **replaces** the actor's `reconnectTasks` dictionary outright (no mirrored
  second store): actor code inserts/cancels via `taskRegistry.insert(id:)` /
  `taskRegistry.cancel(id)` and keeps only the logical reconnect state (`reconnectAttempts`,
  `connectionStates`) for stale-attempt guards. `deinit` and `shutdown()` can then cancel from
  any context.
- Additionally add an **internal `shutdown()`** (actor-isolated) with **terminal semantics**
  (oracle r2): sets `isShutdown = true`; finishes the pipeline; cancels the registry and
  `delegateEventTask`; finishes all subscriber continuations; nils the central/shim. After
  shutdown, `ensureCentralManager()` and all operations are guarded no-ops (the one-shot
  pipeline `let` cannot host a second central — a shut-down actor is dead, not restartable;
  create a new manager instead). Throwing operations (`connect`/`disconnect`) deterministically
  **throw `PeripheralError.bluetoothUnavailable`** after shutdown; non-throwing operations
  no-op with a warning log. Crucially, shutdown clears **volatile** state only — it must
  **not** call `persistReconnectIntent()` or otherwise write/delete the reconnect-intent
  `UserDefaults` key, so persisted intent survives for cold relaunch (add a test asserting
  this). Not public in v1; the test harness uses it for deterministic teardown. Promoting it to
  public API later is non-breaking.
- Do **not** rely on `AsyncStream.Continuation` deinit semantics implicitly; `finish()` /
  `cancelAll()` are always called explicitly via the paths above.

### 3. Central creation & event ordering (oracle must-fix)

`setupCentralManager()` call order changes:

1. Create the unbounded `AsyncStream` + continuation (pipeline box).
2. Create the shim.
3. **Start `delegateEventTask` first** (it suspends on `for await`).
4. *Then* call `CBCentralManagerFactory.instance(...)`.

Rationale: with a restore identifier, the mock (PR #123) invokes `willRestoreState`
**synchronously inside the factory call**, and further callbacks (`didUpdateState`) can arrive
on the delegate queue immediately after. The unbounded buffer holds early yields either way,
but starting the consumer first removes the "task doesn't exist yet" window and shortens the
gap before restore side effects are applied. A single continuation + single consumer preserves
delivery order end-to-end — never fan out per-callback `Task`s.

Ordering invariants:

- **`willRestoreState`-before-`didUpdateState` is a mock/OS observation, not a library
  invariant.** Production code must tolerate either order and restore while not powered on —
  `handleWillRestoreState` already defers the scan; keep the handler synchronous (no awaits
  holding half-restored state). Nothing may assume restore only runs when `.ready`.
- **Tests assert settled, observable state** (restored maps/streams visible after polling), not
  internal event order. One optional mock-contract test may check restore-before-state, clearly
  labeled as a mock behavior check.
- Restore side effects are applied asynchronously relative to `ensureInitialized` returning;
  callers (tests) poll `pollUntil` / consume streams rather than expecting synchronous
  visibility.

### 4. `ensureInitialized` collapse — preserved guarantees

| Guarantee | Today | After |
|---|---|---|
| `ReliaBLEManager.init` never blocks | fire-and-forget `Task` | unchanged (actor init is sync + cheap; eager `Task { await bluetooth.ensureCentralManager() }` optimization kept) |
| Op right after init can't race setup | every public entry awaits `ensureInitialized` | every public entry awaits `ensureCentralManager()` (idempotent, actor-serialized) |
| Logger/policy/restore id set before central exists | first `ensureInitialized` call | actor `init` — strictly earlier |
| No central until `.allowedAlways` (lazy-auth) | gate in `ensureInitialized`/`authorize` | identical gate in `ensureCentralManager()`/`authorize` |
| Out-of-band auth (Settings) picked up later | every call retries creation | every call retries creation |

- The slim method is named `ensureCentralManager()`; exact member disposition:
  - **Stream getters** (`state`, `peripheralDiscoveries`, `discoveredPeripherals`,
    `connectionStateChanges`): do **not** create the central — subscriber registration only
    (matches today).
  - **Snapshot getters** (`currentState`, `currentConnectionStates`): documented cached-state
    reads; do **not** create the central.
  - **Operational methods** (`authorizeBluetooth`, `startScanning`, `stopScanning`, `connect`,
    `disconnect`, and any future op): **must** await `ensureCentralManager()` first — audit on
    implementation.
- Per-actor authorization-continuation maps mean cancelling manager A's `authorize` can no
  longer touch manager B's waiters — add a two-manager test for this.

**Test access to the per-manager actor (oracle must-fix, r2).** With `shared` gone, the suite's
many `BluetoothActor.shared.test…` calls need a defined replacement:

- `ReliaBLEManager` keeps `bluetooth` **internal** (not `private`), so `@testable import
  ReliaBLEMock` reaches the actor directly: `await manager.bluetooth.testIsScanning()` etc.
  Actor test hooks stay `internal` on the actor as today; no public surface is added. (Narrow
  test wrappers on the manager can replace this later if `bluetooth` should become private —
  not required for v1.)
- Suite-level helpers (`Mock.ensureReady`, `pollUntil` predicates, the `hasCentralManager` /
  `isCentralPoweredOn` extension accessors) take the actor (or manager) as a parameter instead
  of referencing a global.

### 5. Isolation model: one stack per manager

Each `ReliaBLEManager` is an isolated stack — its own actor, central, discovered peripherals,
connection state, and streams. Document the model in DocC (as the library's behavior, not as a
change):

- **Restore identifiers must be unique among simultaneously live managers.** Two live managers
  with the same `restoreIdentifier` share the persisted reconnect-intent `UserDefaults` key
  *and* contend for CoreBluetooth's restoration domain (Apple: one restore id ↔ one central) —
  unsupported/undefined. Reusing an id across launches (or across a shut-down stack and its
  successor, as the cold-relaunch tests do) is not just allowed but **required** for
  restoration; DocC states both halves of the rule.
- **Authorization is process-global.** `CBCentralManager.authorization` is app-wide; manager A's
  `authorizeBluetooth()` affects B. Stacks are isolated in state, not in permission.
- **Per-stack discovery.** Two stacks scanning the same device each hold their own `Peripheral`
  snapshot and live-reference map; there is no cross-manager discovered list.
- Multiple concurrent aggressive scans degrade each other (shared radio) — DocC guidance.
- The incorrect "CoreBluetooth enforces a single central per process" comment is removed.
- Demo app: single manager; audit via sub-agent (reads `Demo/CLAUDE.md` first); expected impact
  nil.

### 6. Test architecture

- **Fresh stack per test** via `Mock.makeManager(...)`. The suite stays `.serialized` and keeps
  per-test pinning: Nordic's *mock* globals (authorization, power, peripheral specs,
  `simulateStateRestoration`) remain process-wide even though our stacks no longer are. Tests
  creating two managers must not assume isolated mock power/peripherals. Rewrite the suite's
  header comments — the "process-wide singleton" mental model they document becomes wrong.
- **Faithful cold-relaunch pattern** (replaces `testClearDiscoveredSnapshotsPreservingLiveReferences`):
  1. Manager 1 with restore id `R`: discover, connect (persisting reconnect intent).
  2. **Tear down stack 1 deterministically** via the internal `shutdown()` — dropping the
     manager alone is insufficient while any stream subscriber is alive (streams retain the
     actor). The harness must release all iterators *and* call `shutdown()`.
  3. Set `CBMCentralManagerMock.simulateStateRestoration = { id in id == R ? dict : nil }`
     (**always reset to `nil` in a `defer`** — it is process-global). **Fixture construction
     (oracle must-fix, r2):** the #123 restoration dictionary is built from
     `CBMPeripheralSpec`s — the same process-global specs the harness already owns
     (`Mock.connectionTestSpec`, a `nonisolated(unsafe)` static) — plus `CBMUUID` scan
     services. No live `CBPeripheral` or actor-isolated state is needed, so the closure is
     built entirely in test code with no actor-boundary crossing. If a scenario ever needs
     richer captured state, wrap it in a small test-only `@unchecked Sendable` `RestorationSeed`
     box; do not reach into the actor from the closure.
  4. Manager 2 with the same `R`: central init fires `willRestoreState` → shim → stream →
     `process` → `handleWillRestoreState`. Assert settled state by polling.
- **Deleted from production:** `restoreDeliveryWaiters`, `suspendForRestoreDelivery()`,
  `resumeRestoreDeliveryWaiters()`, `testDeliverWillRestoreStateThroughDelegate`,
  `testSetRestoreIdentifier`, `testClearDiscoveredSnapshotsPreservingLiveReferences`. A minimal
  internal entry point to `handleWillRestoreState` is **retained** (no waiters, no shim
  backdoor) for defensive unit tests only.
- **Test disposition:**

  | Scenario | Path |
  |---|---|
  | Connected restore, map rehydrate, stream broadcast | Faithful (#123) |
  | Re-arm only with persisted intent / `autoReconnect: false` no re-arm | Faithful cold-relaunch (UserDefaults survives `shutdown()`) |
  | Disconnected restored peripheral seeds nothing | Direct-handler unit test (iOS never restores disconnected peripherals; this tests our defensive switch) |
  | Defer restored scan until powered on / empty-filter ignore | Validate against mock (it may set `isScanning = true` at restore-init); if the mock conflicts, keep as direct-handler unit tests and capture the gap for the upstream doc (work item 7) |
  | Restore doesn't hit `peripheralDiscoveries` feed | Faithful |
  | Invalidate clears pending scan + intent | Faithful (power/unauth on that stack's central) |
  | **Two managers, distinct restore ids, independent state** | **New test — must add** (validates the whole migration) |
  | Auth cancellation isolation between managers | New test |
  | willRestore-before-stateUpdate ordering | Optional mock-contract test only |

- Persisted reconnect intent (`UserDefaults`) unchanged; per-test unique restore ids keep tests
  independent. Update the `ReliaBLEManager` Sendable-proof test so it doesn't rely on singleton
  side effects.

### 7. Concurrency notes (Swift 6 strict)

- Manager stays trivially `Sendable` (`let` actor reference + `LoggingService`).
- `@unchecked Sendable` payload ferries (`DiscoveryPayload`, `RestorationPayload`, …) unchanged.
- `sending [CBUUID]?` parameters, checked-continuation helpers, and region-isolation-friendly
  patterns port unchanged.
- The only new unchecked surfaces are the `EventPipeline` and `TaskRegistry`
  `@unchecked Sendable` teardown boxes — scoped, documented, immutable `nonisolated let`
  properties; **no new `nonisolated(unsafe)`**.

### 8. Documentation

- `AGENTS.md` / `CLAUDE.md`: rewrite "Swift Concurrency" — instance actor owned by the manager;
  one-stack-per-manager model; unique-restore-id rule.
- DocC (`Topics/Concurrency.md`, `GettingStarted.md`): isolation model, stream-retains-actor
  lifetime, multi-manager guidance (auth is global, radio shared, unique restore ids),
  restoration unchanged from the consumer's view.
- Verify the resolved CoreBluetoothMock actually contains `simulateStateRestoration` at build
  time (it does in 1.0.6; keep the `.upToNextMinor` pin and fail tests clearly if absent).

## Work items (each checkpoint compiles + tests green)

*(Reordered per oracle r2: the singleton purge cannot compile alone — the first green
checkpoint bundles the actor refactor with the minimal test-access migration.)*

1. **Checkpoint 1 — de-globalize + minimal harness migration** (one PR-sized step, riskiest):
   remove `@globalActor`/`shared`; `init(log:reconnectPolicy:restoreIdentifier:)`; slim
   idempotent `ensureCentralManager()`; stream factories stay `nonisolated` (sync manager
   getters preserved); `EventPipeline` + `TaskRegistry` as `nonisolated let` stored properties
   + `deinit` teardown; terminal internal `shutdown()` (persisted-intent-preserving);
   consumer-task-before-factory ordering; manager owns
   **internal** `bluetooth`; migrate every `BluetoothActor.shared` test call site to
   `manager.bluetooth` and parameterize suite helpers. Existing restoration tests keep passing
   via the (temporarily retained) shim-injection hook.
2. **Lifetime hardening & cleanup**: retain-cycle audit; remove singleton doc comments;
   fresh-stack `Mock.makeManager`; `shutdown()`-based per-test teardown.
3. **Cold-relaunch harness**: spec-based `simulateStateRestoration` fixture helper (set/reset
   in `defer`); then delete the relaunch-faking hooks (`testDeliverWillRestoreStateThroughDelegate`,
   `restoreDeliveryWaiters`, `testClearDiscoveredSnapshotsPreservingLiveReferences`,
   `testSetRestoreIdentifier`); rewrite suite header comments.
4. **Migrate restoration tests** to the faithful/cold-relaunch paths per the disposition table;
   demote disconnected + (if mock conflicts) defer-scan scenarios to direct-handler unit tests;
   **add** the two-manager isolation test and the auth-cancellation isolation test.
5. **Docs**: AGENTS.md/CLAUDE.md, DocC — document the one-stack-per-manager model and
   requirements as the library's behavior (pre-release: no migration/behavior-change notes).
6. **Demo audit** (sub-agent, reads `Demo/CLAUDE.md` first): confirm single-manager usage
   unaffected.
7. **Upstream follow-up (last)**: after all changes land, assess whether any CoreBluetoothMock
   functionality is still missing (e.g. explicit restored state incl. `.disconnected`,
   on-demand `willRestoreState` delivery); if so, write a fresh upstream feature-request doc
   scoped to only those residual gaps.

## Risks

| Risk | Mitigation |
|---|---|
| Actor `deinit` touching isolated state (illegal) | Nonisolated `EventPipeline.finish()` + `TaskRegistry.cancelAll()` only; explicit internal `shutdown()` |
| Reconnect task outlives deinitted actor | Task handles in nonisolated `TaskRegistry`; cancelled from `deinit`/`shutdown()` |
| `shutdown()` clobbers persisted reconnect intent | Terminal `shutdown()` clears volatile state only; explicit test |
| Stream subscriber keeps actor+central alive unexpectedly | Documented; tests drop iterators + call `shutdown()` |
| `ensureCentralManager()` missed on some public API | Explicit audit of every façade method |
| Sync `var state` accidentally becomes async | Keep stream factories `nonisolated`; compile-time proof in tests |
| Same restore id on two managers | Documented unsupported; unique-id rule in DocC |
| `updateState()` runs before restore drained | Consumer-before-factory ordering + settled-state polling in tests; handler tolerates either callback order |
| Mock global statics still process-wide | Suite stays `.serialized`; `simulateStateRestoration` reset in `defer` |

## Future (out of scope)

- Public `shutdown()`/`invalidate()` on `ReliaBLEManager`.
- Keyed shared-stack registry ("two façades, one stack") if a real use case appears.
- Debug log when a second manager is created; N-manager stress tests.
- `package`-visibility test hooks replacing the remaining `test*` actor methods.

## Oracle review

**Round 2** (review-mode oracle, go/no-go, two passes): pass 2 added reconnect-task
cancellation via a nonisolated `TaskRegistry`, terminal `shutdown()` semantics that preserve
persisted reconnect intent, the exact `ensureCentralManager()` member disposition, and the
live-managers-only restore-id uniqueness wording. Pass 1's initial no-go was resolved by (a) `EventPipeline` as a
`nonisolated let` stored property initialized at actor init (no post-init write, no
`nonisolated(unsafe)`), (b) an explicit test-access strategy (internal `bluetooth` +
`@testable`), (c) a spec-based, actor-free cold-relaunch fixture, and (d) merging the singleton
purge and minimal harness migration into one green checkpoint. All incorporated above.

**Round 1** (grok-4.5, chat-mode fallback). Must-fix findings — deinit-isolation-safe
teardown, consumer-before-factory ordering, preserved-guarantee table, sharing-break gaps
(global auth, restore-id uniqueness, per-stack discovery), cold-relaunch harness subtlety
(streams retain the actor), and the two-manager isolation test — are incorporated above.
