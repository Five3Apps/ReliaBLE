# Feedback for planning agent: roll into work-driven connection lifecycle plan

**Audience:** main planning agent updating `docs/plans/work-driven-connection-lifecycle-2026-08-02.md`  
**Source:** user review of poweredOff behavior summary + confirmed design choices (2026-08-05)  
**Do not implement code from this doc.** Apply these amendments into the lifecycle plan only, then re-check consistency of D-0 / D-1 events / D-2 / D-4 / D-7 / tests / DocC / rejected alternatives.

**Prior critique (still valid where not overridden):** `docs/reviews/work-driven-connection-lifecycle-plan-critique-2026-08-02.md`

---

## How to apply

1. Treat each section below as a **normative plan change** unless marked optional.
2. Where this feedback **contradicts** the current plan (especially **D-restore**, restore-time persistence read, connect hold ordering, parked-scan `CancellationError`), **this feedback wins** — it is later user direction.
3. Leave Phase 2 implementation to a later execute pass; this is design-only roll-up.
4. After editing the plan, update the test table, risks, and rejected-alternatives rows so they do not restate superseded decisions.

---

## A — Bluetooth state observation — no plan change

Keep `ReliaBLEManager.state` / `currentState` as the UI-gating surface, including `.poweredOff`. FR-1.4 dual requirement (observable state + typed operation errors) stands.

---

## B — No live `cbPeripheral` under demand — **keep D-never; no internal scan in Phase 2**

### Confirmed

| Path | Phase 2 | Mechanism |
|------|---------|-----------|
| Known id after power cycle | Yes | `refreshPeripherals()` → `retrievePeripherals(withIdentifiers:)` |
| Known id still in CB system cache | Yes | Same retrieve on radio-return / `reevaluateLink` |
| Never-seen / not retrievable | No | Fail-fast `PeripheralError.notFound` (D-never) |
| Library-owned continuous or demand-driven scan | Deferred | FR-8.2 / FR-4 command queue |

### Plan edits

- **Keep D-never** as written (fail-fast, no await-for-discovery, no implicit scan).
- Under D-never / D-7, add: recovery after invalidate is **retrieve-only**; no library scan loop.
- **Do not** invent a second “scan-until-found” stack in Phase 2. Keep a single `reevaluateLink` that surfaces `notFound` when there is no live ref — FR-8.2/FR-4 can later add scan policy + call `reevaluateLink` on discovery (additive).
- **Optional Phase 2 polish (document as allowed, implement if cheap):** when discovery upserts an id that already has demand, call `reevaluateLink` (e.g. reason `.discoveredWhileDemanded` or reuse `.radioReturned`). Does not start scans; only links if something else discovered the device.

---

## C — Pending restored-scan filter cleared on invalidate — **don’t box out FR-8.2**

### Context

Today `invalidatePeripherals` nils `pendingRestoredScanServices` / options. Warm power-off can drop a deferred restored scan that had not resumed.

### Plan edits

- Phase 2 must **not** invent continuous-scan demand or make work-lease / manual-hold imply “keep scanning.”
- **Preferred minimal Phase 2 change:** when invalidating due to `.poweredOff` / `.resetting`, **preserve** `pendingRestoredScanServices` and options (stop nilling them on that path). Full continuous-scan policy stays FR-8.2.
- If preserving is not trivial without inventing scan-demand semantics, leave clear-as-today and add a one-line open item **owned by FR-8.2**: “power-cycle may drop deferred restored scan until continuous-scan demand is defined.”
- DocC / risks: one sentence that true background continuous scan is FR-8.2, not Phase 2 demand/hold.

---

## D — Scan/connect fail-fast on `.poweredOff` — no change to throw policy

D-radio stands: `.poweredOff` → `PeripheralError.bluetoothPoweredOff` (not hang). Hold registration order is refined in **E**.

---

## E — Manual-connect hold **before** radio wait — **amend plan (user)**

### Problem with current plan

`ensure → waitUntilPoweredOn → applyManualConnect` means a failed wait leaves **no hold**, so radio return does nothing. That contradicts `autoReconnect: true` as “connect whenever the peripheral is available.”

### Normative connect sequence

```
Peripheral.connect(autoReconnect:):
  1. ensureCentralManager()
  2. applyManualConnectHoldOnly(id, reconnectDesired: autoReconnect)
     // set manualConnectHold, cancel idle, sync persistence (hold map)
  3. try waitUntilPoweredOn()   // may throw bluetoothPoweredOff / unsupported / unavailable
  4. try reevaluateLink(id, reason: .explicitConnect)
```

| `autoReconnect` | Wait fails | After throw | Radio returns |
|-----------------|------------|-------------|---------------|
| `true` | Hold already set + persisted | Typed error to app | Event 12 re-issues (`wantsReconnect`) |
| `false` | Hold already set (demand true, wantsReconnect false) | Typed error | Radio-return does **not** re-issue (issue gate) |

### Plan edits

- Update D-hold, event 3 / call-site table, Peripheral.connect sketch.
- D-7 row: “connect while poweredOff sets hold then throws.”
- Rejected alternative: “hold only after radio wait succeeds.”
- Tests: `connectPoweredOffSetsHoldAndRelinksOnPowerOn`, `connectAutoReconnectFalsePoweredOffDoesNotRelinkOnPowerOn`.
- Public API name remains `autoReconnect` (not `autoConnect`).

---

## F — After radio drop, auto-relink peripherals show `.reconnecting` — **amend plan (user)**

### Problem

`clearConnectionStates` → stream `.disconnected(.bluetoothUnavailable)` + handle `connectionState == nil` hides auto-relink intent. With no public demand API, the app cannot tell “will come back” from “gone.”

### Confirmed public state

After the drop signal, ids with **`wantsReconnect(id)`** use:

```swift
.reconnecting(source: .library, attempt: nil, nextRetryAt: nil)
```

while radio is down or until `issueConnect` / ladder / success / demand cleared.

### Normative sequence on `.poweredOff` invalidate (event 13)

1. For each tracked id: emit `.disconnected(reason: .bluetoothUnavailable)` (link is dead).
2. Clear CB maps; cancel idle + ladder tasks; **preserve** `activeLeases` + `manualConnectHold`.
3. For each id with `wantsReconnect(id)`: `setConnectionState(.reconnecting(source: .library, attempt: nil, nextRetryAt: nil))`.
4. Demand but **not** wantsReconnect (`connect(autoReconnect: false)`): **no** false “will reconnect” signal (settle disconnected / no reconnecting phase).
5. No demand: handle untracked (`nil` after clear); stream had step 1 only.
6. On radio return: event 12 → `issueConnect` → `.connecting` → `.connected` / fail / ladder as today.

### Plan edits

- Map conceptual phase `AwaitingRadio` → public `.reconnecting(source: .library, attempt: nil, nextRetryAt: nil)` when `wantsReconnect`.
- Replace bulk “always nil handle” narrative for auto-relink ids; likely replace/split `clearConnectionStates` with per-id policy.
- DocC on `ConnectionState.reconnecting`: nil `attempt` / `nextRetryAt` means “waiting for radio or not yet on backoff ladder,” distinct from an armed ladder step.
- Tests: power-off with hold/lease asserts reconnecting, not permanent nil.

---

## G — Approach B reconnect gating — no plan change

`wantsReconnect` gates Tier-0 option and Tier-1 `armReconnect`; quiet peripherals never arm.

---

## H — Not re-retrievable after refresh — **fatal for auto recovery; no scan/retry**

### Confirmed

- Delegate-context `reevaluateLink` → `.failed(reason: .notFound)` on the connection-state stream.
- **No** library scan and **no** silent retry loop in Phase 2.
- Lease/hold **remain** unless app `disconnect()` / releases work (demand not silently dropped).
- Optional discovery→`reevaluateLink` (B) can recover later if the app scans.
- Phase 3 command queue should treat `.failed(.notFound)` as command failure (separate from lease lifetime).

### Plan edits

- D-7 / unknowns: state “no scan-on-notFound.”
- `strandedLeaseSurfacesFailure` asserts demand retained after failure signal.

---

## J — Background restore re-applies manual-connect hold — **reverse prior D-restore (user)**

### Prior plan (superseded)

D-restore said restored links always idle; UserDefaults is reconnect intent only, **never** a hold; demand must be re-declared after relaunch. D-4 said **delete the restore-time read**.

### New normative D-restore

| Restored situation | Behavior |
|--------------------|----------|
| OS restores peripheral **and** persisted **manual-connect hold** for that id | Rehydrate `manualConnectHold[id]` (with `reconnectDesired`), sync intent, **no idle timer**, `reevaluateLink` if not linked |
| OS restores link, **no** persisted hold | **Idle timer** (battery-first for residual/Tier-0 restored links) |
| Work leases | **Never** survive process death |
| Hold with `reconnectDesired: false` | Survives restore: demand/idle suppressed; no Tier-1 / no radio-return re-issue |

### Persistence model

- Persist enough to rehydrate **holds**, not only a reconnect-enabled Set.
- **Recommended encoding:** dictionary `id → reconnectDesired: Bool` (or equivalent) namespaced by `restoreIdentifier`. A Set of true-only ids is **insufficient** for `autoReconnect: false` holds.
- Sole writer remains demand-sync after hold changes (rename in prose to “sync persisted holds” if clearer).
- **Restore-time read returns** in `handleWillRestoreState` — undo “delete the restore-time read.”
- Idle-out of one restored link must not wipe other ids’ persisted holds.
- NFR-3.2: still met for restored links **without** a prior Manual connect hold. Manual `connect` is explicit “keep this link” and should outlive relaunch when restoration is configured.

### Plan edits

- Replace D-restore row in D-0.
- Rewrite D-4 (persistence meaning, restore read, tests).
- Remove from rejected alternatives / risks any “never re-apply hold” / “delete restore-time read” language that is now wrong.
- Tests: `restoredManualHoldSurvivesRelaunch`, `restoredLinkWithoutHoldIdlesOut`, `restoredHoldWithAutoReconnectFalseSuppressesIdleButNotTier1`.

---

## K — Parked `startScanning` waiter — **success on stopScanning supersede; `CancellationError` only on Task cancel**

### Supersedes plan row that always uses `CancellationError` for cancelled waiters

| Cause | `startScanning` result |
|-------|------------------------|
| `stopScanning()` while parked on transient radio | **Return success** (void), no scan started |
| Superseded by another `startScanning` | Earlier waiter completes **success** without scanning (or coalesced — document) |
| Calling task cancelled (`Task.cancel`) | **`CancellationError`** |
| Radio resolves to `.poweredOff` | **`bluetoothPoweredOff`** (not success) |

### Plan edits

- D-2 call-site table for `stopScanning`.
- D-7 rows for waiting scan cancelled vs stopScanning.
- Tests: `stopScanningCompletesParkedScanWaiterSuccessfully`; separate test for Task cancel → `CancellationError`.
- Implementation note: resume reason enum (`.poweredOn` / `.superseded` / `.failed` / cancel path).

---

## L — `shutdown()` must not touch UserDefaults — **confirm and harden**

### Already true in code comments; plan must not regress

- `shutdown()` clears **volatile** state only (holds, leases, waiters, task registries, streams).
- **Must not** call `persistReconnectIntent` / hold-sync writers when clearing in-memory holds (empty flush would erase restore intent — breaks **J**).
- Optional explicit clear/reset API for UserDefaults can come later; test hook `testClearPersistedReconnectIntent` may remain.
- Event 14 bullet + risk table + test: shutdown leaves persisted hold map unchanged.

---

## Checklist for the planning agent (edit targets in the lifecycle plan)

| # | Section | Action |
|---|---------|--------|
| 1 | D-0 **D-restore** | Reverse: rehydrate holds from persistence; idle only without hold; work non-durable |
| 2 | **D-4** | Persist hold map `id → reconnectDesired`; restore-time read **returns**; sole writer demand-sync; invalidate/shutdown do not wipe disk |
| 3 | **D-hold** / connect path / D-2 table | Hold **before** `waitUntilPoweredOn` (E) |
| 4 | D-1 **event 13** | After disconnect emission, `wantsReconnect` → `.reconnecting(library, nil, nil)` (F); still add `.poweredOff` to invalidate triggers; preserve demand |
| 5 | **D-never** / B | Keep fail-fast; retrieve-only recovery; optional discovery→reevaluate; no internal scan |
| 6 | Event 13 / invalidate | Prefer preserve pending restored scan on power-cycle invalidate (C); FR-8.2 owns continuous scan |
| 7 | **D-2** / K | stopScanning supersede → success; Task.cancel → CancellationError |
| 8 | **H** | notFound after refresh terminal for auto path; demand retained |
| 9 | Event 14 / **L** | shutdown never writes UserDefaults |
| 10 | D-7, tests, DocC, risks | Align all tables with above |
| 11 | **D-8 Rejected alternatives** | Strike superseded rows (delete restore read; never re-apply hold; hold only after wait); add rejections as needed (hang on poweredOff stays rejected; internal scan-on-demand stays rejected for Phase 2) |

---

## Explicitly out of scope for this roll-up

- Implementing Phase 2 code.
- FR-8.2 continuous / background scan policy design.
- FR-4 command queue / await-linked work.
- Public work-lease API.

---

## Consistency checks after the plan edit

- [ ] No remaining “delete restore-time read” or “restoration never re-applies a manual-connect hold.”
- [ ] No remaining “hold applied only after wait succeeds.”
- [ ] No remaining “parked scan waiter always throws CancellationError” without distinguishing stopScanning vs Task.cancel.
- [ ] Event 13 + F do not leave auto-relink ids stuck at handle `nil` with no reconnecting signal.
- [ ] Persistence encoding supports `reconnectDesired: false` holds across restore (dictionary, not true-only Set).
- [ ] shutdown / invalidate paths never empty-flush UserDefaults.
- [ ] D-never still blocks Phase 2 internal scan; FR-8.2 door left open.
