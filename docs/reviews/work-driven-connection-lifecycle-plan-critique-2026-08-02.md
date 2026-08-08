# Critique: Work-Driven Connection Lifecycle Plan (2026-08-02)

Reviewed: `docs/plans/work-driven-connection-lifecycle-2026-08-02.md` against the generated-plan
baseline in `prompt-exports/oracle-plan-2026-08-02-104458-phase-2-work-driven-1d95.md` (from
`## Generated Plan`, line 164 onward) and the current code in `Sources/ReliaBLE/`. Line numbers
below are from today's `BluetoothActor.swift`; navigate by symbol.

The four user decisions (one PR; `.poweredOff` fails fast; internal-only work primitive;
restoration restores reconnect intent only, never a hold) are treated as fixed. This critique
checks follow-through, not the decisions themselves.

## Verdict summary

The plan is a faithful, mostly tightened rendering of the export. The export's two known-wrong
sections (poweredOff-awaits, D-restore hold re-application) are correctly overridden everywhere,
including the rejected-alternatives table. The serious problems are not export-vs-plan drift but
five shared blind spots: **poweredOff state staleness**, **self-erasing persisted intent**,
**teardown against a not-actually-connected peripheral**, **the `reconnectDesired: false` hold
contradiction**, and **lease double-release bookkeeping**. Each is detailed below with a concrete
correction.

---

## 1. Export content missing or weakened in the plan

The plan is close to a superset of the export. Only one real loss:

- **Connect-side radio-await test coverage dropped.** The export's test table had
  `connectAwaitsPoweredOn`. Under D-radio that exact test is obsolete (poweredOff now throws), but
  the plan replaced it with only the fail-fast case (`connectFailsWhenPoweredOff`). The transient
  analogs are missing: *connect awaits `.resetting`/`.unknown` and proceeds on `.poweredOn`*, and
  *connect waiter parked on a transient that resolves to `.poweredOff` throws*. The plan has both
  variants for scan (`startScanningAwaitsTransientState`,
  `transientStateResolvingToPoweredOffFailsWaiter`) but neither for `Peripheral.connect`, whose
  await path routes through `applyManualConnect` and is a distinct code path. **Add
  `connectAwaitsTransientState` and a connect-side transient→poweredOff failure test.**

Non-losses worth recording so they aren't re-litigated:

- The export's §3.2 entry-check nuance ("no central and auth not allowed → unavailable; don't
  create central from scan without auth") is compressed in the plan to "No central →
  `bluetoothUnavailable` (callers reach here only after `ensureCentralManager()`)". Equivalent
  given the existing ensure rules; fine.
- The export's "atomic landings" warning survives as the plan's "single PR because public connect
  semantics are inconsistent mid-sequence". Kept.
- The export's optional `idleGeneration` guard was made mandatory in the plan. Improvement, not
  drift.
- The export's `restoreWithPersistedHoldKeepsLink` test is correctly deleted (D-restore override),
  but see §3 on what should replace it.

## 2. Under-specified seams, contradictions, and missing dependencies in the plan

### 2.1 The `reconnectDesired: false` hold contradicts demand-driven `reevaluateLink` (material)

A hold from `connect(autoReconnect: false)` makes `demand(id) == true` but
`wantsReconnect(id) == false`. Walk an unexpected drop:

1. `handleDidDisconnect`, `isReconnecting == true` → event 9's untrusted-Tier-0 branch fires
   (`!wantsReconnect`) and **cancels the connection** — even though demand is present.
2. Or `isReconnecting == false` → no ladder (`armReconnect` gated off). Link stays down.
3. Later, *any* `reevaluateLink(id:)` trigger — most concretely event 12's radio-return sweep
   ("for every id with demand that is not linked, `reevaluateLink`") — sees `demand == true`, link
   down, and **issues a fresh connect**.

So a no-reconnect hold both refuses reconnection (events 9–11) and silently reconnects after a
radio cycle (event 12). The edge-case row "`connect(autoReconnect: false)` … matching today's
`autoReconnect: false` semantics" is not achievable as specified. **Decide and write down one
rule.** The clean fix: after an unexpected drop, a `reconnectDesired == false` hold does not
constitute *re-issue* demand — gate the "Otherwise → `issueConnect`" arm of `reevaluateLink` on
`workCount > 0 || hold?.reconnectDesired == true` (i.e., `wantsReconnect`), keeping bare `demand`
only for idle suppression. That preserves FR-11.2 ("hold suppresses idle") without inventing a
reconnect the app declined.

### 2.2 Untrusted-Tier-0 branch: published state and stranded `intentionalDisconnects`

Event 9's middle branch says "insert `intentionalDisconnects[id]` and call
`cancelPeripheralConnection`" but never says what `ConnectionState` is published. Today's
`isReconnecting` branch publishes `.reconnecting(source: .system)` (`handleDidDisconnect`, :1210);
the new branch presumably publishes `.disconnecting`, but that must be stated — it is the only
place a `.disconnecting` would be emitted without an app call. Worse: if CoreBluetooth delivers
**no follow-up callback** for a cancel issued against a peripheral in OS-reconnect limbo, the
state sticks at `.disconnecting` forever and the stale `intentionalDisconnects` entry misclassifies
the *next* real drop as intentional. The plan's unknown covers only the **mock's** behavior;
extend it to on-device behavior, and specify a fallback (e.g., if no callback arrives, settle to
`.disconnected(reason: nil)` directly and remove the intentional flag). Note the loop question is
otherwise fine: `!wantsReconnect` implies `workCount == 0`, so the follow-up intentional branch
cannot relink — no cancel/reconnect cycle (see §Spot-checks).

### 2.3 Idle teardown while `.reconnecting(source: .library)` — cancel against a disconnected peripheral

Event 2 starts idle grace when the link is "connected/connecting/reconnecting", and event 6/7 fire
by "running the intentional-cancel path". But in library-`.reconnecting` the peripheral is
*physically disconnected* (the ladder task is sleeping between attempts). `syncReconnectIntent` on
demand-drop cancels the ladder task, which leaves `connectionStates[id]` frozen at
`.reconnecting(.library, …)` — nothing updates it — and then `fireIdle` calls
`cancelPeripheralConnection` on a peripheral that is not connected or connecting. CoreBluetooth
does not guarantee a `didDisconnect` for that; result is a permanent `.disconnecting` plus a
stranded intentional flag (same failure shape as §2.2). **Specify:** when demand drops while the
state is library-`.reconnecting` (or `.disconnected`/`.failed`), skip the CB cancel and the idle
timer entirely — cancel the ladder and publish `.disconnected(reason: nil)` synchronously. Idle
grace should only ever be armed against `.connected`/`.connecting`/system-`.reconnecting`.

### 2.4 `reevaluateLink` failure handling in non-throwing contexts

`reevaluateLink` throws `notFound` (event 5). Two of its call sites cannot propagate: the
intentional-relink branch of `handleDidDisconnect` (event 9) and the radio-return sweep
(event 12) — both run in delegate/event context with no caller to receive the error. After an
`invalidatePeripherals`, `refreshPeripherals` (:1037) only re-fills `cbPeripherals` for entries
`retrievePeripherals` still returns, so `notFound` is *reachable* on the event-12 path with a
work lease outstanding. The plan must say what happens: log-and-drop leaves the lease holder
waiting forever with no signal; publishing `.failed(reason: .notFound)` through
`setConnectionState` at least surfaces it on the stream. Pick one.

### 2.5 Persistence has two write choke points

Event 3 (`applyManualConnect`) says "persist reconnect intent if `autoReconnect` and
`restoreIdentifier != nil`", and D-4's `syncReconnectIntent` also persists ("insert … and persist
if the intent is hold-driven"). Since `applyManualConnect` already calls `syncReconnectIntent`,
the explicit persist in event 3 is redundant and invites drift. Make `syncReconnectIntent` the
sole writer (the plan already gives it the sole-remover role).

### 2.6 `disconnect()` during a radio outage cannot drop the hold cleanly

The demand-preserving invalidate (event 13) makes this state reachable: hold held, radio hits
`.resetting`, `cbPeripherals` cleared. The app calls `Peripheral.disconnect()` → event 4 "run the
existing intentional-cancel path" → today's `disconnect(id:)` throws `notFound` when
`cbPeripherals[id]` is nil (:1116). Is the hold cleared before the throw? Event 4's step order
(clear hold first) suggests yes, but then the app gets an error for a disconnect that actually
succeeded in dropping demand — and this is the *only* way to drop demand during an outage.
**Specify:** `applyManualDisconnect` clears the hold unconditionally and returns success when
there is no live peripheral or no CB-level connection to cancel (nothing to tear down is not an
error).

### 2.7 `stopScanning` vs parked scan waiters

`startScanning` can now be suspended in `waitUntilPoweredOn`. The plan leaves `stopScanning`
"unchanged", which means a `stopScanning` call does not cancel a parked `startScanning` — the scan
will start later, after the app said stop. Either document that the caller must cancel the task,
or have `stopScanning` fail/cancel pending scan waiters. One sentence in D-2 settles it.

## 3. Details the code disproves, or that should be corrected

### 3.1 `.poweredOff` does **not** invalidate peripherals — the edge-case row is wrong, and the relink path breaks (CONFIRMED, most important finding)

The D-7 row "Demand present but radio drops to `.poweredOff` → `invalidatePeripherals` clears CB
state; demand is preserved; `reevaluateLink` re-runs when the radio returns (event 12)" is
disproved by `handleCentralManagerStateUpdate` (:849–:853): `.poweredOff` and `.unknown` are the
explicit *do-not-invalidate* branch; only `.resetting`/`.unsupported`/`.unauthorized` invalidate.
Consequence under the plan as written: radio cycles off→on with no invalidate; `connectionStates`
still says `.connected` for the (dead) link; event 12's `reevaluateLink` hits "Already
`.connected` → `syncReconnectIntent` only" and **never re-issues the connect**. The manual
on-device check the plan lists ("toggling Bluetooth off during an active work-driven link…
re-links on return") would fail. Correction — pick one and state it:

- (a) Add `.poweredOff` to the invalidate triggers (with event 13's demand-preserving semantics),
  or
- (b) keep `.poweredOff` non-invalidating but make `reevaluateLink`'s "already connected" arm
  verify `cbPeripherals[id]?.state == .connected` rather than trusting `connectionStates`.

(a) is simpler and matches event 13's design; note it also emits
`.disconnected(reason: .bluetoothUnavailable)` per `clearConnectionStates` (:1157), which is the
right app-visible signal for a radio-off drop. Either way, this is **automatable now** — the mock
supports `simulatePowerOff`/`simulatePowerOn` (existing tests use it, e.g. around
`ReliaBLEManagerTests.swift:315`) — so promote the "toggle Bluetooth during a work-driven link"
item from manual-only to a named test (e.g. `demandSurvivesRadioCycleAndRelinks`).

### 3.2 `invalidatePeripherals` wipes the persisted intent set

`invalidatePeripherals` (:993) does `reconnectEnabled.removeAll()` **then**
`persistReconnectIntent()` (:1000), writing an empty array to UserDefaults. Under the plan's new
semantics (persisted set = "last Manual connect wanted reconnect"), a transient `.resetting`
blip erases the persisted Manual-session intent; if the process dies before the radio returns,
it is gone across relaunch. Event 13 lists what invalidate must *preserve* (`workCount`,
`manualConnectHold`) but says nothing about persistence. Correction: invalidate must not write the
persisted set (drop the `persistReconnectIntent()` call there); with `syncReconnectIntent` as the
sole writer (§2.5), the set self-heals from demand anyway.

### 3.3 The `issueConnect` extraction must strip side effects — the invariant is otherwise achievable (CONFIRMED)

Verified: `centralManager.connect` has exactly one call site today (`connect`, :1095); the restore
path never issues connects (comment at :764: "Do not reconnect here"); `performReconnect` (:1305)
reaches CB via `connect(id:autoReconnect: true)`. So the plan's invariant is achievable. But the
plan should state explicitly that `issueConnect` carries **none** of `connect`'s current side
effects — today's body mutates `reconnectEnabled` (:1083–:1085), calls `persistReconnectIntent()`
(:1087), and clears `intentionalDisconnects` (:1088). If `performReconnect` routed through an
un-stripped extraction, every ladder attempt of a *work-driven* link would persist reconnect
intent, violating D-4's hold-driven-only persistence rule. `issueConnect` should be: optimistic
`.connecting` + options + `centralManager.connect`, nothing else.

## 4. Problems absent from BOTH the export and the plan

### 4.1 Double-release detection is impossible with the declared bookkeeping

Both documents promise "releasing an unknown or already-released token is a no-op" but declare
only `workCount: [String: Int]`. A refcount cannot recognize an already-released token:
`max(0, current - 1)` only protects at zero. Acquire two leases, release token A twice →
`workCount` hits 0 while lease B is live → idle grace tears down a link that still has work. The
`WorkLeaseToken.leaseID: UUID` exists precisely to prevent this but nothing stores it. Correction:
track `activeLeases: [String: Set<UUID>]` (derive `workCount` as `activeLeases[id]?.count ?? 0`,
or keep both in lockstep); `releaseWorkLease` no-ops unless it removes the token's UUID. The
`doubleReleaseIsNoOp` test as named would pass under the broken refcount if only one lease exists —
write it with **two** leases held.

### 4.2 Lease holders have no failure signal

`acquireWorkLease` returns a token after issuing (not completing) the connect. If the connect
fails and the ladder exhausts, the lease holder learns nothing — the only signal is the
connection-state stream. Acceptable for an internal Phase-2 primitive whose consumers are tests,
but the plan should say so explicitly, and note for Phase 3 that the command queue will need an
*await-linked* primitive (or per-command failure delivery) layered on the lease — otherwise
`ensureLinked`'s fire-and-forget shape gets baked into the queue design by accident.

### 4.3 `cancelPeripheralConnection` callback guarantees are load-bearing and unverified

Three plan paths assume a cancel produces a terminal delegate callback: `fireIdle`, the
untrusted-Tier-0 branch (§2.2), and idle-grace-during-`.connecting` (the "last lease released
while `.connecting`" row). CoreBluetooth's documented behavior for cancelling a *pending* connect
or an OS-reconnecting link does not guarantee `didDisconnect` in all cases; the mock's behavior is
a separate question (the plan's existing unknown). If no callback arrives, `.disconnecting` is
terminal-but-wrong and `intentionalDisconnects` leaks. Broaden the unknowns table entry from
"mock behavior during `isReconnecting`" to "callback guarantees for cancel during pending
connect / OS-reconnect, mock **and** device", and give every optimistic `.disconnecting` a
settlement rule.

### 4.4 Resumed waiters act on possibly stale state

`resolvePoweredOnWaiters` resumes continuations from the state handler, but the resumed caller's
code (issuing `scanForPeripherals`, `issueConnect`) runs at some later actor turn — by which time
the radio may have flipped again. D-1 event 5 says the gate is "re-checked cheaply" for the
connect path, but the scan path has no such statement, and D-2's call-site table shows scan
proceeding directly after the wait. Add: every resumed waiter re-checks `centralManager.state`
before acting and re-parks (or throws, per D-radio) on regression. Related: when a restored scan
(`pendingRestoredScanServices`) and an awaited `startScanning` both fire at `.poweredOn`, both
call `scanForPeripherals` and last-writer-wins on the single CB scan — state which filter wins
(app-requested should; say so) as part of resolving the plan's existing `resumeRestoredScan`
unknown.

## 5. The persisted-intent question (user-requested assessment): reduce to write-side only

The plan flags the mechanism as "close to inert" and says keep-but-document. The code says it is
worse than inert — it is **self-erasing**, and the read side is provably dead:

- Restore seeds `reconnectEnabled` from the persisted set (:768–:777). But `armReconnect` now
  gates on `wantsReconnect(id)` — derived from `workCount`/`manualConnectHold`, both empty at relaunch —
  so a seeded entry can never arm the ladder. The seeded entry is also outside `syncReconnectIntent`'s
  derivation, so the first demand change for that id removes it and **clears the persisted record**.
- Independently, D-restore guarantees the restored link idles out; `fireIdle` "runs the existing
  intentional-cancel path", which today removes the id from `reconnectEnabled` and calls
  `persistReconnectIntent()` (:1122–:1123) — wiping the persisted entry on the very first restore
  cycle. The plan's own "load-bearing again in Phase 3" claim cannot survive this: by the time a
  Phase-3 restored queue exists, the set is always empty.
- And Phase 3 does not actually need the read: a restored command queue creates work leases, which
  drive `wantsReconnect` by themselves; a re-declared hold passes `autoReconnect` explicitly. The
  only hypothetical consumer of restored intent was the hold re-application that D-restore
  (correctly) forbids.

**Recommendation — reduce, don't keep or remove:** keep the UserDefaults write path (in
`syncReconnectIntent`, hold-driven only, per §2.5/§3.2 so it stops being wiped by invalidate and
idle teardown), and delete the restore-time read into `reconnectEnabled` (:741–:777's
`persistedIntent` branchs) plus the now-dead `willRestoreSeedingReconnectOnlyForConnectedOrConnecting`
/ `willRestoreDoesNotRearmReconnectWithoutPersistedIntent` test expectations. This honors the user
decision — no manual-connect hold is restored, and the persisted *record* of intent survives for Phase 3 — while
removing read-side code whose only remaining behavior is to be erased. If the read is kept
instead, the plan must add exemptions so seeded entries are neither removed by the first
`syncReconnectIntent` nor wiped by idle teardown — more mechanism for zero Phase-2 behavior.

## 6. Questions that would materially change the design

1. **Does a `reconnectDesired: false` hold count as re-issue demand after an unexpected drop or
   radio cycle, or only as idle suppression?** (§2.1 — changes `reevaluateLink`'s gate and the
   untrusted-Tier-0 branch.)
2. **What terminal state settles a cancel that never produces a delegate callback** (pending
   connect, OS-reconnect limbo)? (§2.2/§4.3 — determines whether `.disconnecting` needs a
   watchdog or a synchronous settle.)
3. **On `.poweredOff`, invalidate-with-demand-preservation or verify-CB-state-in-`reevaluateLink`?**
   (§3.1 — decides whether event 13 gains a fourth trigger or event 5 changes its "already
   connected" check; affects which tests are writable.)
4. **Where do `reevaluateLink` errors surface in delegate contexts** — log-and-drop or
   `.failed(reason:)` on the stream? (§2.4 — determines whether a stranded work lease is
   observable.)
5. **Should `stopScanning` cancel parked scan waiters?** (§2.7 — small, but it is public API
   behavior and must be documented either way.)

None of these block starting commits 1–3 (config, errors, PoweredOn await); questions 1–4 should
be settled before commit 4 (demand substrate) and 6 (gating/restore), where their answers change
code shape.

## Spot-check answers (requested)

| Check | Result |
|-------|--------|
| `handleDidDisconnect` redesign loop-safety | **No cancel/reconnect loop** in the specified branches: untrusted-Tier-0 requires `!wantsReconnect` ⇒ `workCount == 0`, so its follow-up intentional disconnect cannot trigger the relink branch; the intentional-relink branch issues at most one connect per disconnect. But the branch is under-specified (§2.2) and the `reconnectDesired:false` hold breaks it (§2.1). |
| `invalidatePeripherals` preserving `workCount`/`manualConnectHold` | **Safe for CB state**: `cbPeripherals.removeAll()` + `clearConnectionStates()` (which nils the registry mirror and emits `.disconnected(.bluetoothUnavailable)`) compose fine with preserved demand, and `refreshPeripherals` re-fills from the retained `discoveredPeripherals`. **Unsafe for persistence** (§3.2) and needs a `notFound` story on relink (§2.4). |
| `startScanning` throwing vs `resumeRestoredScan` deferral | **No conflict** — the deferral is internal and stays non-throwing. Interaction gap is filter precedence + stale-state re-check when both fire at `.poweredOn` (§4.4); the plan's existing unknown should absorb both. |
| `centralManager.connect` exactly once | **Achievable** — single call site today (:1095); restore never connects; `performReconnect` routes through `connect`. Requires the side-effect-free `issueConnect` extraction (§3.3). |
| Persisted intent inert under D-restore? | **Worse — self-erasing, read side dead.** Reduce to write-side only (§5). |

## Consistency with the four fixed decisions

- **One PR** — consistent throughout (D-deliv, implementation order, issue map).
- **poweredOff fails fast** — consistent in D-2, D-7, D-8, and the test table; the export's
  contrary rows are all overridden. No stragglers found.
- **Internal-only work primitive** — consistent (D-work, D-5, issue map shows no public delta for
  #60).
- **Restore = intent only, never a hold** — consistent in D-restore, D-7, DocC rows, and tests;
  the follow-through gap is that the restored intent is then erased before it can ever matter
  (§5), and event 13/`.poweredOff` handling (§3.1, §3.2) undermines the "demand survives radio
  loss" half of the same story.
