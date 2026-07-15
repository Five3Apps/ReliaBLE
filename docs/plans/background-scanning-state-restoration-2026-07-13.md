# Background Scanning + State Restoration: Plan
*Issue #38 (FR-8.3) · 2026-07-13*

## Goal
Extend the completed foreground scanning foundation (FR-8.1) so ReliaBLE keeps delivering discovery events while the integrating app is backgrounded, and add **full CoreBluetooth state restoration** so the app is relaunched into a working BLE session — restoring both an **active scan** and **active/pending connections** — after iOS terminates it. The integrating app supplies the restoration identifier, with a sane default. This also discharges the **"Background reconnection" follow-up** deferred by the auto-reconnect plan (`docs/plans/auto-reconnect-backoff-2026-07-05.md`, now merged as PR #41).

## Background
_All state below verified against the current worktree (post-#41 rebase onto `origin/master` @ `3d19332`)._

**No prior background/restoration work exists** — no code touches `CBCentralManagerOptionRestoreIdentifierKey`, `willRestoreState`, `UIBackgroundModes`, or background scan options. This is greenfield on top of the finished scanning/stream/connection/**auto-reconnect** foundation. PR #41 (auto-reconnect) explicitly deferred background reconnection (standing connects, restore identifier, `bluetooth-central`, `NotifyOnConnection/Disconnection`) to "its own issue" — this plan is that issue.

Current seams (`Sources/ReliaBLE/`, verified line numbers):
- **Central creation** — `setupCentralManager()` at `BluetoothActor.swift:313`; factory call `CBCentralManagerFactory.instance(delegate:queue:options:forceMock:)` at `:331` passes **`options: nil`**. Lazy/auth-gated via `ensureInitialized(log:reconnectPolicy:)` at `:291` (creates central only when `authorization == .allowedAlways`).
- **Scanning** — `startScanning(services:)` at `:441` → `scanForPeripherals(withServices:options:)` at `:452` with **`options: nil`**; `stopScanning()` at `:462`.
- **Delegate shim** — `BluetoothDelegateShim` at `:948` (`didDiscover` at `:966`, plus `didUpdateState`/`didConnect`/`didFailToConnect`/`didDisconnect`); yields a `DelegateEvent` (enum at `:61`) drained by `process(_:)` at `:341` → `handle*`. **No `willRestoreState`.**
- **Discovery plumbing** — `handlePeripheralDiscovered` at `:546` broadcasts `PeripheralDiscoveryEvent` and updates `discoveredPeripherals`/`cbPeripherals`. Broadcaster: `nonisolated` per-subscriber stream factories + `register(...)` + `broadcast(_:to:)`.
- **Connection + reconnect state (from #41, actor-isolated, never escapes):** `cbPeripherals` `:117`, `connectionStates` `:130`, `reconnectPolicy` `:134`, `reconnectEnabled` `:135`, `intentionalDisconnects` `:136`, `reconnectAttempts` `:137`, `reconnectTasks` `:138`.
- **Connect/disconnect** — `connect(id:autoReconnect:)` at `:671`; the OS option `[CBConnectPeripheralOptionEnableAutoReconnect: true]` is built at `:692`. `disconnect(id:)` at `:705`. Handlers: `handleDidConnect` `:737`, `handleDidDisconnect` `:750` (honors `isReconnecting`), `handleDidFailToConnect` `:799`.
- **Library reconnect ladder (Tier 1)** — `armReconnect(id:)` `:817` → `scheduleReconnect(id:attempt:)` `:835`, whose retry `Task` uses `Task.sleep` at `:863`. **This ladder is process-scoped and does NOT survive app suspension/termination** — the gap restoration must close.
- **Config** — `ReliaBLEConfig.swift`: logging fields + `reconnectPolicy` `:43` (`ReconnectPolicy` `:52-84`). Flows `init(config:)` → `ensureInitialized(log:reconnectPolicy:)`; precedent for adding a background/restoration field.
- **State model** — `ConnectionState` (`Models/ConnectionState.swift:10`): `.connecting`, `.reconnecting(source:attempt:nextRetryAt:)`, `.connected`, `.disconnecting`, `.disconnected(reason:)`, `.failed(reason:)`; `ReconnectSource` (`.system`/`.library`) at `:50`.
- **Public API** — `ReliaBLEManager.swift`: `init(config:)`, `authorizeBluetooth()` `:118`, `startScanning(services:)` `:160`, `stopScanning()` `:166`, `connect(to:autoReconnect:)` `:186`, `disconnect(from:)` `:199`, plus `state`/`peripheralDiscoveries`/`discoveredPeripherals`/`connectionStateChanges` streams.
- **Mock limitation** — `CoreBluetoothMock` cannot simulate `CBConnectPeripheralOptionEnableAutoReconnect` (see the comment at `BluetoothActor.swift:914`) and cannot synthesize `willRestoreState`. This bounds test coverage (see Approach).

**Background-BLE pitfalls to design around** (external research):
1. Service-UUID filter is **mandatory** in background; `nil`-service scans return nothing.
2. Advertisement data is truncated/absent in background.
3. `AllowDuplicatesKey` is silently ignored + discoveries are coalesced/throttled.
4. Restoration ID must be **unique + stable** per manager; reuse corrupts state.
5. `willRestoreState` is the **first** delegate call on relaunch — delegate must be attached at central init, before any other use.
6. Restoration requires recreating the manager with the **exact same ID** before any other BLE call.
7. Only actively-scanning/connecting managers are preserved.
8. Duplicate `CBCentralManager` instances break the restoration chain (favor the existing single-instance facade).
9. Missing Info.plist `bluetooth-central` → no background scanning and no relaunch.
10. ~10s execution budget on wake; keep restoration-path work async and cheap.
11. Restored `CBPeripheral`s (both discovered **and connected/connecting**) arrive with **no delegate** — must be re-wired immediately or all subsequent events are lost.

## Approach

The work is **purely additive** and re-uses every existing pattern: the `ReliaBLEConfig` → `ensureInitialized` config flow, the `DelegateEvent` → shim → `process(_:)` → `handle*` drain, the broadcaster streams, and the single `CBCentralManagerFactory` creation seam. Nothing about `Peripheral`, `CBCentralManagerFactory`, `Package.swift`, or production logging changes.

**Restoration ID via config, `nil` by default.** Add one field `restoreIdentifier: String?` (default `nil`) to `ReliaBLEConfig`, mirroring the `reconnectPolicy` precedent. `nil` = restoration disabled, lazy contract fully preserved. When set, it is passed through `init(config:)` → a config-aware `ensureInitialized` overload → `setupCentralManager`, which builds `[CBCentralManagerOptionRestoreIdentifierKey: id]` instead of `nil` at the factory call (`BluetoothActor.swift:331`).

**Reconciling lazy init with restoration.** The `.allowedAlways` creation gate is **preserved** — this is *not* a relaxation. State restoration only preserves state for apps that were already authorized and had active BLE, so if auth isn't `.allowedAlways` there is nothing to restore and the library behaves exactly as today. The change is narrow: when `restoreIdentifier` is set **and** auth is `.allowedAlways`, `ensureInitialized` (already fired fire-and-forget from `init`) creates the central with the restore-id option and its delegate attached — which is what makes `willRestoreState` (the first callback on relaunch) reachable. The app triggers restoration simply by constructing `ReliaBLEManager(config:)` with the same `restoreIdentifier` early in launch; no separate `restore(launchOptions:)` entry point is needed, because CoreBluetooth delivers `willRestoreState` off the recreated, delegate-attached manager before any other call.

**Restoration handling.** Extend the closed `DelegateEvent` enum (`:61`) with `case willRestore(...)` (`Sendable`-boxed payload, yielded on the delegate queue like other events). `BluetoothDelegateShim` (`:948`) implements `centralManager(_:willRestoreState:)`; `process(_:)` (`:341`) routes it to a new actor-isolated `handleWillRestoreState(_:)` that:
1. **Peripherals** — reads `CBMCentralManagerRestoredStatePeripheralsKey`, re-wires each restored `CBPeripheral`'s delegate (they arrive delegate-less) and repopulates `cbPeripherals` (`:117`), keyed by the same identity rule as `handlePeripheralDiscovered` (`:546`).
2. **Scan** — reads `CBMCentralManagerRestoredStateScanServicesKey`/`…ScanOptionsKey`; if a scan was active, resumes `scanForPeripherals` with the restored (mandatory non-nil) service filter.
3. **Broadcast** — surfaces restored peripherals through the **existing** `discoveryContinuations`/`peripheralsContinuations`. No separate restoration API (per the issue's acceptance criteria). All work is dict lookups + map inserts, well inside the ~10s wake budget.

**Connection state restoration (the deferred #41 item).** The restored peripheral array also contains devices that were **connected or connecting** at termination (each `CBPeripheral.state` says which). Standing connects + Tier-0 OS auto-reconnect (`CBConnectPeripheralOptionEnableAutoReconnect`, `:692`) are daemon-held and relaunch the app on connect; the Tier-1 library ladder (`scheduleReconnect`/`Task.sleep`, `:835`/`:863`) died with the process. So `handleWillRestoreState` also rehydrates connection state:
- Runs **after** the peripheral step has repopulated `cbPeripherals` (`:117`); on a cold relaunch `reconnectAttempts`/`reconnectTasks` are already empty (fresh process), so no clearing is needed.
- Seed `connectionStates[id]` (`:130`) from the restored `CBPeripheral.state` (`.connected` → `.connected`, `.connecting` → `.connecting`) and broadcast on `connectionStateChanges`.
- Re-arm Tier-1 **intent**: re-insert restored connected/connecting ids into `reconnectEnabled` (`:135`) so a post-relaunch drop can re-arm `armReconnect` (`:817`).
- **Do not** synchronously reconnect on the restoration path (10s budget) — rely on the OS holding standing connects, with normal `handleDidConnect`/`handleDidDisconnect` (`:737`/`:750`) callbacks flowing afterward.
- **Teardown interaction:** if Bluetooth is off/unauthorized at relaunch, the `didUpdateState` that follows `willRestoreState` runs `invalidatePeripherals` (`:620`) and clears the just-restored `connectionStates`/`reconnectEnabled` — this is intentional (nothing to restore when BT is unavailable). Restoration assumes `willRestoreState` is followed by `.poweredOn`; no re-seed is attempted.

**Connect notification options — off for now.** `CBConnectPeripheralOptionNotifyOnConnection` / `…NotifyOnDisconnection` (which make iOS post a system alert when the app isn't running) are deliberately **not** passed in the first cut; connect options stay as-is (`EnableAutoReconnect` only, `:692`). This keeps the "it just works" default quiet and predictable; they can be added non-breakingly later if a use case appears (see Decisions Q6).

**Background scan constraints.** No new public scan parameter — the existing `startScanning(services:)` argument already satisfies the mandatory background service filter. Add a warning log when `services` is empty/`nil`. `AllowDuplicatesKey` is intentionally not set (ignored in background). Truncated background advertisement data is a documentation concern on `AdvertisementData`.

**Testability boundary.** `CBMCentralManagerMock` can synthesize neither `willRestoreState` nor the `EnableAutoReconnect` state machine (`:914`), so tests exercise `handleWillRestoreState(_:)` (and the new `DelegateEvent` case) **directly** at the actor boundary with a hand-built restoration dictionary — asserting map/`connectionStates`/`reconnectEnabled` population, stream broadcast, and scan resumption. The eager-vs-lazy creation branch is covered via the existing `Mock.makeManager` harness with/without a `restoreIdentifier`.

## Work Items
_Ordered so each step compiles and is independently testable; steps 2–4 add unreachable code until step 5 wires the restore identifier into central creation._

1. **Config field** — add `restoreIdentifier: String? = nil` to `ReliaBLEConfig` (`ReliaBLEConfig.swift`) and its init; document the "stable across launches" requirement.
2. **Event + shim** — extend `DelegateEvent` (`:61`) with `case willRestore(...)` and implement `centralManager(_:willRestoreState:)` in `BluetoothDelegateShim` (`:948`). No behavior change yet.
3. **Restoration handler — scan + peripherals** — implement `handleWillRestoreState(_:)` + dispatch in `process(_:)` (`:341`): re-wire restored peripherals, repopulate `cbPeripherals` (`:117`), resume scan, broadcast via existing continuations. Reuse identity logic from `handlePeripheralDiscovered` (`:546`).
4. **Restoration handler — connections** — in the same handler (after step 3 has populated `cbPeripherals`), seed `connectionStates` (`:130`) from restored `CBPeripheral.state`, broadcast on `connectionStateChanges`, and re-arm `reconnectEnabled` (`:135`) for connected/connecting peripherals. No synchronous reconnect.
5. **Restore-id creation path** — thread `restoreIdentifier` through a config-aware `ensureInitialized` overload (`:291`) into `setupCentralManager` (`:313`); build `[CBCentralManagerOptionRestoreIdentifierKey: id]` at the factory call (`:331`, keep `forceMock: true`). **Keep the `.allowedAlways` gate unchanged** — creation stays authorization-gated (if not authorized, there is nothing to restore). Wire `config.restoreIdentifier` through `ReliaBLEManager.init`.
6. **Background scan guard** — add the empty-filter warning in `startScanning` (`:441`).
7. **Tests** — cover the new `DelegateEvent` case, `handleWillRestoreState` (scan + connection rehydration), and the eager/lazy branch — direct actor-boundary tests + `Mock.makeManager` config variants. Mock can't fire `willRestoreState` or `EnableAutoReconnect` (`:914`); end-to-end mock fidelity is a follow-up (**#42**).
8. **DocC** — add a "Background scanning & state restoration" section to `GettingStarted.md` (Info.plist `bluetooth-central`, `restoreIdentifier`, mandatory service filter, restored connections, and the deliberate off-by-default notification options per Q6) and note the eager-creation exception in `Topics/Concurrency.md`.
9. **Demo** — delegate to a sub-agent (must read `Demo/CLAUDE.md` first): add `bluetooth-central` to the Demo `Info.plist`, set a `restoreIdentifier`, demonstrate background discovery **and** a restored standing connection. Additive only.

## Decisions (resolved at mid-flow check-in)
1. **Restoration ID API shape** — single optional `restoreIdentifier: String?` on `ReliaBLEConfig`, `nil` = off; documented bundle-derived default *pattern*, not auto-applied.
2. **Background filter enforcement** — warn + log on empty/`nil` filter, still pass through; foreground behavior unchanged.
3. **Creation gate** — central creation stays gated on `.allowedAlways` (unchanged); `restoreIdentifier` only adds the restore-id option to the existing init-time creation. No auth-gate relaxation — if BT isn't authorized there is nothing to restore.
4. **Restored-state surfacing** — reuse existing `discoveredPeripherals` / `connectionStateChanges` streams; no dedicated restoration event.
5. **Test depth** — direct actor-boundary tests of `handleWillRestoreState` / the new `DelegateEvent` case (mock can't fire `willRestoreState`/`EnableAutoReconnect`). End-to-end mock fidelity filed as follow-up **#42**.
6. **Connect notification options** — **off by default for now.** `NotifyOnConnection`/`NotifyOnDisconnection` are not passed; connect options stay `EnableAutoReconnect`-only. Chosen for "it just works" reliability; addable non-breakingly later.

## Orchestration Progress
_Maintained by the orchestrator. Dispatched work items group the plan steps above._
- [x] **A. Library core** (steps 1–6): config field, `DelegateEvent.willRestore` + shim, `handleWillRestoreState` (scan/peripherals + connection rehydration), restore-id creation path, background-scan guard.
- [x] **B. Tests** (step 7): new `DelegateEvent` case, `handleWillRestoreState`, eager/lazy branch.
- [x] **C. DocC** (step 8): `GettingStarted.md` background section + `Topics/Concurrency.md` eager-creation note.
- [x] **D. Demo** (step 9): Demo `Info.plist` `bluetooth-central`, `restoreIdentifier`, restored standing connection.

## References
- Issue #38 (FR-8.3.1, FR-8.3.2); PRD FR-8.3; foundation FR-8.1 (#3, completed)
- **Handoff:** `docs/plans/auto-reconnect-backoff-2026-07-05.md` → "Deferred / follow-up: Background reconnection" (PR #41, merged) — this plan addresses it.
- Apple: [Core Bluetooth Background Processing & State Preservation/Restoration](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html); `CBCentralManagerOptionRestoreIdentifierKey`; `centralManager(_:willRestoreState:)`; `CBConnectPeripheralOptionNotifyOnConnection`/`…NotifyOnDisconnection`; `UIBackgroundModes` (`bluetooth-central`)
- Architecture: `AGENTS.md` (`@BluetoothActor`, three-target mock harness, lazy init, `forceMock`); Demo work per `Demo/CLAUDE.md`
- Follow-up filed: **#42** (simulate `willRestoreState` in `CoreBluetoothMock` for end-to-end restoration tests).
- Prior plans: `docs/plans/connection-lifecycle-stream-2026-06-30.md`, `docs/plans/auto-reconnect-backoff-2026-07-05.md`
