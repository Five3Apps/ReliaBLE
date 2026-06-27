# `ReliaBLEManager` → nonisolated `Sendable` + collapse `BluetoothManager`: Plan (Step 4 of 5)
*Issue #18 · 2026-06-23*

## Goal

Make `ReliaBLEManager` a **nonisolated `Sendable final class`** that forwards directly to `BluetoothActor.shared`, and delete the now-vestigial `BluetoothManager` indirection. This completes the architectural goal: the library is callable cleanly from `@MainActor` SwiftUI *and* background actors without forcing a MainActor hop on background callers. Also remove the dead `testFunction()` and `AuthorizationError.unauthorized`.

## Background (verified current state, post-Step-3)

The issue text predates the Step 3 implementation and is **stale** in several places. Verified actual state:

- **`ReliaBLEManager.swift`** — `public class ReliaBLEManager` (not `final`, not `Sendable`, no isolation). Holds `private let bluetoothManager: BluetoothManager` (:37), created in `init` (:52). All public actions are **already `async`** (`authorizeBluetooth` :81, `startScanning` :110, `stopScanning` :115, `connect` :133). The three event surfaces are **already `AsyncStream`** (:67/:90/:97). `currentState` is **synchronous** (:72). Dead `testFunction()` at :135.
- **`BluetoothManager.swift`** — now a **thin pass-through** to `BluetoothActor.shared` (every method one-line forwards). Its only real job beyond forwarding: `init` fires `Task { await BluetoothActor.shared.initialize(log:) }` (:64), with a documented non-FIFO-ordering caveat (:51–63). The file **also hosts the public types** `AuthorizationStatus` typealias (:139), `BluetoothState` enum (:146), `AuthorizationError` enum (:206) — these are *not* tied to the `BluetoothManager` class. Several `BluetoothState` doc comments still say "`BluetoothManager`" (:143,148,150,156,163,165).
- **`BluetoothActor.swift`** — `@globalActor` internal `actor BluetoothActor` already does all real work via `BluetoothActor.shared`. Holds actor-isolated `currentBluetoothState` as the `currentState` backing **and** the `stateStream()` replay value. `initialize(log:)` doc comment references `ReliaBLEManager.init`. PeripheralManager is already gone (issue item #5 already done). The actor is **not** part of the public API — consumers interact only through ``ReliaBLEManager``.
- **No `import Combine` anywhere in Sources** (Step 3 complete).

**Already-done issue items (no work needed):** PeripheralManager collapse (#5); public methods async (#2); AsyncStream surfaces (#3 partial); Demo already `await`s every call and consumes streams via `.task` (#8 — see below).

**Blast radius of the changes:**
- `BluetoothManager` symbol: referenced **only** in `Sources/` (the files themselves) and `docs/`. **Zero** references in `Demo/` or `Tests/`.
- `currentState`: the **Demo never reads `manager.currentState`** — it mirrors state through the `state` stream into its own `@Observable` VM property (`CentralViewModel.swift:34,52`; view reads `viewModel.currentState`). Tests have **zero** `currentState` references. Only DocC examples read it synchronously (`GettingStarted.md:90,105`).
- `AuthorizationError.unauthorized`: **genuinely dead** — never thrown or matched (the `.unauthorized` grep hits are `CBManagerState` in a switch, DocC prose, and the Demo's own enum).
- `testFunction()`: exercised by one test (`ReliaBLEManagerTests.swift:30`) — that test must be removed/replaced.
- Demo consumes the manager only from SwiftUI `.task` / fire-and-forget `Task {}` in a non-`@MainActor` `@Observable` VM. Making the manager `Sendable` only *removes* latent cross-actor warnings; nothing breaks.

**Design intent (audit report).** `docs/investigations/swift6-concurrency-audit-2026-05-13.md` is decisive:
- **§A (chosen architecture):** nonisolated `Sendable` `ReliaBLEManager`, *not* `@MainActor` — a `@MainActor` façade would force every background caller to hop MainActor → BluetoothActor per call. SwiftUI integrates via `.task { for await … }`; `@Observable` belongs in *consumer* view-models.
- **§7 (naming):** `BluetoothManager`'s responsibilities collapse into the actor; the `BluetoothActor` name is the chosen target.
- **currentState:** the report models it as **`get async`** post-refactor (`get async { await BluetoothActor.shared.currentBluetoothState }`), marked BREAKING. The PR#23 evaluation (`docs/investigations/copilot-pr23-review-evaluation-2026-06-11.md:74`) independently flags that the current `nonisolated(unsafe)` read of the *payloaded* `BluetoothState` enum can **tear** — a real data-race argument for moving the read onto the actor.

## Approach

Collapse the layering from `ReliaBLEManager → BluetoothManager → BluetoothActor.shared` down to `ReliaBLEManager → BluetoothActor.shared`. `BluetoothManager` carries no state worth keeping — every method is a one-line forward; its only real behavior is the fire-and-forget `initialize` Task in `init`, which moves verbatim into `ReliaBLEManager.init`. The three public types it incidentally hosts get relocated, then the file is deleted.

`ReliaBLEManager` becomes `public final class ReliaBLEManager: Sendable`. After dropping the `bluetoothManager` stored property, it holds only two `Sendable let`s (`loggingService`, `log`), so `Sendable` conformance is trivial and requires no `@unchecked`. Every forwarder retargets from `bluetoothManager.X` to `BluetoothActor.shared.X`. The nonisolated stream factories (`stateStream()` etc.) are already callable from a nonisolated context, and the async actions already `await` the actor — so the retarget is mechanical. Lazy central-manager init and the `forceMock: true` literal stay untouched inside `BluetoothActor`.

Two decisions were resolved at the Mid-flow checkpoint (see **Decisions**):

- **`currentState` → `get async`**, reading the actor directly, and **drop `nonisolated(unsafe)`** from `currentBluetoothState` (its only other reader, `register(stateContinuation:)`, runs on-actor). This realizes the audit's §A design and eliminates the payloaded-enum tearing race the PR#23 eval flagged. Cost is near-zero: pre-1.0, no external consumers, and the Demo never reads `manager.currentState` — only DocC examples (`GettingStarted.md:90,105`) need an `await`.
- **Inline the public types into `ReliaBLEManager.swift`** (after the class): `AuthorizationStatus`, `BluetoothState`, `AuthorizationError`. Fix the stale "`BluetoothManager`" mentions in the `BluetoothState` doc comments during the move. DocC anchors key on symbol name, not file path, so the move breaks no links.

## Work Items

Land inside-out so the build stays green at each step.

1. **Relocate public types out of `BluetoothManager.swift` into `ReliaBLEManager.swift`** (after the class). Move `AuthorizationStatus` (:139), `BluetoothState` (:146), `AuthorizationError` (:206). Delete the dead `AuthorizationError.unauthorized` case. Reword the `BluetoothState` doc comments that say "`BluetoothManager`" to describe ReliaBLE's behavior without naming the internal actor. *(Build green — types still exist, just moved.)*
2. **Retarget `ReliaBLEManager` to the actor.** Remove `private let bluetoothManager` (:37) and its `init` assignment (:52); move the fire-and-forget `Task { await BluetoothActor.shared.initialize(log: loggingService) }` (from `BluetoothManager.swift:64`, with its caveat comment) into `ReliaBLEManager.init`. Retarget every forwarder (`state`, `peripheralDiscoveries`, `discoveredPeripherals`, `authorizeBluetooth`, `startScanning`, `stopScanning`, `connect`) from `bluetoothManager.X` to `BluetoothActor.shared.X`. Make `currentState` `get async`. Do this as **one edit**: removing the property and adding the init Task together means exactly one `initialize` call, with no transient double-init. *(Build green.)*
3. **Make it `Sendable` + drop dead code.** Mark `public final class ReliaBLEManager: Sendable`; delete `testFunction()` (:135). Drop `nonisolated(unsafe)` from `BluetoothActor.currentBluetoothState` (:101) — make it a plain actor-isolated `var` — and reword its comment (it is now read on-actor by both `currentState`'s async getter and `register(stateContinuation:)`'s replay). *(Build green.)*
4. **Delete `BluetoothManager.swift`** (now empty). Update the `initialize(log:)` doc comment in `BluetoothActor.swift:202` ("Called once from `BluetoothManager.init`" → "`ReliaBLEManager.init`"). *(Build green.)*
5. **Tests — `ReliaBLEManagerTests.swift`.** Remove/replace the test at :30 that calls `testFunction()`. Add the acceptance test: capture a `ReliaBLEManager` into `Task.detached` and call every public method + read every stream — compilation proves `Sendable`. If `currentState` is async, `await` it where touched. *(Tests pass.)*
6. **DocC.** Add `await` to the `currentState` reads at `GettingStarted.md:90,105` (now async). Update `Documentation.md` Concurrency section to document ``ReliaBLEManager`` (not ``BluetoothActor``) as the public concurrency surface. Reword any public doc comments that cross-reference the internal actor. Per `CLAUDE.md`, DocC must track the public API.
7. **Hide `BluetoothActor` from the public interface.** Drop `public` from the actor and `shared` singleton. Tests retain access via `@testable import ReliaBLEMock`. No Demo or external-consumer impact — zero references outside `Sources/`. *(Build green.)*
8. **Verify.** `swift build && swift test`; grep confirms zero `BluetoothManager` references in `Sources/`; `forceMock: true` literal intact; lazy-init preserved; Demo target still builds and runs (no functional change expected — issue item #8 already satisfied by Step 3).

## Decisions (confirmed at Mid-flow checkpoint)

1. **`currentState` becomes `get async`**, reading the actor; `nonisolated(unsafe)` is dropped from `currentBluetoothState`. (Breaking signature change — acceptable pre-1.0, no external consumers, no Demo impact.)
2. **Public types are inlined into `ReliaBLEManager.swift`** (not relocated to `Models/`).
3. **`BluetoothActor` stays internal** — the global actor serializes Core Bluetooth state but is not exposed in the public API; ``ReliaBLEManager`` is the sole entry point.

## Notes

- **No double-`initialize` window.** `BluetoothManager` is already `internal` (never `public`) and is instantiated by nothing but `ReliaBLEManager` — zero references in `Tests/` or `Demo/`. Item 2 swaps the single instantiation for the single init Task in one edit, so `initialize` is called exactly once throughout. Item 1's type move leaves the still-internal class momentarily inert but harmless.
- **No surviving synchronous `currentState` readers.** The Demo mirrors state via the `state` stream into its own VM property and never reads `manager.currentState`; `Tests/` has zero `currentState` references. The async change touches only the two DocC examples (Item 6).

## References

- Issue #18; parent #10. Depends on #13 (Step 1), #17 (Step 2), #12 (Step 3) — all merged.
- Audit: `docs/investigations/swift6-concurrency-audit-2026-05-13.md` (Findings §4, Recommendations §A, Risks §7).
- PR#23 eval (tearing risk): `docs/investigations/copilot-pr23-review-evaluation-2026-06-11.md:74`.
- Prior step plans: `docs/plans/bluetooth-actor-migration-2026-06-08.md` (Step 1), `docs/plans/peripheral-sendable-struct-2026-06-13.md` (Step 2), `docs/plans/combine-to-asyncstream-2026-06-18.md` (Step 3).
- Key files: `Sources/ReliaBLE/ReliaBLEManager.swift`, `BluetoothManager.swift`, `BluetoothActor.swift`; `Tests/ReliaBLETests/ReliaBLEManagerTests.swift`; `Sources/ReliaBLE/Documentation.docc/`.
