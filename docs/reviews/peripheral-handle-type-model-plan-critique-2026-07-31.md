# Critique — Phase 1 Public Type Model Plan (`Peripheral` handle + `DiscoveredPeripheral`)

**Subject:** `docs/plans/peripheral-handle-type-model-2026-07-31.md`
**Baseline:** `prompt-exports/oracle-plan-2026-07-31-121912-peripheral-handle-ty-892a.md`, "Generated Plan / Response" section only (from ~line 216).
**Date:** 2026-07-31

## Scope

Focused critique only. Covered: (A) implementation-bearing export content dropped or weakened in the plan; (B) under-specified seams, unresolved decisions, contradictions, bad references, missing dependencies; (C) claims the code disproves, work the task does not require, and places where a named simpler design fully replaces the proposal; (D) requirements/edge cases/architecture absent from **both** documents; (E) questions whose answers change the design or the implementation order.

**Not re-litigated (owner-decided):** one PR closing #50; `.macOS(.v15)` + `Synchronization.Mutex` + checked `Sendable`; `ReliaBLEManager.connect(to:)`/`disconnect(from:)` removed outright; Option A metadata as synchronous cached properties on the handle. Every finding below is compatible with those four decisions.

### Verification performed

- Read `BluetoothActor.swift` discovery (`handlePeripheralDiscovered`, :876–:954), restore (`handleWillRestoreState`, :709–:807), `invalidatePeripherals` (:956–:968), `refreshPeripherals` (:998–:1016), storage declarations (:180–:201).
- Read `ReliaBLEManager.swift` in full, `Models/Peripheral.swift` (:55–:116), and the test harness (`ReliaBLEManagerTests.swift` :55–:129, :320–:349, :432–:466, :1960–:2079, :2126–:2240) plus call-site greps.
- Compile-verified the `Mutex` + `weak var` + checked-`Sendable` question against Swift 6 language mode with `-strict-concurrency=complete` at `-target arm64-apple-macos15.0` (results in D9).
- Compile-verified the `self`-in-`init` ordering question with `-emit-sil` (definite-initialization diagnostics do not run under `-typecheck`) (result in D2).

---

## A. Export content missing, weakened, or over-generalized in the plan

### A1 — The export's explicit out-of-scope list was dropped · Medium

Export (Generated Plan, header): *"Out of scope: work-driven connect/idle teardown (#51), FR-10 GATT (#52), PoweredOn gating (#57), commands FR-4/5."*

The plan has no Out of Scope section. Two of those matter to this diff, not just to the roadmap:

- **#57 PoweredOn gating.** `Peripheral.connect()` is a *new public entry point*. Today `ReliaBLEManager.connect(to:)` calls `await bluetooth.ensureCentralManager()` and then throws `.bluetoothUnavailable` if the central is missing or `.notFound` if no live ref exists (`BluetoothActor.swift:1031-1050`). A reviewer of the new handle API will reasonably ask "does `connect()` await PoweredOn?" — the plan must say "no, unchanged from today, FR-1.4/FR-8.6/#57."
- **FR-10 attachment (D13)** is stated, but without the out-of-scope frame, D13's "reserve a home" reads as an invitation to add storage now.

**Correction:** restore the out-of-scope list verbatim into the plan, immediately after the Goal.

### A2 — The registry's manager reference was silently changed from per-call to stored-weak · High (this is what creates D2)

Export §4: `final class PeripheralHandleRegistry { func peripheral(id: String, manager: ReliaBLEManager) -> Peripheral }` — the manager is **passed at call time**, by `ReliaBLEManager.peripheral(id:)` which has `self` in hand.

Plan D6/D8/§Proposed signatures: `init(manager: ReliaBLEManager)` — *"holds weak manager inside `Mutex<Storage>`"*, and `Storage` *"carries `[String: Peripheral]` plus a `weak var manager`."*

The plan changed a load-bearing detail without noting it, and the changed form does not compile as written (see **D2**: `PeripheralHandleRegistry(manager: self)` cannot appear in `ReliaBLEManager.init` before `bluetooth` is initialized). The export's per-call form sidesteps the problem entirely and removes one of the three weak references in the design.

**Correction:** either adopt the export's per-call `manager:` parameter, or specify the two-phase attach in D2 below. Do not leave the plan's current wording.

### A3 — "Init is internal, callable only from the registry" is unenforceable · Low

Export D11 hedged: *"`Peripheral` init is `fileprivate`/`package` from registry only."* Plan D11 flattens this to "internal and is callable only from the registry," which `internal` does not enforce — anything in the module can construct a handle, including the actor, which is exactly the divergence hazard the registry exists to prevent.

**Correction:** either co-locate `Peripheral` and `PeripheralHandleRegistry` in one file and mark the init `fileprivate`, or keep `internal` and state plainly that the single-construction-site rule is a convention enforced by review, not by the compiler.

*(Content the plan legitimately hardened, listed so it is not "fixed" back: `@unchecked Sendable` → checked `Sendable` via `Mutex`; the export's `ManagerStamp` with a bare `weak var` → `Mutex`-boxed; the export's dithering about `preconditionFailure`/`fatalError` in `.peripheral` → "return an orphan handle"; the export's "DocC maybe incremental" → items 1+2 land together. All four are improvements.)*

---

## B. Under-specified seams, unresolved decisions, bad references, missing dependencies

### B1 — `resolveAndUpsertDiscovered` merge semantics: the two call sites are **not** identical, and the plan's signature loses the difference · High

Plan D9 claims *"Logic is identical to today"* and prescribes `(cbPeripheral:name:rssi:lastSeen:advertisement:emitDiscoveryEvent:)` with `rssi: Int?` and non-optional `advertisement`, restore passing *"an empty advertisement and nil rssi."*

The code disagrees. On the update branches, restore **preserves prior values**:

- `BluetoothActor.swift:742` — `rssi: discoveredPeripherals[idx].rssi` (keeps prior RSSI)
- `BluetoothActor.swift:744` / `:754` — `advertisement: discoveredPeripherals[idx].advertisement ?? emptyAdvertisement` (keeps prior advertisement)
- `BluetoothActor.swift:751` — `name: name ?? discoveredPeripherals[idx].name` (coalesces name; discovery at `:930` does **not**)

Implementing the plan's literal signature — restore passes `nil` rssi and a fresh empty `AdvertisementData` — **regresses restore**: a device discovered pre-termination and then restored would have its RSSI and last advertisement wiped from the snapshot list *and*, now, from the handle's Option A metadata. That is a user-visible behavior change smuggled in as a refactor, and it would not be caught by any existing test.

**Correction:** the helper needs explicit merge semantics, not a flag. Give it `rssi: Int?`, `advertisement: AdvertisementData?`, `name: String?` with a documented rule — *nil means "keep the existing value; fall back to empty/nil when there is none"* — and note that discovery always passes non-nil so the rule is a no-op there. Add a test asserting a restored, previously-discovered peripheral keeps its RSSI/advertisement.

### B2 — Who broadcasts the snapshot list is unspecified · Medium

Discovery broadcasts once per advertisement at the end of the handler (`:953`). Restore broadcasts **once after the loop**, guarded by `didMutatePeripherals` (`:804-806`), precisely to avoid N broadcasts for N restored peripherals. If the extracted helper broadcasts, restore regresses to one broadcast per restored peripheral (and each carries a partially-updated list).

**Correction:** state in D9 that the helper mutates and returns the resolved id only — it neither broadcasts nor emits; both callers keep their existing broadcast placement.

### B3 — `emitDiscoveryEvent` is a dead parameter · Medium

`PeripheralDiscoveryEvent` is broadcast at `BluetoothActor.swift:886-890`, **before** id resolution begins, from `cbPeripheral` + `advertisement` + `rssi` — data the helper does not need and a step restore never performs. A helper whose stated job is *"resolves the app-facing id, upserts the discovered snapshot list, and returns the resolved id"* has nothing to gate on this flag.

**Correction:** drop `emitDiscoveryEvent` from the signature. The "restored peripherals never hit the ad feed" invariant is preserved for free by leaving the broadcast at the discovery call site.

### B4 — A third live-reference binding site is unaccounted for · Medium

`refreshPeripherals()` (`BluetoothActor.swift:998-1016`) re-binds `cbPeripherals[p.id]` from `centralManager.retrievePeripherals(withIdentifiers:)` after a power cycle and broadcasts the list. Neither document mentions it. It does not resolve new ids or change metadata, so it likely needs **no** bridge call — but the plan's claim of a *"single id-resolution site"* (D8 diagram) is false until this is addressed, and an implementer scanning for `discoveredPeripherals` mutation sites will hit it and have to guess.

**Correction:** name it in D9 with an explicit "no bridge call needed — no metadata change, no new id" note.

### B5 — Nothing says how `BluetoothActor` obtains the `ManagerStamp` · High (missing dependency)

D7 puts `let stamp: ManagerStamp` inside `DiscoveredPeripheral`, and D8/D9 make the **actor** the site that constructs `DiscoveredPeripheral` values. But D6 adds only `registry:` to `BluetoothActor.init(log:reconnectPolicy:restoreIdentifier:)`. The actor therefore cannot construct a stamped snapshot. The plan is not implementable as written.

**Correction:** either inject the stamp alongside the bridge, or adopt **C4** (drop `ManagerStamp`; have `DiscoveredPeripheral` hold the registry reference), which removes the dependency instead of adding a fourth init parameter.

### B6 — The apply-before-broadcast ordering invariant is implied but never stated · Medium

The whole point of pushing metadata into handles from the actor is that a consumer who receives snapshot *N* never observes handle metadata **older** than *N*. That holds only if `registry.applyDiscovery(...)` runs before `broadcast(list, to: peripheralsContinuations)`. The plan's data-flow section happens to show that order; nothing states it as a requirement, so a later reordering (e.g. "broadcast early to cut latency") would silently break it.

**Correction:** state it as an invariant in the Concurrency section and cover it with a test (see D8c).

### B7 — Two locks now exist and no lock order is specified · Medium

After this change the library holds a registry `Mutex` and a per-handle `Mutex`. The natural implementation of `applyDiscovery` takes the registry lock, finds the handle, then takes the handle lock — nested. Nothing in the plan forbids the reverse order, and a future `handle.connect()` that consults the registry would create one.

**Correction:** state the rule — *registry lock → handle lock, never the reverse; no user code and no CoreBluetooth call runs under either lock* — or, better, have `applyDiscovery` copy the handle reference out under the registry lock, **release**, then call `handle.applyMetadata(...)`, so the locks never nest at all.

### B8 — Citation drift · Low (individually), Medium (in aggregate — the file is the implementer's map)

| Plan says | Actual |
|---|---|
| `discoveredPeripherals: [Peripheral]` (~:212) | `BluetoothActor.swift:180` |
| `cbPeripherals` (~:220) | `BluetoothActor.swift:186` |
| `Peripheral.swift:109-115` (plan line 13) **and** `Peripheral.swift:107-113` (D1) — contradictory | `hash(into:)` :107-109, `==` :111-115 |
| connect sites ":577, :606, :644, :686, :730, :792, :870, :923, :980, :1032, :1096" | 585, 614, 661, 694, 738, 804, 878, 935, 990, 1043, 1104 — every entry 8–10 lines low |
| "~50 direct `Peripheral` references plus ~30 discovery/connect/connection-state sites" | `connect(to:)`/`disconnect(from:)` alone occupy **36** lines, and the plan's list omits `:1455, :1550, :1596, :1655, :1808` (restoration + multi-manager tests) entirely |
| `handlePeripheralDiscovered` (:876), `id(for:)` (~:1099), delegate shims (:1486, :1540), `waitForPeripheral` (:2170), stale-connect (:450-458), Demo `:55/:68/:282/:286` | all correct |

**Correction:** re-derive the test line numbers (or drop them in favour of the symbol names, which do not rot) and fix the two actor storage refs and the self-contradictory `Peripheral.swift` span.

---

## C. Corrections — disproved by the code, not required, or replaced by a simpler design

### C1 — `ensureCentralManagerReady()` on the manager is unnecessary, and its stated rationale is wrong · Medium

D3: *"The handle lives in the same module, so `bluetooth` stays internal — expose a small internal helper on the manager rather than widening access."*

`bluetooth` is **already** `internal let` (`ReliaBLEManager.swift:42`), and `ensureCentralManager()` is already reachable as `await manager.bluetooth.ensureCentralManager()` — the exact call `connect(to:)` makes today (`ReliaBLEManager.swift:189`). Nothing needs widening, so the helper prevents nothing.

**Correction:** delete the "widening access" justification. Keep the helper only if you want a single named seam for handles to call (a legitimate but different reason), and say so; otherwise have the handle call `manager.bluetooth` directly and drop `ensureCentralManagerReady()` from the API table.

### C2 — Renaming the actor's `discoveredPeripherals` to `discoveredSnapshots` is unrequested churn · Low

The element type must change; the property name need not. The rename breaks two `@testable` accesses (`ReliaBLEManagerTests.swift:1500`, `:1783`) and four internal DocC links (`BluetoothActor.swift`: `discoveredPeripheralsStream()`, `invalidatePeripherals()`, `cbPeripherals` comment neighbourhood), for zero functional gain, inside an already-large commit whose review budget is the scarce resource.

**Correction:** keep the property name `discoveredPeripherals`; change only its element type. If the rename is wanted for clarity, make it a separate trailing commit.

### C3 — Collapse `ensureHandle(id:)` + `applyDiscovery(...)` into one call · Medium

`PeripheralRegistryBridge` has two methods that are always invoked back-to-back (plan D6, State-and-data-flow). `applyDiscovery` must intern anyway (the handle may not exist), so `ensureHandle` is redundant — it doubles lock acquisitions on the hottest path in the library (one advertisement per device per interval; the mock alone advertises at 50 ms across two peripherals, `ReliaBLEManagerTests.swift:2138`, `:2156`).

**Correction:** one protocol method, `applyDiscovery(id:cbIdentifier:name:rssi:lastSeen:advertisement:)`, documented as create-or-update. This also removes the only reason the bridge protocol has two ordering-sensitive members.

### C4 — `ManagerStamp` is fully replaced by holding the registry in `DiscoveredPeripheral` · Medium–High

D7 introduces `ManagerStamp` (a `Mutex`-boxed weak manager) purely so `.peripheral` can find the interning registry. But the registry *is* the thing being looked up, it is already per-manager, and it is already `Sendable`:

```swift
public struct DiscoveredPeripheral: Sendable, Identifiable, Hashable {
    // …public lets…
    let registry: PeripheralHandleRegistry     // internal, excluded from ==/hash
    public var peripheral: Peripheral { registry.peripheral(id: id) }
}
```

This is strictly better on four counts:

1. **Deletes a type** and the third weak reference in the design.
2. **Removes B5** — the actor already receives the registry/bridge; nothing extra to inject.
3. **Removes the "manager freed → detached orphan" special case.** With a stamp, `.peripheral` after manager death returns a *fresh* orphan each call, so `snap.peripheral === snap.peripheral` is false — quietly violating the plan's headline interning invariant in exactly the state it is hardest to debug. With the registry held, interning survives manager death; the handle's own weak manager is nil, so `connect()` still throws `.bluetoothUnavailable` — same documented behavior, no new object identity rule.
4. **Retain graph stays acyclic:** manager → registry (strong), registry → handles (strong), handle → manager (weak), snapshot → registry (strong). The only consequence is that a retained snapshot keeps the registry alive after the manager dies, which is precisely what makes point 3 work.

**Correction:** replace D7's `ManagerStamp` with the registry reference, or explicitly justify keeping the stamp and then answer point 3 (define `.peripheral`'s identity contract after manager deallocation).

### C5 — The rewritten equality test proves nothing · Medium

Verification table: *"Equality/hash tests (:110-126) — Two `manager.peripheral(id:)` for the same id → `===` **and** `==`."*

Under interning those two calls return the **same object**, so `==` is satisfied by any implementation, including a default identity-based one. The id-only equality contract (D1: *"two handles from different managers with the same id compare `==` but are different objects"*) can only be exercised with **two distinct objects sharing an id**, which by construction requires two managers.

**Correction:** keep the same-manager test as an interning assertion (`===`), and move the real `==` assertion into `twoManagersIndependentHandleRegistries`: `a.peripheral(id: "x") !== b.peripheral(id: "x")` **and** `a.peripheral(id: "x") == b.peripheral(id: "x")`, plus the `Set` count check there.

### C6 — Tightening the unknown-peripheral connect test to `.notFound` will flake · Medium

The plan's rewrite row and new test #4 both demand `.notFound`. The existing test (`ReliaBLEManagerTests.swift:448-462`) deliberately accepts `.notFound || .bluetoothUnavailable`, with a comment explaining why: `makeManager()` does **not** bring the central online (authorization is pinned `.notDetermined`, `SimulationConfig`, `:2049`), and `ReliaBLEManager.init`'s fire-and-forget `Task { await bluetooth.ensureCentralManager() }` (`ReliaBLEManager.swift:70-72`) may or may not have produced a central by the time the assertion runs.

**Correction:** if the plan wants a deterministic `.notFound`, the test must call `await Mock.ensureReady(manager)` first (which the current test does not). State that in the plan; otherwise keep the either-or assertion.

---

## D. Absent from both the export and the plan

### D1 — Option A metadata has no change notification, so the "my devices" UI it exists for cannot update · High (architectural)

`Peripheral` is a plain `Sendable` class. It is not `@Observable`, publishes no `objectWillChange`, and the plan defers both a metadata-change `AsyncStream` and design Option B (D2, D4). SwiftUI therefore has **no signal** that `rssi`/`lastSeen`/`advertisement` changed: a `ForEach` over tracked handles renders once and then shows stale values until some unrelated state change forces a re-render.

This is not the sync-vs-async question (owner-decided; sync is right and is a precondition for any fix). It is the missing half: the "Nearby" screen re-renders because `discoveredPeripherals` vends fresh **value** snapshots, whereas the "my devices" screen — the sole justification for Option A, and FR-2.4.5 — is handed a mutable reference with no invalidation channel. Shipping DocC that teaches "bind your my-devices list to handle metadata" (plan, DocC checklist for `GettingStarted.md`) teaches a pattern that visibly does not update.

**Correction, zero API cost:** document that `discoveredPeripherals` doubles as the "something changed" tick — it fires on every advertisement, and an app can re-read handle metadata inside that loop. That is honest, requires no new API, and keeps Option B deferred. Add it to D2 and to the `GettingStarted.md` checklist item. If that is judged insufficient, the alternative is scoping a minimal notification now (see **E1**) — but the plan must not stay silent.

### D2 — `PeripheralHandleRegistry(manager: self)` in `ReliaBLEManager.init` does not compile · High (blocks implementation)

Verified with `swiftc -swift-version 6 -emit-sil` (this diagnostic is a SIL pass — `-typecheck` alone reports nothing):

```
error: 'self' used before all stored properties are initialized
note: 'self.registry' not initialized
```

`self` is unusable in a class initializer until **every** stored property is assigned. The plan requires `registry` (needing `self`) to exist *before* `bluetooth` (needing `registry`) — an unsatisfiable order.

**Correction (two-phase attach), the minimal fix:**

```swift
public init(config: ReliaBLEConfig = ReliaBLEConfig()) {
    loggingService = LoggingService(...)
    handleRegistry = PeripheralHandleRegistry()          // no manager yet
    bluetooth = BluetoothActor(log:..., reconnectPolicy:..., restoreIdentifier:...,
                               registry: handleRegistry)
    handleRegistry.attach(manager: self)                 // legal: all stored props initialized
    Task { await bluetooth.ensureCentralManager() }
}
```

Then state the consequence the plan must not leave implicit: handles capture their `weak manager` **at creation from the registry's stored reference**, so nothing may call `peripheral(id:)` before `attach` (nothing does — but say so). The alternative is A2's per-call `manager:` parameter, which needs no attach step at all.

### D3 — The retain-graph rule omits the actor → bridge edge, where the only real leak lives · High

Plan Concurrency: *"manager → registry (strong) → handle (strong) → manager (weak)."* Missing: **manager → actor → bridge → ?**. The actor stores `let registry: PeripheralRegistryBridge` (D6), so if the bridge captures the manager **strongly**, the cycle is manager → actor → bridge → manager and the manager never deallocates. Worse, the plan itself notes that *live stream subscribers retain the actor* (`ReliaBLEManager.swift:40-45`), so a single un-terminated `for await` would pin the manager, its central, and every handle for the process lifetime — and the entire "handles orphan when the manager dies, `connect()` throws `.bluetoothUnavailable`" contract (D1, D7, edge-case table) would never be reachable, in production or in tests.

**Correction:** extend the rule to actor → bridge → **registry (strong)** → manager (**weak**), and state explicitly that **no** object reachable from the actor may hold the manager strongly. If the registry conforms to `PeripheralRegistryBridge` directly (see below) this is automatic — a further argument for dropping the separate adapter object. Add a teardown test: create a manager in a scope, take a handle, drop the manager, assert `handle.connect()` throws `.bluetoothUnavailable`. That test is the leak detector.

*(Related simplification: the plan lists both `PeripheralHandleRegistry` and "an adapter conforming to `PeripheralRegistryBridge`". The registry can conform to the protocol itself — keep the protocol for the actor's dependency inversion and testability, drop the separate adapter type.)*

### D4 — Nothing ever evicts handles; the registry grows without bound and survives `shutdown()` · High

`[String: Peripheral]` with strong values, keyed by the resolved id, populated on **every** discovery, with no removal path anywhere in the plan. Each handle retains a full `AdvertisementData` — `manufacturerData: Data`, `serviceData: [CBUUID: Data]`, three UUID arrays (`AdvertisementData.swift`).

The relevant comparison is not "today has no registry" but **what today already clears**:

- `shutdown()` clears both the snapshot list and the live map (`BluetoothActor.swift:257-259`).
- `invalidatePeripherals()` clears `cbPeripherals` and connection state (`:956-968`).

The plan's edge-case table says `invalidatePeripherals` *"keeps handles and their last-known metadata"* — correct and intentional (the handle must survive a radio reset). But it never says what `shutdown()` does to the registry, and by omission the answer is "nothing." So a long-running background scanner in a crowded environment (each distinct advertised name, and each nameless device's UUID string, mints a permanent handle) accumulates handles + advertisement payloads for the process lifetime, and tearing the stack down does not reclaim them. For a library whose headline feature is continuous background scanning, this is a genuine leak class, not a theoretical one.

**Correction — pick one and write it down:**

1. **Clear the registry in `shutdown()`.** Cheap, matches the actor's existing behavior, and harms nothing: handles the app still holds keep working (orphaned, throwing) and the stack is dead anyway. This should be the default even if you also do (2) or (3).
2. **Weak-value storage** (`[String: WeakBox<Peripheral>]` with prune-on-insert). Interning identity then holds exactly as long as the app holds a reference — which is the only window in which `===` is observable. Cost: a handle re-created after eviction starts with empty metadata unless you keep a small id→metadata side cache; and `discoveredPeripheralSugarReturnsInternedHandle` must hold its references across the assertion (it does).
3. **Accept and document** the growth explicitly, with a note that FR-8.5/#51 revisit it.

Whatever is chosen, add a line to the edge-case table for `shutdown()` — it currently only covers `invalidatePeripherals`.

### D5 — The re-entrancy contract points at the wrong hazard · Medium

Plan D6/Concurrency: *"Implementations may take a lock and mutate handles, but must not call back into the actor."* Because the protocol methods are **synchronous and non-throwing** and are called from actor-isolated code, calling back into the actor is *structurally impossible* — it would require `await`, which cannot appear in a sync function. The stated rule is therefore already enforced by the compiler, while the hazards that are actually reachable go unmentioned:

1. **`Task { await actor… }` inside a bridge call** — permitted, and it reorders arbitrarily relative to the discovery stream. This is the real "must not."
2. **Blocking under the lock** — the actor's executor thread stalls behind whoever holds the registry lock. Fine for dictionary ops; not fine if a future notification hook invokes app code under the lock (the natural place someone will add D1's observability).
3. **Nested lock order** (B7).

Similarly, *"`Mutex.withLock` is non-async and will not compile with an `await` inside, which enforces this structurally"* is true for `await` but not for `Task { }`, which compiles fine inside the closure.

**Correction:** restate the contract as: bridge implementations must be non-blocking and allocation-light; must not spawn tasks that touch the actor; must not invoke app-supplied callbacks; must observe registry-before-handle lock order. Note that direct actor re-entry is already impossible by signature.

### D6 — Multi-property reads are not atomic · Low–Medium

Five getters, five independent lock acquisitions. A row that reads `name`, then `rssi`, then `lastSeen` can straddle two discovery updates and render a mix. Benign for UI, but it is a public API contract that should be stated — and it is cheap to avoid.

**Correction:** store one immutable metadata struct inside the `Mutex` and expose the five properties as computed reads over a single `withLock` snapshot, or document "each property is individually consistent; reads of different properties are not a single atomic snapshot."

### D7 — Restore stamps `lastSeen = now` for a device that was not seen · Low–Medium

`BluetoothActor.swift:744-766` sets `lastSeen: now` for every restored peripheral. Harmless today (a snapshot-list field), but Option A promotes `lastSeen` to a public "my devices" field where it will be rendered as "Last seen: just now" for a device that has not advertised since before the app was killed.

**Correction:** decide explicitly in D9 — either preserve the prior `lastSeen` on restore (nil for never-discovered), or keep `now` and document `lastSeen` as "last bound or seen." Either way it belongs in the plan, because the split is what makes it visible.

### D8 — Testability gaps under the CoreBluetoothMock harness

The harness supports what the plan needs — ids are deterministic (`Mock.testPeripheralID = "ReliaBLE-Test-Peripheral"`, `:1964`; `connectionTestPeripheralID`, `:1969`), two simultaneous managers are supported (`makeManager(tearDownPrevious: false)`, `:2072`+ and the existing multi-manager test at `:1808`), and the restore path is directly drivable (`bluetooth.testHandleWillRestoreState`, used at `:1628, :1679, :1704, :1745`). Three gaps remain:

**(a) No test for restore-path interning**, despite it being a stated invariant (plan Background: *"restoration must intern the same handles"*; D9). The `testHandleWillRestoreState` hook makes this cheap: pre-create `manager.peripheral(id:)`, drive restore, assert the same instance received `cbIdentifier`, and assert `testContainsCBPeripheral`. Given B1, also assert prior RSSI/advertisement survived. **Add it to the new-test list.**

**(b) No test for the apply-before-broadcast ordering of B6.** Feasible: subscribe to `discoveredPeripherals`, and on the first element containing the test id, immediately assert `manager.peripheral(id: testId).rssi != nil` — no polling, which is what makes it a real ordering assertion.

**(c) `waitForPeripheral` returning a handle silently repoints existing assertions.** Today it returns the snapshot the stream emitted, and callers assert on it: `#expect(peripheral?.advertisement?.localName == …)`, `#expect(peripheral?.cbIdentifier != nil)` (`:336-338`). After the change those read **handle** metadata, i.e. whatever the latest discovery wrote — the assertions still pass, but they no longer test the snapshot that was actually emitted, which is what "the discovery pipeline populates the list" tests are for.

**Correction:** keep a `waitForDiscovered(id:) -> DiscoveredPeripheral?` and derive the handle at the connect call sites (`try await discovered.peripheral.connect()`), or add the handle-returning variant alongside rather than replacing. Preserve at least one assertion against snapshot fields.

### D9 — `Mutex` + `weak var` + checked `Sendable`: verified, with three caveats worth writing down · Informational (claim confirmed)

Compiled successfully under `-swift-version 6 -strict-concurrency=complete -target arm64-apple-macos15.0` (Swift 6.3 locally; CI is Xcode 16.4 / Swift 6.1 on `macos-15`, `ci.yml:19,44`): a `final class … : Sendable` holding `private let state: Mutex<State>` where `State` contains `weak var manager: ReliaBLEManager?` plus the five metadata fields; property getters via `withLock`; a registry whose `withLock` closure creates, inserts, and **returns** a handle; and `Task.detached` capture of both. No errors, no `@unchecked`. The plan's D0/D1 claim holds.

Caveats the plan should absorb:

1. **The premise is stronger than stated.** `Mutex` is *unconditionally* `Sendable` — SE-0433 achieves safety through `sending` on `init` and `withLock` rather than by requiring `Value: Sendable`. Verified: a `Mutex` over a struct containing a non-`Sendable` class compiles inside a checked-`Sendable` class. The practical constraint is on the **result**: `withLock` returns `sending Result`, so only `Sendable` (or provably-isolated) values can escape the closure. Every Option A field is `Sendable` (`String`, `Int`, `Date`, `UUID`, `AdvertisementData`), and `ReliaBLEManager` is `Sendable`, so all planned reads are legal. Say this, because it is the rule that governs any future field added to `State`.
2. **`weak` is sound here for a specific reason** worth recording: all reads and writes of the weak reference happen under the mutex, and the Swift runtime's weak load/zeroing is itself atomic with respect to deallocation. A `weak var` in a `Mutex`-guarded struct is safe; a `weak var` as a bare stored property of an `@unchecked Sendable` class (the export's `ManagerStamp`) is not. The plan already made this upgrade — keep the reasoning in the doc.
3. **Platform floor mechanics.** `Synchronization` requires macOS 15 / iOS 18 at runtime; CI's `macos-15` runner satisfies it, and D0 removes the need for `@available`. Two consequences the plan should mention: contributors on macOS 14 can no longer build or run the library's tests locally, and `Package.swift` declares only `.iOS`/`.macOS` — any consumer building for tvOS/watchOS/visionOS gets the SPM default floor and will fail on `import Synchronization`. Add the platforms or state iOS/macOS-only support.

### D10 — Connection state is the one thing a "handle-centric" API still cannot answer synchronously · Medium

D10 keeps `ConnectionStateChange.peripheralId: String` and defers per-handle streams — reasonable for a *stream*. But the result is that the my-devices row this whole phase is built for can read `rssi`/`lastSeen`/`advertisement` off the handle and must then join a String-keyed stream (or `await manager.currentConnectionStates`) to answer "is it connected?" — the single most important field on that row. Note also that the plan cites FR-2.1/2.4/2.5/8.2.1/NFR-1.2/1.3 but never **FR-2.3.1**, which says connection-state consumption should *"migrate to `Peripheral` as the handle model lands."*

The bridge, the lock, and the actor-ordered write path all already exist in this design; mirroring `connectionStates[id]` into a cached `peripheral.connectionState` is the same mechanism applied to a second field, and doing it now avoids reopening the identical seam in a later PR.

**Correction:** make this an explicit decision in D10 — either in scope (one extra bridge method, one cached property, mirroring the existing `connectionStates` writes) or explicitly deferred **with FR-2.3.1 cited**. Silence is the wrong answer either way.

---

## E. Questions that would materially change the design or implementation order

1. **Does Phase 1 owe SwiftUI a change signal for handle metadata (D1)?** If the documentation-only answer ("re-read inside the `discoveredPeripherals` loop") is acceptable, the plan is unchanged and only DocC grows. If not, a notification mechanism enters scope and should be designed together with D10's connection state — which changes work item 1 and the bridge protocol.
2. **Strong or evicting registry (D4)?** Strong + clear-on-`shutdown()` is a two-line addition. Weak values change `PeripheralHandleRegistry`'s type, add a metadata side-cache question, and add a test. Decide before writing the registry, not after.
3. **Does `peripheral.connectionState` ship now (D10)?** Answering "yes" means one bridge pass instead of two, and it changes the new-test list.
4. **`ManagerStamp` or registry reference in `DiscoveredPeripheral` (C4)?** Determines whether `BluetoothActor.init` gains one parameter or two (B5), and defines `.peripheral`'s identity contract after manager deallocation.
5. **Which registry/manager wiring (A2 + D2)** — per-call `manager:` parameter, or stored weak manager with a two-phase `attach`? This is the first line of code in work item 1.
6. **Does `handle.connect()` gate on PoweredOn, or preserve today's ensure-then-throw (A1/#57)?** Affects the error contract in the edge-case table and the strictness of new test #4.
7. **Keep or rename the actor's `discoveredPeripherals` (C2)?** Determines whether two `@testable` accessors and four DocC links move inside the already-large commit.

---

## Suggested minimal edits to the plan

Ordered by cost of getting it wrong, not by size:

1. **D6/§Proposed signatures** — fix the registry construction seam (A2/D2): per-call `manager:` **or** two-phase `attach(manager:)`, spelled out in code.
2. **Concurrency section** — complete the retain graph with actor → bridge → registry → weak manager, and add the "nothing reachable from the actor holds the manager strongly" rule plus the orphan-handle teardown test (D3).
3. **D9** — replace "logic is identical to today" with explicit merge semantics (B1), drop `emitDiscoveryEvent` (B3), state that the helper does not broadcast (B2), and mention `refreshPeripherals` (B4).
4. **D4/edge-case table** — decide and record the registry's growth/eviction policy and `shutdown()` behavior (D4).
5. **D2** — add the observability paragraph (D1) and, if kept, the non-atomic-multi-read note (D6).
6. **D7** — drop `ManagerStamp` for the registry reference, or answer the post-deallocation identity contract (C4/B5).
7. **D10** — decide connection-state placement, citing FR-2.3.1 (D10).
8. **D1/D3** — delete the "widening access" rationale (C1); add the `Mutex` `sending`-result rule and the platform-floor consequences (D9).
9. **Verification section** — fix the equality test (C5), add `ensureReady` to the `.notFound` test (C6), add restore-interning and ordering tests (D8a/b), keep a snapshot-returning wait helper (D8c).
10. **Background/blast radius** — correct the line citations and the call-site count (B8); restore the out-of-scope list (A1).
