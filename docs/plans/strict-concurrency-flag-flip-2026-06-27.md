# Logging polish + strict-concurrency flag flip + DocC update: Plan (Step 5 of 5)
*Issue #19 · 2026-06-27*

## Goal

Final polish pass closing out the Swift 6 migration: make `ReliaBLEConfig` explicitly `Sendable`, pin **Swift 6 language mode + complete strict concurrency** in `Package.swift` for both library targets, and add a DocC `Concurrency.md` page documenting the isolation contract. Steps 1–4 already delivered the architecture; this step makes the guarantees explicit and durable.

## Background (verified current state)

**Build status — already clean today.** `swift build` succeeds with no warnings in our sources. swift-tools-version is `6.1`, which defaults both targets to the **Swift 6 language mode** (= complete strict concurrency) even though `Package.swift` sets no `swiftSettings`. So the code already compiles under the regime this step makes explicit — the flag flip **pins intent**, it does not unlock new diagnostics. (A forced `-Xswiftc -strict-concurrency=complete` build also reports clean.)

**Logging layer (deliverables #1–#2) — both essentially no-ops, verified:**
- `ReliaBLEConfig` (`ReliaBLEConfig.swift:20`) is a struct with **no explicit `Sendable`**. All four stored fields are Sendable: `logLevels: LogLevel` (Willow `LogLevel: Sendable`, `LogLevel.swift:30`), `logWriters: [LogWriter]` (Willow `public protocol LogWriter: Sendable`, `LogWriter.swift:31`, so the existential array is Sendable), `logQueue: DispatchQueue` (Sendable), `loggingEnabled: Bool`. ⇒ Adding `: Sendable` compiles with **no other change**.
- `OSLogWriter` (`LogWriters.swift:35`) is `public final class OSLogWriter: LogModifierWriter` with **no explicit Sendable**. Since `LogModifierWriter: LogWriter: Sendable`, the clean v6 build **proves OSLogWriter already satisfies Sendable implicitly**. No `@unchecked Sendable` is needed today — it is only a contingency for a future SDK where the inferred conformance breaks.
- `LoggingService` is already `public final class … : Sendable` (`LoggingService.swift:20`). The `enabled` last-write race is deliberately left as-is (issue decision; tracked upstream as Willow#3) — no DocC note.

**Public concurrency surface (delivered Steps 1–4 — informs DocC + tests):**
- `ReliaBLEManager` is `public final class ReliaBLEManager: Sendable`, nonisolated, forwarding to the internal `@globalActor BluetoothActor.shared` (`ReliaBLEManager.swift:64`). Actions are `async` (`authorizeBluetooth()`, `startScanning(services:)`, `stopScanning()`, `connect(to:)`); `currentState` is `get async`.
- Three event surfaces — `state`, `peripheralDiscoveries`, `discoveredPeripherals` — each return a **fresh per-subscriber** `AsyncStream`. Replay via `.bufferingNewest(1)` for `state` and `discoveredPeripherals`; `peripheralDiscoveries` does **not** replay.
- `BluetoothActor` is **internal**. `Peripheral`, `AdvertisementData`, `PeripheralDiscoveryEvent` are `Sendable` value structs.

**Tests (deliverables #6–#7) — already exist:**
- `ReliaBLEManagerTests.swift:30` `reliaBLEManagerIsSendable` — captures a `ReliaBLEManager` in `Task.detached` and exercises every public member (streams, `currentState`, `authorizeBluetooth`, scanning, `connect`).
- `ReliaBLEManagerTests.swift:51` `peripheralIsSendable` — captures `Peripheral` in `Task.detached`.
- ⇒ No new tests needed; this step **verifies** they still pass under the explicit flags.

**DocC catalog** (`Sources/ReliaBLE/Documentation.docc/`, excluded from `ReliaBLEMock`):
- `Documentation.md:1-29` already has a `### Concurrency` topic group with a one-line `ReliaBLEManager` entry but **no dedicated article**. Articles live under `Topics/` (e.g. `Topics/Logging.md`) and are linked via `<doc:Name>`.

## Approach

The substantive work is small and low-risk because the code already compiles under Swift 6 mode. Three concrete edits plus documentation:

1. One-line `Sendable` on `ReliaBLEConfig` — proven safe by the field audit above.
2. Pin language mode + strict concurrency in `Package.swift` on **both** `ReliaBLE` and `ReliaBLEMock`, making the guarantee independent of the tools-version default. `.swiftLanguageMode(.v6)` already implies complete strict concurrency; `.enableExperimentalFeature("StrictConcurrency")` is belt-and-suspenders and harmless.
3. Leave `OSLogWriter` as-is (conformance already satisfied); add only a short comment recording why, with the `@unchecked Sendable` fallback noted as a contingency — do **not** apply it unless a build actually fails.
4. New DocC `Concurrency.md` article documenting the isolation contract, linked from `Documentation.md`. Optional ASCII isolation graph inline (no binary asset to manage).

Verification gates the step: `swift build`, `swift test`, and `swift package generate-documentation` must all be clean.

Demo cross-actor validation (audit "Preventive Measures") is **outside this step's acceptance criteria** — Issue #19 scopes acceptance to the library. If wanted, delegate it separately to a sub-agent that reads `Demo/CLAUDE.md` first.

## Work Items

Ordered so the build stays green at each step.

1. **`ReliaBLEConfig: Sendable`.** `ReliaBLEConfig.swift:20` — change `public struct ReliaBLEConfig {` → `public struct ReliaBLEConfig: Sendable {`. No other change. *(Build green.)*

2. **Pin flags in `Package.swift`.** Add an identical `swiftSettings:` to both targets. `swiftSettings:` is a sibling argument to `dependencies:` (and, for the mock, `exclude:`) in the target literal — append it last, comma-separated:
   ```swift
   .target(
       name: "ReliaBLE",
       dependencies: ["Willow"],
       swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("StrictConcurrency")]
   ),
   .target(
       name: "ReliaBLEMock",
       dependencies: [ "Willow", .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock") ],
       exclude: ["ReliaBLE/CBCentralManagerFactory.swift", "ReliaBLE/Documentation.docc"],
       swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("StrictConcurrency")]
   ),
   ```
   Leave the `ReliaBLETests` target as-is. If strict checking surfaces issues from the `CBM*` aliases, the fix belongs in `CoreBluetoothMockAliases.swift` (escape hatches like `@preconcurrency`/`@retroactive @unchecked Sendable` are permitted in `ReliaBLEMock` only). Not expected — v6 is already the effective default and the target builds clean. *(Build green.)*

3. **`OSLogWriter` comment.** `LogWriters.swift:35` — keep the declaration unchanged. Add a one-line comment noting Sendable is satisfied via `LogModifierWriter: LogWriter: Sendable`, with the `@unchecked Sendable` fallback recorded as a contingency (matching upstream `Willow.OSLogWriter`). Apply `@unchecked` only if a build genuinely fails. *(Build green.)*

4. **DocC `Concurrency.md`.** Create `Sources/ReliaBLE/Documentation.docc/Topics/Concurrency.md`. DocC auto-compiles every `.md` in the catalog, so no manifest/index entry is required — the curation link in Work Item 5 is what surfaces it in navigation. Document:
   - `ReliaBLEManager` is `Sendable` + nonisolated → callable from `@MainActor` SwiftUI **and** background actors with no forced MainActor hop.
   - All actions are `async`; `currentState` is `get async`.
   - Event surfaces return **fresh per-subscriber** `AsyncStream`s; show the SwiftUI `.task { for await … }` pattern; note replay semantics (`state`/`discoveredPeripherals` replay latest; `peripheralDiscoveries` does not).
   - `BluetoothActor` is internal — consumers must not reference it.
   - *(Optional)* inline ASCII isolation graph: `ReliaBLEManager (nonisolated, Sendable) → BluetoothActor (@globalActor) → delegate shim → CoreBluetooth`.

5. **Link the article.** `Documentation.md:24-26` — the `### Concurrency` group currently holds a single bullet (the `ReliaBLEManager` symbol entry). Add `- <doc:Concurrency>` as a sibling bullet in that same group, keeping the symbol entry. (A `### Concurrency` heading with two bullets is valid DocC curation.)

6. **Verify.**
   - `swift build` clean on both targets.
   - `swift test` green — confirm `reliaBLEManagerIsSendable` (:30) and `peripheralIsSendable` (:51) pass and still cover the full public surface (async `currentState`, `connect`, all three streams).
   - `swift package generate-documentation --target ReliaBLE` (catalog lives only in the production target) builds **clean**; `Concurrency.md` renders in navigation under the Concurrency group.

## Open Questions

- **Demo validation in scope?** The audit lists Demo cross-actor validation under Preventive Measures, but Issue #19's acceptance criteria are library-only. Default: out of scope here — delegate separately (sub-agent reads `Demo/CLAUDE.md` first) if wanted.

## References

- Issue #19 (Step 5 of 5); parent #10. Depends on #13 / #17 / #12 / #18 — Steps 1–4, merged.
- Audit: `docs/investigations/swift6-concurrency-audit-2026-05-13.md` (Recommendations §C, Migration order Step 5, Preventive Measures).
- Upstream `enabled` race: itsniper/Willow#3 (no ReliaBLE-side work).
- Willow Sendable constraints: `.build/checkouts/Willow/Source/LogWriter.swift:31`, `LogLevel.swift:30`.
- Prior step plans: `docs/plans/bluetooth-actor-migration-2026-06-08.md`, `peripheral-sendable-struct-2026-06-13.md`, `combine-to-asyncstream-2026-06-18.md`, `manager-sendable-collapse-2026-06-23.md`.
- Key files: `Sources/ReliaBLE/ReliaBLEConfig.swift:20`, `Logging/LogWriters.swift:35`, `Package.swift`, `Documentation.docc/Documentation.md`, `Tests/ReliaBLETests/ReliaBLEManagerTests.swift:30,51`.
