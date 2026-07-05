# Peripheral Connection Lifecycle + Connection-State Stream: Plan
*Issue #36 · 2026-06-30*

## Goal

Flesh out the peripheral connection lifecycle in ReliaBLE — implement real `connect(to:)` / `disconnect(from:)` driving the CoreBluetooth connection delegate paths, and expose per-peripheral `ConnectionState` changes to the integrating app via an `AsyncStream`, consistent with the existing stream patterns on `BluetoothActor`. Multi-device aware. Ship a Demo consumer (connect/disconnect UI on the device-detail screen).

Covers the connection-oriented halves of **FR-2.3.1** (connection-change callbacks) and **FR-1.3.1** (connection-stability status). Data-transmission halves (FR-2.3.2 / FR-1.3.2) and auto-reconnect (FR-1.2, issue #37) are out of scope.

## Background

All current state verified by exploration (file:line refs below).

### Library — connect path & streams (`Sources/ReliaBLE/`)
- `ReliaBLEManager.connect(to:)` (`ReliaBLEManager.swift:162`) → `BluetoothActor.shared.connect(id:)`.
- `BluetoothActor.connect(id:)` (`BluetoothActor.swift:604`): guards `centralManager`, looks up `cbPeripherals[id]`, calls `centralManager.connect(cbPeripheral, options: nil)`. **No disconnect, no connection delegate methods exist.**
- AsyncStream broadcaster pattern (the template to mirror):
  - Continuation registries (actor-isolated): `stateContinuations`/`discoveryContinuations`/`peripheralsContinuations` (`BluetoothActor.swift:116–118`).
  - `nonisolated` factory methods mint a fresh stream per call: `stateStream()` (:131, `.bufferingNewest(1)`), `peripheralDiscoveriesStream()` (:155), `discoveredPeripheralsStream()` (:166).
  - `register(...)` (:179–196): yields replay value (state/list streams), stores continuation, sets `onTermination` → remover. Removers at :205–207.
  - `broadcast(_:to:)` (:213) loops continuations and `.yield`s.
- Delegate wiring: `BluetoothDelegateShim: NSObject, CBCentralManagerDelegate` (`BluetoothActor.swift:628`). Shim yields into an internal unbounded `AsyncStream` of `DelegateEvent` (:272); a single actor Task drains it via `process(_:)` (:290). Implemented: `centralManagerDidUpdateState` (:638 → `.stateUpdate`), `didDiscover` (:644 → `.discovered`). **No `didConnect`/`didDisconnectPeripheral`/`didFailToConnect`.** Adding one: extend `DelegateEvent` enum (:55), add shim method that yields, handle in `process`, add `handle*` on the actor.
- Peripheral tracking: `Peripheral` is a `Sendable` struct keyed by `id` (`Models/Peripheral.swift`). Actor holds value snapshots `discoveredPeripherals: [Peripheral]` (:99) and live refs `cbPeripherals: [String: CBPeripheral]` (:106, never escapes actor). Populated in `handlePeripheralDiscovered` (:489).
- `ReliaBLEManager` public surface: `init`, `authorizeBluetooth`, `startScanning`, `stopScanning`, `connect(to:)`; properties `state`, `currentState`, `peripheralDiscoveries`, `discoveredPeripherals`. Every entry point does `ensureInitialized(log:)` then delegates to the actor.

### Tests / mock harness (`Tests/ReliaBLETests/`, `Sources/ReliaBLEMock/`)
- `forceMock: true` is hardcoded at `BluetoothActor.swift:280`; production factory ignores it, mock honors it.
- `ReliaBLEManagerTests.swift` is `@Suite(.serialized)` (process-wide singletons). `Mock.makeManager()` + `SimulationConfig.ensureConfigured()` set up `CBMCentralManagerMock.simulateInitialState(.poweredOn)` / `simulatePeripherals([spec])` / `simulateAuthorization`.
- Test spec: `Mock.makeTestPeripheralSpec()` (:647) builds `CBMPeripheralSpec.simulatePeripheral(...).advertising(...).connectable(name:..., services:[], delegate:nil).build()`.
- Current connection test `connectToDiscoveredPeripheralSucceeds` (:385) only asserts `connect(to:)` doesn't throw — **no didConnect/disconnect/fail coverage.** No usage of `simulateConnection`/`simulateDisconnection` anywhere. `Tests/ReliaBLETests/Mocks/` exists but is empty.
- Stream assertion helpers: `firstEvent(from:withinNanoseconds:)` (:744) races a stream against a sleep inside a TaskGroup; direct iterator+replay via `makeAsyncIterator()`/`next()`.

### Demo (`Demo/ReliaBLE Demo/ReliaBLE Demo/Central/`)
- `CentralView.swift:112` `.task { withTaskGroup { ... } }` with 3 `group.addTask` loops: `manager.state` → `viewModel.updateState` (@MainActor); `peripheralDiscoveries` → `store.insertDiscovery`; `discoveredPeripherals` → `store.syncDevices` (both off-main `DeviceStoreActor`).
- `deviceList` NavigationLink (:130) destination is a static `Text("Device Details")` placeholder — to be replaced by a real detail view.
- `CentralViewModel` (`:39`) is `@Observable` (not @MainActor): `var currentState`, `@MainActor func updateState(_:)` (:50). Devices come from `@Query` in the View, not the VM.
- `DeviceStoreActor` persists `Device` + `DiscoveryEvent` to SwiftData, writes always off-main (`assertWritesOffMainThread()` :136). **Connection state is persisted nowhere** — keep it that way.
- Sidebar scanning button (`CentralView.swift:43`) is the state-driven button template (conditional on `viewModel.currentState` cases).

## Approach

Purely additive — reuse the existing broadcaster machinery and delegate-shim pipeline; touch no existing surfaces.

**Models.** Two new public `Sendable` types in `Sources/ReliaBLE/Models/` (parity with `Peripheral`):
- `ConnectionState` enum: `.connecting`, `.connected`, `.disconnecting`, `.disconnected(reason: PeripheralError?)`, `.failed(reason: PeripheralError?)`. The `reason` is `nil` for a clean/explicit disconnect and non-`nil` for an unexpected drop or connect failure (Q2-B). Stays `Equatable`/`Hashable` because `PeripheralError` is a finite mapped enum.
- `ConnectionStateChange` struct: `{ let peripheralId: String; let state: ConnectionState }` — the element of the per-event stream. (A raw tuple would not be a clean public/`Sendable`/`Equatable` surface.)

**Error mapping (Q2-B).** Extend `PeripheralError` (`Models/PeripheralError.swift`, today `.notFound`/`.bluetoothUnavailable`) with connection-failure cases (e.g. `.connectionFailed`, `.connectionTimeout`, `.peripheralDisconnected`, `.unknown`) and a private `CBError` → `PeripheralError` mapper so raw CoreBluetooth `Error` never leaks into the public API. Keep it `Equatable`/`Sendable`.

**Actor registry + dual surface (Q1-C).** Add `connectionStates: [String: ConnectionState]` to `BluetoothActor` (beside `cbPeripherals`/`discoveredPeripherals`, keyed by `Peripheral.id`, mutated only on-actor). Expose **two** surfaces fed from the same registry mutation:
- **Per-event stream** `connectionStateChangesStream() -> AsyncStream<ConnectionStateChange>` — no replay (mirrors `peripheralDiscoveriesStream()`, `BluetoothActor.swift:155`). The primary, granular subscription; a single-device view/service filters `where $0.peripheralId == id`.
- **Snapshot accessor** `currentConnectionStates: [String: ConnectionState] { get async }` — a one-shot read of the whole registry (mirrors `currentState`), so a view appearing can seed itself without waiting for the next change.

Add a `connectionStateChangesContinuations` registry + `nonisolated connectionStateChangesStream()` factory + `register(...)` (copy the non-replay discovery path). Each `handle*` mutates the registry, then broadcasts the single `ConnectionStateChange` to the change-continuations via the existing `broadcast(_:to:)` helper.

**Connect/disconnect.** Extend `connect(id:)` to optimistically set `.connecting` + broadcast the change before calling `central.connect` (CoreBluetooth has no "connecting" callback). Add `disconnect(id:)` that sets `.disconnecting` + broadcasts, then calls `central.cancelPeripheralConnection(cbPeripheral)`. Both keep the existing `guard centralManager`/`cbPeripherals[id]` → `PeripheralError` behavior.

**Delegate wiring & id resolution.** Extend `DelegateEvent` (`:55`) with `.connected`, `.disconnected(Error?)`, `.connectFailed(Error?)`, each carrying the raw `CBPeripheral` wrapped in the existing `SendableWrapper` (exactly how `.discovered` hops the non-`Sendable` `CBPeripheral` off the delegate queue — the shim does **not** resolve the id). Add the three `CBCentralManagerDelegate` methods to `BluetoothDelegateShim` (`:628`); each yields its event. Route them in `process(_:)` (`:290`) to actor handlers `handleDidConnect/handleDidDisconnect/handleDidFailToConnect`.

The handlers resolve `Peripheral.id` through a **single private on-actor helper** — `id(for cbPeripheral: CBPeripheral) -> String?` — that does a reverse object-identity lookup in the existing registry: `cbPeripherals.first { $0.value === cbPeripheral }?.key`. All three handlers call it; if it returns `nil` (should not happen — the callback's peripheral is already in `cbPeripherals` because `connect(id:)` looked it up there), log and drop. This helper performs **zero id derivation** — it reads back the key `handlePeripheralDiscovered` (`:489`) already assigned, so `handlePeripheralDiscovered` stays the library's *single* source of `id` truth. That is what keeps the connection layer FR-8.5-safe: when FR-8.5 rewrites the derivation site, these handlers keep working unchanged (see Decision 5). Tag the helper with a `// TODO: FR-8.5` breadcrumb mirroring the one at `:508`, so a grep for `FR-8.5` surfaces every coupled site. Each handler then updates the registry (`.connected` / `.disconnected(reason:)` / `.failed(reason:)`), logs the mapped error via a `.peripheral(id)` tag, and broadcasts the change.

**Ordering.** No extra serialization or "pending" machinery is needed: every mutation + broadcast runs on `@BluetoothActor`, and both the internal delegate `AsyncStream` and the per-subscriber output streams preserve emission order. So a subscriber sees `.connecting` (emitted synchronously inside `connect(id:)`) strictly before the later `.connected`/`.failed` (emitted when the delegate event drains). Rapid interleaved connect/disconnect calls are serialized by the actor — last write wins in the registry and every transition is still emitted in order.

**Façade.** `ReliaBLEManager` adds:
- `var connectionStateChanges: AsyncStream<ConnectionStateChange>` (forwards to `connectionStateChangesStream()`),
- `var currentConnectionStates: [String: ConnectionState] { get async }` (forwards to the actor snapshot),
- `func disconnect(from: Peripheral) async throws` (`ensureInitialized` → actor `disconnect(id:)`).

Additive — no existing call sites change.

**Demo.** Add a 4th `group.addTask` in `CentralView`'s `.task` looping `for await change in manager.connectionStateChanges { await viewModel.updateConnectionState(change) }`. Add `var connectionStates: [String: ConnectionState] = [:]` + `@MainActor func updateConnectionState(_ change: ConnectionStateChange)` (does `connectionStates[change.peripheralId] = change.state`) to `CentralViewModel` (transient only — never SwiftData; the Demo owns retention, which is why registry entry-lifecycle is a non-issue — Q3). Replace the static `Text("Device Details")` `NavigationLink` destination with a real detail view that renders `viewModel.connectionStates[device.id]` and a context-aware Connect/Disconnect button (mirroring the sidebar's `currentState`-driven scanning button).

**Tests.** Drive connect-success / disconnect / connection-failure through the mock central and assert the emitted `ConnectionStateChange` sequence via the existing `firstEvent`/iterator helpers, including a failure case that asserts the mapped `PeripheralError` reason. Preserve `@Suite(.serialized)` and `forceMock`. (Mock-simulation API details in Work Item #5.)

## Work Items

Land 1–4 together (library + delegate paths must build as a unit); 5–7 follow.

> **Progress (orchestrator):** ✅ ALL COMPLETE. Items 1–4 (library core), 5 (tests: 32/32 pass incl. 4 new connection tests), 6 (Demo: detail view + Connect/Disconnect UI, builds), 7 (DocC GettingStarted example + final `swift build`/`swift test` green). Three-target trick, `forceMock`, lazy central init all verified intact.

1. **`Models/ConnectionState.swift` + `ConnectionStateChange` (new); extend `PeripheralError`.** Public `Sendable` enum (five cases, `reason: PeripheralError?` on the two terminal cases) + the change struct. Add connection-failure cases to `PeripheralError` and the `CBError`→`PeripheralError` mapper. Compiles independently.
2. **`BluetoothActor.swift` — registry, per-event stream, delegate paths.** Add `connectionStates` dict + `connectionStateChangesContinuations`; `connectionStateChangesStream()` + `register(...)` (copy the non-replay `peripheralDiscoveries` pattern) + `currentConnectionStates` accessor. Extend `DelegateEvent` (:55) with `.connected/.disconnected/.connectFailed` carrying a `SendableWrapper<CBPeripheral>` (+ `Error?`); add the three shim delegate methods (`:628`) and `process(_:)` routes (:290); add a single private `id(for cbPeripheral:)` reverse-identity-lookup helper (tagged `// TODO: FR-8.5`) plus `handleDidConnect/handleDidDisconnect/handleDidFailToConnect` that call it, map the error, log via `.peripheral(id)`, and broadcast the change. Keep `forceMock`, lazy-init, `SendableWrapper`, `currentBluetoothState`.
3. **`BluetoothActor.swift` — connect/disconnect bodies.** Extend `connect(id:)` (:604) to set `.connecting` + broadcast before `central.connect`; add `disconnect(id:)` (set `.disconnecting` + broadcast, then `central.cancelPeripheralConnection`).
4. **`ReliaBLEManager.swift` — public surface.** Add `connectionStateChanges` stream, `currentConnectionStates` async accessor, and `disconnect(from:) async throws`, all delegating through `ensureInitialized`. *(Breaking addition — pre-1.0 OK.)*
5. **`ReliaBLEManagerTests.swift` — coverage.** Add mock-driven tests for connect-success, disconnect, and connection-failure asserting the `ConnectionStateChange` sequence (incl. the mapped `PeripheralError` reason on failure); one Sendable/multi-subscriber proof for the new stream. Drive it with whatever `CBMPeripheralSpec` connection delegate / `simulate*` surface the harness can attach (the current spec is `delegate: nil` — confirm at the keyboard).
6. **Demo — `CentralView.swift` + `CentralViewModel.swift`.** 4th `.task` consumer looping `connectionStateChanges` → `@MainActor updateConnectionState(_:)` merging into the transient `connectionStates` dict; real device-detail view (reads `connectionStates[device.id]`) with context-aware Connect/Disconnect button. *(Read `Demo/CLAUDE.md` first; delegate to a sub-agent per AGENTS.md.)*
7. **Docs + verify.** Add the lifecycle + stream example to `Documentation.docc/GettingStarted.md` (one paragraph — DocC must track the public API per AGENTS.md). `swift build` + `swift test`; confirm three-target constraint, `forceMock`, and lazy-init intact.

## Decisions (resolved at mid-flow check-in)

1. **Dual surface (Q1-C).** Ship both a per-event `connectionStateChanges: AsyncStream<ConnectionStateChange>` (primary, granular — lets a single-device view/service subscribe directly) and a `currentConnectionStates` async snapshot accessor for one-shot seeding. No aggregate *snapshot stream* is shipped — deferred until a multi-device dashboard consumer needs it (avoid speculative surface).
2. **Errors carried, mapped (Q2-B).** `.failed(reason:)` and unexpected `.disconnected(reason:)` carry a `PeripheralError?`, mapped from `CBError` so integrators can surface addressable issues without importing CoreBluetooth. Raw `Error` is never exposed; the enum stays `Equatable`/`Sendable`.
3. **Registry retention (Q3 — N/A at the library boundary).** The Demo owns its own retention in the transient `connectionStates` dict (fed by the per-event stream), so terminal-entry lifecycle is not a public contract. Internally the actor registry keeps the last-known state per id (so `currentConnectionStates` stays meaningful and to support #37); it is cleared on `invalidatePeripherals()`.
4. **Demo scope (Q4-A).** The Demo work stays as Work Item #6 in this plan (matches issue #36's "ship alongside" section); implemented by a sub-agent that reads `Demo/CLAUDE.md` first.
5. **FR-8.5 coupling — one resolution point, tracked.** `CBPeripheral → Peripheral.id` resolution in the connect handlers goes through a single private `id(for:)` helper that *derives nothing* — it reverse-looks-up the key `handlePeripheralDiscovered` already assigned. This avoids planting a second copy of the name-based derivation (`cbPeripheral.name ?? localName ?? uuidString`, `:508`) that FR-8.5 would have to hunt down. Consequence: the connection layer inherits — and never worsens — the current same-name-collision caveat, and needs no rewrite when FR-8.5 lands. Both the helper and `:508` carry `// TODO: FR-8.5` so a single grep surfaces every site. Two integration points are explicitly deferred to FR-8.5 (see Open Questions).

## Open Questions

None blocking for this issue. Confirm at the keyboard:
- Exact Nordic `CoreBluetoothMock` API for simulating connect-success / disconnect / connect-failure given the spec is built `delegate: nil` (may require attaching a `CBMPeripheralSpec` connection delegate). Work Item #5.
- Final `CBError` code → `PeripheralError` case list; the mapper is exhaustive with a `.unknown` fallback. Work Item #1.

**Deferred to FR-8.5** (tracked here so they aren't forgotten — not in scope now):
- **Registry key migration on late id assignment.** FR-8.5.2 lets the app hand back a unique id *after* discovery, so a peripheral may be filed under a provisional id before its final one is known. When the key changes provisional→unique, the `connectionStates` entry must migrate to the new key. The `id(for:)` helper still resolves the object correctly; it's the registry keying that needs the migration.
- **Cross-reconnection persistence (FR-8.5.3).** Once ids are stable across reconnections, the id-keyed `connectionStates` registry becomes the natural home for "consistent tracking across reconnections" — design it together with FR-8.5.3 and the #37 auto-reconnect work.

## References
- Issue #36. Follow-up: #37 (auto-reconnect, builds on this). Mock harness: #31.
- PRD: FR-2.3.1, FR-1.3.1 (in-scope); FR-2.3.2, FR-1.3.2, FR-1.2, FR-5.1; **FR-8.5** (PRD:106–109 — unique-id-from-manufacturing-data; connection-layer coupling tracked in Decision 5 + Open Questions).
- Prior stream plan: `docs/plans/combine-to-asyncstream-2026-06-18.md` (AsyncStream broadcaster pattern this mirrors).
- Key files: `Sources/ReliaBLE/BluetoothActor.swift`, `ReliaBLEManager.swift`, `Models/Peripheral.swift`; `Tests/ReliaBLETests/ReliaBLEManagerTests.swift`; `Demo/.../Central/CentralView.swift`, `CentralViewModel.swift`, `DeviceStoreActor.swift`.
- Architecture: root `AGENTS.md` (`@BluetoothActor`, three-target mock trick, lazy central init); `Demo/CLAUDE.md` (Demo conventions, XcodeBuildMCP).
