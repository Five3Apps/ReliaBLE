# Demo: exercise ReliaBLE from a background-actor SwiftData stack: Plan
*Issue #20 · 2026-06-27*

## Goal

Refactor the Demo app's SwiftData layer so **all writes** run on a background `ModelActor`, while reads stay on `@MainActor` via `@Query`. The Demo then exercises `ReliaBLEManager` across actor boundaries at PR-time — catching inadvertent `@MainActor` creep in the library — and doubles as a concrete off-main persistence pattern for consumers. No library changes.

Tracked under parent #10 as a **Preventive Measure** in `docs/investigations/swift6-concurrency-audit-2026-05-13.md` (not a numbered migration step). Depends on the Step 4 `Sendable` façade (#18) and `AsyncStream` surfaces (#12) being in place; both are merged on the current branch.

## Background (verified pre-change state)

**Library (ready — no work needed):**
- `ReliaBLEManager` is `public final class ReliaBLEManager: Sendable`, nonisolated, forwarding to internal `BluetoothActor.shared` (`ReliaBLEManager.swift:38`).
- Three event surfaces return fresh per-subscriber `AsyncStream`s: `state`, `peripheralDiscoveries`, `discoveredPeripherals` (`ReliaBLEManager.swift:84–120`).
- Element types `Peripheral`, `PeripheralDiscoveryEvent`, `BluetoothState` are `Sendable` value types — safe to hand across isolation domains from stream loops.
- DocC `Concurrency.md` documents the isolation contract for consumers.

**Demo consumption (`Demo/ReliaBLE Demo/.../Central/`) — the problem:**
- `CentralView` already consumed streams via three `.task { for await … }` blocks (post-Step 3), but persistence still ran on `@MainActor`.
- `CentralViewModel.insertDiscovery(_:into:)` and `syncDevices(_:into:)` were `@MainActor` methods that took a `ModelContext` and wrote directly inside the stream loops (`CentralViewModel.swift:55–84`; wired from `CentralView.swift:105–114`).
- `clearAllData`, swipe-delete (`deleteDiscoveries` / `deleteDevices`) also used a stored `ModelContext` on the view-model.
- `@Query` in `CentralView` handled reads on main — this part was already correct and stays.
- `ReliaBLE_DemoApp.swift` provides a single shared `ModelContainer` via `.modelContainer(sharedModelContainer)` and injects `ReliaBLEManager` via `@Environment(\.bleManager)`.
- Demo builds with `SWIFT_STRICT_CONCURRENCY = complete` (`project.pbxproj`).

**SwiftData models (unchanged):**
- `Device` — one row per unique discovered peripheral (keyed by `Peripheral.id`), upserted on each `discoveredPeripherals` tick.
- `DiscoveryEvent` — one row per raw advertisement (`peripheralDiscoveries` event).

**Out of scope:** library test-target background-actor smoke test (Step 5 / #19); Peripheral tab (no SwiftData).

## Approach

Introduce `DeviceStoreActor` — a `ModelActor` that owns every SwiftData write. `CentralView` creates it off the main thread, then runs three concurrent stream loops: state → `@MainActor` view-model; discoveries and peripheral list → store.

```
CentralView (@MainActor reads via @Query)
    │
    ├─ .task ──► DeviceStoreActor.create(container:)   [off-main creation]
    │                │
    │                ├─ insertDiscovery / syncDevices / delete* / clearAll
    │                └─ modelContext.save()
    │
    ├─ ReliaBLEManager.state ──────────► CentralViewModel.updateState (@MainActor)
    ├─ ReliaBLEManager.peripheralDiscoveries ──► store.insertDiscovery
    └─ ReliaBLEManager.discoveredPeripherals ──► store.syncDevices
```

**`DeviceStoreActor` design:**
- Manual `ModelActor` conformance (not the `@ModelActor` macro) with an explicit `init(modelContainer:)` and `nonisolated let modelExecutor` / `modelContainer` — the macro's synthesized initializer is not accessible from outside the type, which blocked environment-key and preview construction.
- `static nonisolated func create(container:) async -> DeviceStoreActor` — **critical**: SwiftData `ModelActor` inherits the thread of its creation context. Initializing on `@MainActor` (e.g. in `App.init` or a synchronous environment default) pins writes to the main thread despite the actor label. The factory must be called from a `nonisolated async` context so the actor actually runs in the background.
- Write methods: `insertDiscovery`, `syncDevices`, `clearAll`, `deleteDiscoveries(ids:)`, `deleteDevices(ids:)`. Swipe-delete passes `PersistentIdentifier` (Sendable) rather than `@Model` class instances.
- `#if DEBUG` `assert(!Thread.isMainThread)` in every write method — acceptance-criteria guard.
- File-level doc comment pointing consumers at this as the canonical off-main persistence pattern.

**`CentralView` pipeline:**
- One `.task` block: capture `let manager = reliaBLE` (avoids MainActor-isolated environment access inside `TaskGroup` children under strict concurrency), `await DeviceStoreActor.create(container: modelContext.container)`, wire `viewModel.setDependencies`, then `withTaskGroup` running three concurrent `for await` loops.
- `@Environment(\.modelContext)` retained **only** to reach `modelContext.container` for store creation; no direct writes through it.
- `@Query` unchanged for Devices / Discoveries lists.

**`CentralViewModel` slim-down:**
- Drop `modelContext` storage and all `@MainActor` persistence methods.
- Keep `@MainActor updateState` for `@Observable` UI properties.
- Keep fire-and-forget BLE actions (`authorizeBluetooth`, `startScanning`, `stopScanning`).
- `clearAllData` / delete helpers wrap `Task { await deviceStore?.… }`.

**Documentation:** inline comment in `DeviceStoreActor.swift` + update `Demo/AGENTS.md` concurrency / app-structure sections.

## Work Items

Demo-only; library untouched. Build via XcodeBuildMCP (workspace `ReliaBLE.xcworkspace`, scheme `ReliaBLE Demo`).

1. **`DeviceStoreActor.swift` — new file.** `actor DeviceStoreActor: ModelActor` under `Central/`. Move write logic from the old `CentralViewModel` persistence methods. Add `create(container:)` factory and debug thread asserts. PBXFileSystemSynchronizedRootGroup auto-includes the file. *(Build may fail until items 2–3 land.)*

2. **`CentralViewModel.swift` — slim down.** Remove `modelContext`, `insertDiscovery`, `syncDevices`. Change `setDependencies` to `(deviceStore:reliaBLE:)`. Route `clearAllData` / delete through `deviceStore` via `Task { await … }`. Keep `updateState` as the sole `@MainActor` handler.

3. **`CentralView.swift` — rewire pipeline.** Replace three separate `.task` loops + `onAppear` modelContext wiring with the single `.task` + `withTaskGroup` pattern. Swipe-delete passes `persistentModelID`. Capture `reliaBLE` into a local `manager` before spawning child tasks.

4. **`Demo/AGENTS.md` — document pattern.** Update App structure and Swift Concurrency sections: `DeviceStoreActor` owns writes; `CentralViewModel` owns UI state + BLE actions; `@Query` owns reads; store created via `create(container:)`.

5. **Verify.**
   - `ReliaBLE Demo` scheme builds clean under `SWIFT_STRICT_CONCURRENCY = complete` (zero warnings).
   - Debug asserts fire during scanning (writes off-main).
   - UX unchanged: Devices / Discoveries lists update live; Clear All and swipe-delete work.
   - No `@MainActor` annotation added to any library public type to make the Demo compile (regression guard).

## Decisions (resolved at implementation)

1. **Manual `ModelActor` conformance, not `@ModelActor` macro.** The macro synthesizes an initializer that is not constructible from `EnvironmentKey.defaultValue`, `ReliaBLE_DemoApp` property initializers, or `#Preview` — build error: *"'DeviceStoreActor' cannot be constructed because it has no accessible initializers."* Manual expansion (`modelExecutor` + `modelContainer` + `DefaultSerialModelExecutor`) matches the macro output and exposes a public `init(modelContainer:)`.

2. **No `@Environment(\.deviceStore)` injection.** App-level `var deviceStore = DeviceStoreActor(modelContainer: sharedModelContainer)` also fails: (a) `sharedModelContainer` is unavailable in a sibling property initializer, and (b) synchronous main-thread creation defeats the off-main goal. Store is created in `CentralView`'s `.task` via `create(container:)` instead.

3. **Single `.task` + `withTaskGroup` instead of three `.task` blocks.** Guarantees the store exists before stream loops start; runs state / discoveries / peripherals concurrently. Alternative (three independent `.task`s) risks racing on an uninitialized store.

4. **`let manager = reliaBLE` before `TaskGroup`.** `@Environment(\.bleManager)` is MainActor-isolated; child tasks in the group are not. Local capture of the `Sendable` manager avoids Swift 6 errors. Same pattern applies to any future environment-injected `Sendable` service.

5. **Deletes via `PersistentIdentifier`, not model instances.** `@Model` classes are not `Sendable`; passing them into `DeviceStoreActor` from `@MainActor` list handlers would violate strict concurrency. `persistentModelID` is `Sendable` and resolves back to the model inside the actor via `modelContext.model(for:)`.

6. **Docs split: inline comment + `Demo/AGENTS.md`.** Issue asked for README or inline comment; both inline (`DeviceStoreActor.swift` header) and agents doc update were chosen. No standalone `Demo/README.md`.

## Open Questions

None blocking. One item noted for future Demo work:
- **Fetch perf on `syncDevices`:** current implementation fetches all `Device` rows per `discoveredPeripherals` tick (inherited from pre-refactor code). Fine for a demo; a production app would index by `id` or maintain an in-actor lookup cache.

## References

- Issue #20; parent #10. Related library steps: #12 (AsyncStream), #18 (`Sendable` façade), #19 (strict-concurrency flag / DocC `Concurrency.md`).
- Audit preventive measure: `docs/investigations/swift6-concurrency-audit-2026-05-13.md` — Preventive Measures ("Cross-actor validation in the Demo"), Tracking table.
- SwiftData `ModelActor` creation-context behavior: [massicotte.org/model-actor](https://www.massicotte.org/model-actor/) (ModelActor inherits main-thread execution when created on MainActor).
- Key files: `Demo/ReliaBLE Demo/ReliaBLE Demo/Central/DeviceStoreActor.swift`, `CentralViewModel.swift`, `CentralView.swift`, `ReliaBLE_DemoApp.swift`, `Demo/AGENTS.md`.
- Library concurrency contract (unchanged): `Sources/ReliaBLE/Documentation.docc/Topics/Concurrency.md`.
- Prior step plans: `docs/plans/combine-to-asyncstream-2026-06-18.md` (Step 3 — Demo stream consumption), `docs/plans/manager-sendable-collapse-2026-06-23.md` (Step 4 — `Sendable` façade).