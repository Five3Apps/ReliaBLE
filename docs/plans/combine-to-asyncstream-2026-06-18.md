# Combine → AsyncStream Broadcaster: Plan (Step 3 of 5)
*Issue #12 · 2026-06-18*

## Goal

Replace the three `AnyPublisher` event surfaces on `ReliaBLEManager` — `state`, `peripheralDiscoveries`, `discoveredPeripherals` — with per-subscription `AsyncStream`s fed by an in-`BluetoothActor` broadcaster, and remove `Combine` from `Sources/ReliaBLE` and `Sources/ReliaBLEMock` entirely. Update the Demo's `CentralViewModel` to consume via `.task { for await … }`. Fixes **Cluster 2** of the Swift 6 concurrency audit (non-`Sendable` Combine types in the public API).

This is **Step 3 of 5**. Steps 1 (#13, `@globalActor BluetoothActor`) and 2 (#17, `Peripheral` Sendable struct) are merged. Step 4 (#18) makes `ReliaBLEManager` `Sendable` and collapses `BluetoothManager`; Step 5 is logging/strict-concurrency/DocC polish.

## Background

All current state verified at the file:line refs below.

**Public surface (`ReliaBLEManager.swift`)** — three computed properties forward to `BluetoothManager`:
- `state: AnyPublisher<BluetoothState, Never>` (:55)
- `peripheralDiscoveries: AnyPublisher<PeripheralDiscoveryEvent, Never>` (:80)
- `discoveredPeripherals: AnyPublisher<[Peripheral], Never>` (:85)
- `currentState: BluetoothState` (:60) — **synchronous** accessor, *not* a Combine surface (see Open Questions).
- `import Combine` (:27).

**Forwarding layer (`BluetoothManager.swift`)** — thin computed getters onto the actor's bridging props:
- `state` → `BluetoothActor.shared.statePublisher` (:72)
- `currentState` → `BluetoothActor.shared.currentBluetoothState` (:79)
- `peripheralDiscoveries` → `discoveryPublisher` (:98), `discoveredPeripherals` → `discoveredPeripheralsPublisher` (:103)
- `import Combine` (:27). `BluetoothState: Sendable` enum (:147).

**Actor internals (`BluetoothActor.swift`)** — all Combine state is actor-owned, bridged out via `nonisolated(unsafe)`:
- Subjects (:83–85): `stateSubject = CurrentValueSubject(.unknown)`, `discoverySubject = PassthroughSubject`, `discoveredPeripheralsSubject = PassthroughSubject`.
- `nonisolated(unsafe) let` publishers (:96, :99, :102) + `nonisolated(unsafe) var currentBluetoothState = .unknown` (:108).
- `init()` erases subjects → publishers (:113–115).
- `.send(...)` sites: `broadcastState` (:244, also writes `currentBluetoothState` :248), `handlePeripheralDiscovered` (discovery event :287; list :336), `invalidatePeripherals` (:341), `refreshPeripherals` (:359).
- `import Combine` (:27).
- The actor already holds `discoveredPeripherals: [Peripheral]` (the list-replay source) and `cbPeripherals` registry — both stay.

**Cleanup markers** — 7 `// TODO: removed in Step 3` sites: `BluetoothActor.swift` (:95, :98, :101, :107, :247) and `BluetoothManager.swift` (:71, :77).

**Element types are already `Sendable`** (Step 2): `Peripheral` (struct), `PeripheralDiscoveryEvent` (struct), `BluetoothState` (enum). No element-type work needed.

**Stays in place (do NOT remove):** `SendableWrapper<T>: @unchecked Sendable` (`BluetoothActor.swift:30`) — it hops the non-`Sendable` `CBPeripheral` + `[String: Any]` from the delegate queue into the actor. It is **not** a Combine workaround (no Step-3 TODO marker) and was deliberately retained in Step 2.

**Demo consumption (`Demo/ReliaBLE Demo/.../Central/`)** — single consumer, `CentralViewModel.setupSubscriptions()`:
- `@Observable class CentralViewModel` (CentralViewModel.swift:38) — not `@MainActor`, not `ObservableObject`. `var cancellables = Set<AnyCancellable>()` (:42), `var currentState` (:39).
- `state` → `.receive(on: .main).assign(to: \.currentState)` (:53–57).
- `peripheralDiscoveries` → `.sink { insert DiscoveryEvent into SwiftData }` (:59–68).
- `discoveredPeripherals` → `.sink { sync Device SwiftData models }` (:70–89).
- `import Combine` at CentralViewModel.swift:27 and CentralView.swift:27.
- Wiring: `.onAppear { setDependencies(...) }` → `setupSubscriptions()` (CentralView.swift:142); teardown `.onDisappear { cancellables.removeAll() }` (:144).

**Tests** — `Tests/ReliaBLETests/ReliaBLEManagerTests.swift` has **zero** references to Combine or the three surfaces; the migration breaks no existing test.

## Approach

The broadcaster lives entirely inside `BluetoothActor`. Three `[UUID: AsyncStream<T>.Continuation]` dictionaries replace the three Combine subjects; three `nonisolated` factory methods mint a fresh stream per call; the existing broadcast paths `.yield(...)` into the continuations instead of `subject.send(...)`.

**Broadcaster state** (replaces the subjects + erased publishers):
```swift
private var stateContinuations: [UUID: AsyncStream<BluetoothState>.Continuation] = [:]
private var discoveryContinuations: [UUID: AsyncStream<PeripheralDiscoveryEvent>.Continuation] = [:]
private var peripheralsContinuations: [UUID: AsyncStream<[Peripheral]>.Continuation] = [:]
// kept: nonisolated(unsafe) var currentBluetoothState — replay source + sync `currentState` backing
```

**Stream factories** (internal `nonisolated`, called by the façade):
```swift
nonisolated func stateStream() -> AsyncStream<BluetoothState> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let id = UUID()
        Task { @BluetoothActor in
            continuation.yield(currentBluetoothState)        // replay (state only)
            stateContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @BluetoothActor in stateContinuations[id] = nil }
            }
        }
    }
}
```
`discoveredPeripheralsStream()` is identical but replays the current `discoveredPeripherals` array (also `.bufferingNewest(1)`). `peripheralDiscoveriesStream()` omits the replay yield and uses the default unbounded buffer (BLE ad rate is low; switch to `.bufferingNewest(n)` only if back-pressure is ever observed).

**Atomicity / ordering:** the factory's `Task { @BluetoothActor in … }` body has no `await`, so the replay-yield, registration, and `onTermination` assignment run as one indivisible actor job — they cannot interleave with `broadcastState`. The only residual gap is the window between `AsyncStream` creation and that job starting: an event emitted then is missed by a *new* `peripheralDiscoveries` subscriber (no replay). Accepted for a lightweight advertisements feed; documented, not engineered around.

**Broadcast sites** (5 `.send` → yields): `broadcastState` loops `stateContinuations` (and still writes `currentBluetoothState`); `handlePeripheralDiscovered` yields the event to `discoveryContinuations` and the updated array to `peripheralsContinuations`; `invalidatePeripherals` / `refreshPeripherals` yield the array to `peripheralsContinuations`. A small private `broadcast(_:to:)` helper keeps the loops DRY — it just iterates `.values` and yields; it never prunes. Dead continuations are removed by their own `onTermination` (a fire-and-forget actor hop, which is safe because yielding to an already-finished continuation is a harmless no-op).

**Façade:** `BluetoothManager` and `ReliaBLEManager` swap each `AnyPublisher<X, Never>` property for `AsyncStream<X>`, delegating to the actor factory (`BluetoothActor.shared.stateStream()`, etc.). `currentState` and its `nonisolated(unsafe)` snapshot are untouched. `import Combine` leaves all three files.

**Demo:** `CentralView` replaces the `.onAppear`-installs-sinks / `.onDisappear`-clears-cancellables pattern with three `.task { for await v in reliaBLE.<surface> { … } }` blocks (SwiftUI cancels them on disappear). Each loop body hops to the main actor (`await MainActor.run { … }` or an `@MainActor` VM handler) before touching `@Observable` state or SwiftData. `CentralViewModel` drops `import Combine`, `cancellables`, and `setupSubscriptions()`, keeping the conversion logic in handler methods.

## Work Items

Edit the library inside-out so the build stays green; the three library files (1–3) must land together if any intermediate build is required.

1. **`BluetoothActor.swift` — broadcaster core.** Drop `import Combine`, the three subjects (:83–85), the three `nonisolated(unsafe) let …Publisher` (:96–102), and the `init` erasure (:113–115). Add the three continuation dictionaries + three `nonisolated` stream factories. Rewrite the 5 yield sites (`broadcastState` :244, `handlePeripheralDiscovered` :287/:336, `invalidatePeripherals` :341, `refreshPeripherals` :359). **Keep** `currentBluetoothState` (reword its TODO :107 → “retained for sync `currentState` + `stateStream()` replay”), `SendableWrapper` (:30), `forceMock`, and lazy-init.
2. **`BluetoothManager.swift` — façade.** Drop `import Combine`; retype `state` / `peripheralDiscoveries` / `discoveredPeripherals` (:72/:98/:103) to `AsyncStream<…>` delegating to the actor factories; reword/remove the Step-3 TODOs (:71, :77). Leave `currentState` (:79) and the `BluetoothState` enum (:147) unchanged.
3. **`ReliaBLEManager.swift` — public surface.** Drop `import Combine` (:27); retype the three properties (:55/:80/:85) to `AsyncStream<…>`; refresh the doc comments (s/Publisher/stream). Leave `currentState` (:60) unchanged. *(Breaking API change — intentional, pre-1.0.)*
4. **Demo — `CentralViewModel.swift` + `CentralView.swift`.** Remove `import Combine`, `cancellables`, and `setupSubscriptions()`; move the existing SwiftData/assignment logic into `@MainActor` handler methods (`updateState`, `insertDiscovery`, `syncDevices`). In `CentralView`, replace the onAppear/onDisappear wiring with three `.task` loops feeding those handlers; keep `setDependencies` for context/manager injection.
5. **Tests — `ReliaBLEManagerTests.swift`.** Existing tests are unaffected (they touch none of the surfaces). Add one test (via `ReliaBLEMock`): two concurrent `stateStream()` subscribers both replay the current state and receive a later broadcast; `peripheralDiscoveriesStream()` does not replay; each property access returns a distinct stream.
6. **DocC — `Documentation.docc/GettingStarted.md` (+ `Documentation.md`).** Replace the `.sink` / `.store(in:)` examples with `.task { for await … }`. Document prominently: fresh stream per access, multi-subscriber by design, replay for `state` / `discoveredPeripherals`, no replay for `peripheralDiscoveries`.
7. **Verify.** `swift build` + `swift test`; grep confirms zero `import Combine` in `Sources/ReliaBLE*`; Demo scheme builds; `currentState` still synchronous; `forceMock` / lazy-init / `SendableWrapper` intact.

## Decisions (resolved at planning)

1. **`currentState` stays synchronous; `currentBluetoothState` stays `nonisolated(unsafe)`.** It is not a Combine surface. Step 3 removes only Combine machinery; the snapshot now backs both `currentState` and `stateStream()` replay. Its TODO is reworded, not actioned. Revisiting `currentState`'s isolation belongs to Step 4 (#18).
2. **Buffering:** `.bufferingNewest(1)` for the two replay/snapshot surfaces — exactly 1, latest-wins; a larger buffer would hand a slow consumer stale intermediate snapshots. Unbounded (default) for the discoveries feed.
3. **No typed wrapper.** Return plain `AsyncStream<T>`; defer a `BluetoothEventStream<T>` façade unless an ergonomic need appears (the issue's open question).
4. **`peripheralDiscoveries` registration window** (an event lost between stream creation and continuation registration) is accepted and documented, not engineered around.

## Open Questions

None blocking. Two items to confirm during implementation:
- Whether a subscriber that opens `stateStream()` exactly as `broadcastState` fires sees a duplicated value — `.bufferingNewest(1)` collapses this to the latest, so it is benign; assert in the multi-subscriber test.
- Demo only: keep `setDependencies` vs. fold manager/context capture directly into the `.task` blocks — cosmetic, decide in code.

## References

- Issue #12 (this); parent #10; depends on #13 (Step 1, merged) and #17 (Step 2, merged).
- Investigation report: `docs/investigations/swift6-concurrency-audit-2026-05-13.md` — Findings §1/§2, Cluster 2, Recommendations §A (AsyncStream broadcaster).
- Step 1 plan: `docs/plans/bluetooth-actor-migration-2026-06-08.md`; Step 2 plan: `docs/plans/peripheral-sendable-struct-2026-06-13.md`.
- Key files: `Sources/ReliaBLE/BluetoothActor.swift`, `BluetoothManager.swift`, `ReliaBLEManager.swift`; `Sources/ReliaBLE/Documentation.docc/`; `Demo/ReliaBLE Demo/ReliaBLE Demo/Central/CentralViewModel.swift`.
