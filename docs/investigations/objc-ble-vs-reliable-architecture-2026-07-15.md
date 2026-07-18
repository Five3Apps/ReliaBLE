# Investigation: ObjC BLE Architecture vs ReliaBLE

**Updated:** 2026-07-15  
**Includes:** PR #47 (FR-10), product feedback on layering / connections / Peripheral API / concurrency

## Summary

ReliaBLE is the modern, improved equivalent of the ObjC **Core** layer (`CCBTCentralManager` / `CCBTPeripheral` / `CCBTCommand`). The reference protocol facade and app layers are **usage context**, not something ReliaBLE should re-implement. The PRD is the v1 target; the library is unshipped and not intended for use before PRD completion.

**Shipped code today** is a strong **link manager** (scan, multi-device connect, two-tier reconnect, lifecycle streams, background restore). The ObjC reliability moat was **PoweredOn gate → demand-driven connect → discovery readiness → serial command queue → pause/reconnect/rerun**. PR #47 specifies the discovery gate (FR-10). Commands (FR-4/5) follow FR-10. Product direction re-centers **work-driven connection as the only primary model**: non-empty command queue drives auto-connect; idle teardown when the queue is empty. Reconnect is **Approach B**: Tier-0 (OS) enabled while the work-driven link is up, cancelled on idle teardown; Tier-1 armed only while work is pending. Explicit `connect()`/`disconnect()` is an **Advanced app-hold** path (rarely used), not an either-or policy mode. Public device model is **two types**: long-lived **`Peripheral`** (control handle; primary for wearables/IoT) and value **`DiscoveredPeripheral`** (scan snapshot; manager-stamped `.peripheral` sugar). Not `manager.connect(id:)` as the primary API. See also `docs/designs/discovered-peripheral-vs-peripheral-2026-07-15.md`.

**Full PRD + agreed product direction clears (and in places exceeds) the ObjC Core bar**, provided FR-10, work-driven default, and command reconnect-and-rerun actually ship. Framing/CRC stay app-owned by design (OSS multi-device).

---

## Product decisions (from feedback)

| Topic | Decision |
|---|---|
| **Layering** | ReliaBLE = modern Core only. Protocol/app layers in ObjC are context for how Core is consumed. |
| **Connection model** | **Work-driven only as the primary path:** auto-connect when the command queue is non-empty; idle teardown when empty. **Reconnect Approach B:** work-driven connects pass Tier-0 (OS auto-reconnect) while linked; idle teardown / intentional cancel drops OS reconnect; Tier-1 armed only while queue non-empty (exact “no work ⇒ no library ladder”). Explicit `connect(autoReconnect:)` / `disconnect()` is **Advanced app-hold** (docs only; rarely used): same ensure-linked path, suppresses idle while held; `autoReconnect` Bool remains on explicit `connect`. **No either-or `ConnectionPolicy.mode`.** |
| **Connect API placement** | Hang connect / discovery / commands off **`Peripheral`** (long-lived handle), matching ObjC `CCBTPeripheral` / `runCommand:` ergonomics — not only `ReliaBLEManager.connect(to:)`. |
| **Public device types** | **`Peripheral`** = control handle (stable id, sticky discovery filter, ready, queue, Advanced connect, last-seen metadata). **`DiscoveredPeripheral`** = scan snapshot (ads/rssi); manager-stamped; **`discovered.peripheral`** sugar → interned handle. Leave **`Device`** free for multi-transport app layers. |
| **Known id / “my devices”** | App obtains `manager.peripheral(id:)` up front; discovery later binds live CB to the same handle. Primary UI for IoT = tracked **`Peripheral`s** (option A: last discovery metadata on the handle). Raw discovery stream = scanner/provisioning. No fake placeholder discoveries. Optional later: thin `PeripheralUpdate` event (option B). |
| **Discovery API (GATT FR-10)** | On **`Peripheral`**, not a global id-keyed manager API. |
| **UUID declaration** | Sticky on **`Peripheral`** (e.g. `discoveryFilter`); required before auto-discovery / first work (fail-closed if empty). |
| **Commands** | Not before FR-10. |
| **Target devices** | Wearables, IoT sensors, smart-home (“my devices” first). Always-connected notify is **not** a primary use case. Scanner apps secondary. |
| **Maturity** | Unshipped; PRD = v1 target; no pre-PRD production use. |
| **Idle disconnect** | Global config (not per-peripheral); default **5s**. |
| **Ready vs subscriptions** | Default ready = **catalog-ready**. Subscriptions = explicit intent + re-arm (FR-10.4); not auto-enable-all-notify; commands needing notify await those UUIDs. |

---

## Hypotheses

1. ReliaBLE Core should match ObjC Core guarantees with Swift 6 mechanisms — **confirmed as intent**.
2. Current code implements connection/scan foundations; discovery (FR-10) and commands (FR-4/5) are greenfield — **confirmed**.
3. Work-driven connection was the original plan; manager-level `connect` was a placeholder detour — **confirmed by feedback**.
4. FR-10 is the required middle layer before commands — **confirmed (PR #47 + feedback §4)**.
5. Full PRD + product direction clears ObjC Core reliability bar — **yes, with gaps noted in §5**.

---

## Background

- ObjC docs: `Bluetooth/docs/BLE-Architecture.md`, `Swift6-Translation.md`
- ObjC Core: `CCBTCentralManager`, `CCBTPeripheral`, `CCBTCommand`
- ReliaBLE: `PRD.md` (incl. FR-10 from PR #47), `Sources/ReliaBLE/*`, DocC
- Product feedback: layering, PoweredOn, work-driven + Advanced hold (Approach B reconnect), Peripheral-scoped APIs, PRD bar, actor layout

---

## 1. Layering

### Intent (product)

ReliaBLE **is** the modern Core. Mapping:

| ObjC Core | ReliaBLE (target) |
|---|---|
| `CCBTCentralManager` | Central concerns on `ReliaBLEManager` + internal `BluetoothActor` (scan, radio state, multi-device registry) |
| `CCBTPeripheral` | **`Peripheral`** handle (work-driven link, discovery/ready, command queue, idle teardown, optional app-hold, last-seen metadata) |
| *(scan row / ads)* | **`DiscoveredPeripheral`** value snapshot + `.peripheral` sugar |
| `CCBTCommand` | App-supplied command protocol executed by **`Peripheral`** (FR-4/5, after FR-10) |

ObjC protocol facade (`CCLDBand*`, packets, CRC) and app UI are **consumers of Core** — useful for understanding ergonomics and end-to-end reliability, not library scope. Framing stays with the integrating app (FR-4.1).

### Current code vs intent

- Shipped: central/scan/connect-on-manager + connection streams.
- Missing Core pieces: `Peripheral` as control handle (today’s type is a snapshot), `DiscoveredPeripheral` rename/split, FR-10, command queue, work-driven default.
- Placeholder smell: `ReliaBLEManager.connect(to:)` as the only connection entry point; today’s `Peripheral` is the wrong shape for control methods.

### Pros / cons of pure-Core scope

| | Pros | Cons |
|---|---|---|
| Core-only (ReliaBLE intent) | Multi-device OSS; no vendor framing; clear package boundary | Apps supply protocol; library must still ship discovery + command *machinery* so reliability isn’t N× reinvented |
| Core + protocol (ObjC full stack) | One-liner domain API for one device family | Not a general package |

**Verdict:** Scope is right. Success metric is **ObjC Core parity (or better)**, not device-specific band-protocol parity.

---

## 2. Connections

### 2.1 ObjC model (evidence)

| Mechanism | Evidence |
|---|---|
| Demand-driven connect | Side effect of `runCommand:` when disconnected — `CCBTPeripheral` / architecture §2.2 |
| Idle disconnect | 5 s after queue empty while connected |
| Retry budget + 5 s connect timeout | `CCBTPeripheral` constants / timers |
| PoweredOn gate | Central `commandOperationQueue` created suspended (`CCBTCentralManager.m:45`); unsuspend only on PoweredOn (`m:214-218`); **scan and connect ops are enqueued on that queue** (`searchForPeripherals` `:155-156`, `connectToPeripheral` `:177-184`) |
| Explicit connect exists lower-level | `connectToPeripheral:options:` on central — used by peripheral’s auto-connect path, not the app’s primary API |

### 2.2 ReliaBLE today

| Mechanism | Status |
|---|---|
| Explicit `manager.connect` / `disconnect` | Done (placeholder path) |
| Two-tier reconnect + streams + restore | Done (ahead of ObjC) |
| PoweredOn: scan no-op; connect throws if no central | Different from park |
| Work-driven + idle teardown | Absent (original plan; product wants as default) |

### 2.3 PoweredOn park-until-ready vs fail/no-op — deep dive

#### What ObjC actually parks

Not “all BLE forever,” but **central operations submitted to `commandOperationQueue`**: primarily **scan** and **connect/cancel-connect**. The queue starts suspended and only runs when `central.state == PoweredOn`. If state leaves PoweredOn, the queue re-suspends. Terminal bad states (unauthorized / powered off / unsupported, after Resetting) **fail outstanding search completions** rather than parking forever (`CCBTCentralManager.m:220-231`).

So park is: *“hold radio work until the radio can do it; fail terminal unrecoverable states.”*

#### Is it only useful at initial boot?

**No.** Boot is the *most common* case, but not the only one.

| Scenario | Park / await-ready | Fail / no-op |
|---|---|---|
| **Cold start** — app launches, CB still `.unknown`/`.resetting`, user (or code) starts scan/sync immediately | Work runs when PoweredOn; no app retry loop | App must observe `state` and re-issue scan/connect |
| **Authorize-then-work** — user grants permission, central becomes usable moments later | Natural fit with lazy central: first work waits for PoweredOn | Race: first call throws/no-ops if app doesn’t sequence carefully |
| **User toggles Bluetooth off then on mid-session** | ObjC re-suspends queue on non-PoweredOn; when On again, parked ops can proceed (if still queued). In-flight peripheral work has its own disconnect path | ReliaBLE today: scan no-ops; app must notice `state` and restart scan. Connect throws if central missing |
| **iOS radio reset / brief `.resetting`** | Park absorbs blip for newly submitted central ops | Flaky “why didn’t scan start?” unless app retries |
| **Background relaunch + restore** | Await PoweredOn before re-scan / re-connect intent is cleaner | Fail-fast forces restore path to carefully order setup |
| **User intentionally left BT off; app keeps submitting work** | Risk: silent queue of stale work (ObjC mitigates for search via fail on terminal states; still can surprise) | Better UX: immediate error → prompt “Turn on Bluetooth” |
| **UI that shows BT status and disables Sync** | Park less necessary; UI already gates | Fail-fast matches UI |
| **Work-driven Core (wearable sync)** — app only calls `run(command)` | **Park (or `await ready`) is essential** so Core can hide radio readiness | Forces every call site to handle “not ready” |

#### ReliaBLE’s current fail/no-op specifically

- **Scan** (`BluetoothActor.swift:503-506`): if not PoweredOn → log warn, **return** (silent no-op from app’s perspective aside from logs).
- **Connect**: throws `bluetoothUnavailable` if no central — **fail-fast**, not no-op.
- **State stream**: app *can* observe PoweredOn and retry — good for UI, boilerplate for work-driven Core.

Silent scan no-op is the weakest variant: neither “park until ready” nor a clear error.

#### Recommendation for ReliaBLE Core (aligned with product)

For a **work-driven default** targeting wearables/IoT:

1. **Prefer await/park semantics for work submission**, not silent no-op:
   - `await waitUntilPoweredOn()` (or equivalent) inside scan / connect / `run(command)` paths.
   - **Throw promptly** on terminal states: unauthorized, unsupported, poweredOff if policy says don’t wait forever (configurable timeout optional).
2. **Keep the `state` stream** for apps that want UI gating — observability and park are complementary, not alternatives.
3. **Avoid silent no-op** for scan; either await PoweredOn or throw `bluetoothNotReady`.

| Prefer await/park when… | Prefer fail-fast when… |
|---|---|
| Default Core path: app submits work without managing radio | Settings/debug UI; user must turn BT on now |
| Transient `.unknown` / `.resetting` / post-authorize | Policy: never queue work while powered off |
| Work-driven + multi-step command chains | Tests asserting immediate errors |

**Swift 6 shape** (from `Swift6-Translation.md:76-100`): parked work is a suspended `await`, not an `NSOperationQueue.suspended` flag — same product behavior, better structured cancellation/timeouts.

### 2.4 Work-driven link + Advanced app-hold (no either-or policy)

**Product decision (KISS):** one connection state machine. The primary model is ObjC-style work-driven. Explicit connect is not a second “mode” — it is an optional **app hold** on the same machine.

**Target devices** (wearables, IoT sensors, smart-home): sessions are “do a job,” not always-connected notify. Always-connected notify is out of primary scope; app-hold is documented under **Advanced** and expected to be rare.

#### Rules

| Signal | Meaning |
|---|---|
| **Command queue non-empty** | Reason to be linked: auto-connect if down; Tier-0 enabled at that connect; Tier-1 armed on unexpected drop |
| **Command queue empty** | Disarm Tier-1; start idle teardown timer (if no app hold) — cancel connection ends Tier-0 |
| **App hold** (Advanced) | Set by `connect(autoReconnect:)`; cleared by `disconnect()`. Suppresses idle teardown while held. Same ensure-linked path as work-driven connect |
| **Idle teardown** | Runs only when **queue empty and no app hold**; cancel connection drops OS Tier-0 |

```text
ensureLinked()  ← called from run(command) and from Advanced connect()
  await PoweredOn
  connect if needed  // work-driven: pass Tier-0 EnableAutoReconnect (Approach B)
  discover to ready (FR-10)

on unexpected disconnect:
  if queue non-empty OR (app hold && autoReconnect):
    arm Tier-1 ladder   // exact “work pending ⇒ library reconnect”
  else:
    stay down           // no Tier-1 when quiet

on queue drained && !appHold:
  disarm Tier-1
  start idle timer → cancel connection  // cancels Tier-0 as well

on Advanced connect(autoReconnect:):
  set appHold; ensureLinked()
  Tier-0 / Tier-1 follow the autoReconnect Bool while hold remains

on Advanced disconnect():
  clear appHold; intentional cancel; disarm reconnect
```

#### Reconnect: Approach B

| Path | Tier-0 (OS `EnableAutoReconnect`) | Tier-1 (library ladder) |
|---|---|---|
| **Work-driven** (default) | **On while linked** — passed at auto-connect for work; **dropped when idle teardown (or intentional cancel) cancels the connection** | **On only while queue non-empty** (mid-job drop with work remaining) |
| **Advanced `connect(autoReconnect: true)`** | On for that hold | Armed while app hold remains |
| **Advanced `connect(autoReconnect: false)`** | Off | Off for that hold |
| **Queue empty, no hold** | Ended by cancel on idle teardown | **Disarmed** |

Rationale: Tier-0 is fixed at connect time and cannot track “queue just emptied” without cancelling. Approach B keeps OS help **during an active job** (link is up for work) and relies on **idle teardown cancel** to end Tier-0 when the queue is quiet. Exact “no work ⇒ no library reconnect” stays on **Tier-1** (arm/disarm from queue). Accepted gap: during the idle grace window (e.g. 5s after last command) Tier-0 might still bring the link back once with an empty queue — then idle logic should cancel again if still quiet and no hold. KISS: do not re-`connect` to flip options when the queue toggles.

#### Docs shape

- **Primary docs / Getting Started:** only `run(command)` (after FR-10/4); connection is an implementation detail.
- **Advanced:** `connect(autoReconnect:)` / `disconnect()` as app hold — keep link up without pending work; `autoReconnect` semantics as today.

**Complexity:** one ensure-linked path + `appHold` + `queuedWork` flags + idle cancel. No `ConnectionPolicy.mode` enum.

### 2.5 Public types: `Peripheral` (handle) + `DiscoveredPeripheral` (snapshot)

**Settled.** Two public layers are required under Swift 6 (list-safe scan values vs long-lived control). Naming puts Apple’s noun on the control object.

| Type | Kind | Role |
|---|---|---|
| **`Peripheral`** | Long-lived handle (interned by id in the manager) | Primary app type for wearables/IoT: sticky `discoveryFilter`, work-driven `run`, ready/connection streams, Advanced `connect`/`disconnect`, last-seen / last-advertisement metadata (option A) |
| **`DiscoveredPeripheral`** | Sendable value snapshot | Scan row: ads, rssi, lastSeen; **manager-stamped**; **`discovered.peripheral`** → same interned handle |
| **`ReliaBLEManager`** | Façade | Auth, scan, registry, `peripheral(id:)`, tracked-peripherals feed |

**Why not methods on today’s snapshot-only `Peripheral`:** that type was built as an immutable discovery row. Control needs stable identity across ads, queue, filter, hold. Renaming the snapshot to `DiscoveredPeripheral` and making **`Peripheral` the handle** keeps one primary noun for implementers.

**Why not `Device`:** leave free for multi-transport app models (BLE + Matter + Wi‑Fi).

**Known id:** `manager.peripheral(id:)` creates/returns handle before any scan; matching discovery binds live CB. No library fake discoveries for UI — “my devices” = tracked handles; “nearby” = real `DiscoveredPeripheral` stream.

**Option A now / B later:** enrich `Peripheral` with last discovery metadata for IoT lists; optional later thin `PeripheralUpdate` stream payload without a third control type.

Full write-up for external review: `docs/designs/discovered-peripheral-vs-peripheral-2026-07-15.md`.

**Verdict:** Demote manager-only connect; device-centric API on **`Peripheral`**; scan sugar via **`DiscoveredPeripheral.peripheral`**.

---

## 3. Discovery & readiness (FR-10)

### ObjC

Discovery **gates the per-peripheral command queue** (queue created suspended; unsuspend after services + characteristics; `didModifyServices` re-suspends and rediscovers). App doesn’t call “discover” as a global API — it’s part of the device becoming usable for `runCommand:`.

### PRD (FR-10)

Discovery is a **reliability gate**, not a catalog: **connected ≠ ready**. Filtered UUIDs, state machine, distinct readiness stream, timeout, fail-closed missing UUIDs, subscription intent re-arm, re-discover every connection, restore re-discover, document OS GATT cache limits. All greenfield in code.

### Product API placement

**GATT discovery / ready / subscriptions hang off `Peripheral`**, not `manager.discover(id:)`:

```text
// Known / bound device (primary IoT path)
let p = manager.peripheral(id: "user-lock-42")
p.discoveryFilter = ...                    // sticky; fail-closed if empty when work needs discovery
try await p.run(MyCommand())               // ensureLinked → discover → ready → run

// Scanner path
for await d in manager.peripheralDiscoveries {
    let p = d.peripheral                   // sugar → interned handle
    // ...
}

// Advanced hold
try await p.connect(autoReconnect: true)
```

UUID declaration (FR-10.1.2) is sticky on **`Peripheral`**.

**Verdict:** FR-10 requirements stand; surface them on **`Peripheral`**. Actor isolation still owns CB objects (see §6).

---

## 4. Commands & queues

**Will not be implemented prior to FR-10** (product).

Target after FR-10:

- Serial-per-peripheral FIFO (ObjC one-wide) as MVP.
- App-owned command content (FR-4.1); target characteristics by UUID; **inherit ready gate** (don’t re-litigate discovery in the queue).
- Reconnect-and-rerun after **ready**, not merely after link-up (FR-1.2 / FR-10.6).
- FR-5.2 deps/priority **after** serial + rerun work — avoid over-build.

API: `device.run(command)` (or equivalent), not manager-global.

---

## 5. Reliability — does the full PRD clear the ObjC bar?

### ObjC Core guarantees (the bar)

| Guarantee | ObjC mechanism |
|---|---|
| Don’t run radio work before PoweredOn | Suspended central op queue |
| Don’t run commands before GATT known | Peripheral queue suspended until discovery |
| Work-driven link + idle teardown | `runCommand` → connect; idle timer |
| Mid-transfer drop recovery | Pause → reconnect → rediscover → resume/rerun |
| Exactly-once completion | Command completion contract |
| Step timeouts | Watchdog (resettable for streams) |
| Serialized work per device | One-wide queue |
| Protocol integrity | Protocol layer CRC (above Core) |

### Full PRD (incl. FR-10) vs bar

| ObjC Core guarantee | Full PRD coverage | Clears bar? |
|---|---|---|
| PoweredOn gating | Not explicit as park/await; state stream exists | **Partial** — should specify await/park for work submission (product §2.3) |
| Discovery readiness gate | **FR-10.3** (stronger: streams, timeout, fail-closed, distinct from connection) | **Yes — exceeds** |
| Re-discover on reconnect / modify | **FR-10.5 / 10.6**, FR-1.2 amended | **Yes — exceeds** (restore + subscription intent) |
| Work-driven + idle; Approach B reconnect (Tier-0 while linked, cancel on idle; Tier-1 while queue non-empty) | Not yet first-class in PRD | **Gap** — product model; document work-driven + Advanced hold; Approach B |
| Serial command queue | FR-5.2.1 FIFO | **Yes** |
| Reconnect-and-rerun commands | FR-1.2 + FR-4/5 depend on ready | **Yes if implemented** as retry-after-ready |
| Exactly-once + watchdogs | FR-1.1 / implied | **Yes if specified tightly in command design** |
| Multi-device concurrent | FR-5.1 | **Yes — exceeds** ObjC practical focus |
| Connection observability | FR-1.3.1 | **Exceeds** (streams, reconnect sources) |
| Background / restore | FR-8.3, FR-10.6.3 | **Exceeds** |
| CRC / framing | App-owned FR-4.1 | **Different bar** (correct for OSS Core) |

### Verdict

**Yes — the full PRD target clears the ObjC Core reliability bar**, and exceeds it on discovery observability, restore, multi-device, and connection recovery — **if** implementation follows FR-10 → commands with retry-after-ready, and product adds:

1. Work-driven link + idle teardown; Approach B reconnect (Tier-0 while linked, cancel on idle; Tier-1 only while queue non-empty); Advanced app-hold `connect`/`disconnect` only.
2. Await/park (not silent no-op) for PoweredOn on work paths.
3. Device-handle API so the Core is usable without re-learning CB.

Without those, PRD still beats “connection-only ReliaBLE” on paper via FR-10/4/5, but would miss ObjC’s **ergonomic** reliability (app never manages the link).

Framing/CRC: ObjC protocol layer is **out of Core scope**; apps can still meet or beat band integrity. Core’s job is not to own packet formats.

---

## 6. Concurrency — one actor vs per-device actors

### Question

Should discovery state machines and readiness streams live on **new actors**, or stay on a **single `@BluetoothActor`** with one CB delegate shim?

### Constraints

- `CBCentralManager` / `CBPeripheral` / `CBService` / `CBCharacteristic` are **not Sendable**.
- CoreBluetooth delivers callbacks **serially on the queue you pass at init** (ReliaBLE already uses a dedicated queue + shim → actor hop).
- Actor isolation **≠** FIFO across `await` (reentrancy): a per-device command gate is still required even inside one actor (`Swift6-Translation.md:112-118`).

### Recommendation: **single Bluetooth isolation domain; per-device state machines as data, not separate actors holding CB objects**

```text
ReliaBLEManager (nonisolated, Sendable façade)
        │
        ▼
@BluetoothActor  (sole owner of all CB* objects + registry)
  - central, scan, reconnect ladders
  - devices[id]: DeviceState
        readiness, discovery SM, command FIFO gate,
        subscription intent, idle timer bookkeeping
        │
        ▼
Public DeviceHandle (Sendable id + thin async façade)
  - forwards connect/run/discovery streams → actor
```

| Approach | Pros | Cons |
|---|---|---|
| **Single `@BluetoothActor` + per-id state** | One place for non-Sendable CB refs; one shim; matches CB’s single serial queue; simpler restore; FR-10 SM is just state | Actor can become large; need disciplined `DeviceState` types |
| **Actor per peripheral holding CBPeripheral** | Attractive modularity | **CBPeripheral not Sendable** — illegal/unsafe without shared executor hacks; multi-actor hops on every notify |
| **Peripheral actor that only holds `id`, central owns CB** | Mental model of “peripheral actor” | Extra hops; still need central for all CB calls; easy to pretend isolation you don’t have |
| **Custom executor shared with CB queue** | Callbacks already on actor | More plumbing; optional later if profiling demands |

**Discovery SM + readiness streams:** implement as **per-device state inside `@BluetoothActor`**, exposed via handle-scoped `AsyncStream`s (each subscriber gets a stream filtered/keyed by device). That is *not* overcomplicating — it’s the minimum that respects Sendable. Separate actors per device **for CB ownership** would overcomplicate and fight the type system.

Command FIFO: explicit gate per device id inside the actor (semaphore/queue), not “actor isolation alone.”

---

## 7. Multi-device, scan, background (brief)

- ReliaBLE **ahead** on multi-connection substrate, connection streams, OS auto-reconnect, state restoration (link level).
- FR-10.6.3 extends restore to re-discover + re-arm subscriptions — required for Core parity after FR-10.
- Scan stays on manager; post-connection lifecycle on device handle.
- FR-8.5 identity still open; FR-10.6.2 keys catalog by `Peripheral.id`.

---

## 8. Security & framing

- Library: link + discovery + command lifecycle + subscription setup.
- App: packet bytes, CRC, domain protocol (FR-4.1).
- FR-6 security modes: still PRD-future; not required to clear ObjC Core bar (ObjC Core didn’t own them either).

---

## Parity matrix (Core-focused)

| ObjC Core capability | PRD / product target | Code today |
|---|---|---|
| Central scan + PoweredOn gate | Await/park on work paths (recommend PRD note) | Scan no-op; partial |
| `Peripheral` handle + `DiscoveredPeripheral` snapshot | **Product: yes** (option A metadata on handle) | Today single snapshot type + manager.connect |
| Work-driven connect + idle teardown | **Product: primary** | Absent |
| Advanced app-hold `connect`/`disconnect` | **Product: Advanced docs; rare** | Only path today (to be demoted) |
| Work-driven: Tier-0 while linked + cancel on idle; Tier-1 while queue non-empty | **Product: Approach B** | Today two-tier on manager connect; not yet queue/idle-gated |
| Two-tier reconnect + streams (Advanced hold / general substrate) | Exceeds ObjC | **Done** (wire to queue/hold rules) |
| Discovery readiness gate | FR-10 | Absent |
| Ready stream on device | FR-10.3.2 + product | Absent |
| Subscription intent re-arm | FR-10.4.5 | Absent |
| didModifyServices re-gate | FR-10.5 | Absent |
| Serial command queue | FR-5.2 (after FR-10) | Absent |
| Reconnect-and-rerun after ready | FR-1.2 + FR-4/5 | Absent |
| Background restore (link) | FR-8 / config | **Done** |
| Restore → rediscover/resubscribe | FR-10.6.3 | Absent |
| App-owned framing | FR-4.1 | N/A until commands |
| Swift 6 single CB actor | Product §6 | **Done** (manager façade) |

---

## Risks

1. Shipping GATT/commands without device-handle + ready gate → CB-shaped API, races ObjC already fixed.
2. Leaving scan as silent no-op while marketing work-driven Core → mysterious “sync did nothing.”
3. Implementing full FR-5.2 priority before serial + ready + rerun.
4. Per-peripheral actors holding CB objects → Sendable / ownership bugs.
5. Treating Advanced `connect` as a second connection stack instead of app-hold on one machine.
6. PRD/docs not updated for work-driven primary → implementers treat manager.connect as the “real” API.
7. Enabling Tier-0 on work-driven connects **without** idle/intentional cancel → OS reconnects indefinitely with empty queue (violates Approach B). Idle grace may allow one OS reconnect; must re-cancel if still quiet.

---

## Recommendations

### PRD / design updates

1. Document **work-driven primary path**: auto-connect on non-empty command queue; idle teardown when empty; **Approach B reconnect** — Tier-0 while linked (cancel on idle), Tier-1 only while work pending. Idle duration as a simple config default (e.g. 5s), not a mode enum.
2. Document **Advanced app-hold**: `connect(autoReconnect:)` / `disconnect()` suppress idle while held; existing `autoReconnect` Bool controls Tier-0/Tier-1 for that hold. Rare; Advanced docs only.
3. Specify **PoweredOn**: work submission awaits ready radio; terminal states fail; no silent scan no-op.
4. Specify **`Peripheral` / `DiscoveredPeripheral` split**: handle-centric API (`run` / discovery filter / Advanced connect); `discovered.peripheral` sugar; `peripheral(id:)` for known devices; tracked feed with last-discovery metadata (option A); manager keeps auth, scan, registry.
5. Keep FR-10 before FR-4/5 (unchanged).
6. Document reliability unit: **command completion after ready** (not connection alone).

### Build sequence

1. **`Peripheral` handle + `DiscoveredPeripheral` snapshot** rename/split; registry intern by id; `discovered.peripheral` sugar; `peripheral(id:)`; move link APIs onto `Peripheral`.
2. **Work-driven link rules**: ensure-linked from `run` with Tier-0 on; idle when queue empty && !appHold (cancel drops Tier-0); Tier-1 arm/disarm from queue (Approach B); Advanced hold via `connect`/`disconnect`.
3. **PoweredOn await** on scan/connect/work paths (replace scan no-op).
4. **FR-10** on handle (SM, ready stream, filtered discovery, subscriptions, didModifyServices, restore rediscover).
5. **Serial command queue** + run-after-ready + reconnect-and-rerun + watchdogs.
6. Then FR-5.2 deps/priority, FR-7, FR-6, FR-8.5 as needed.

### Concurrency

- Keep **one `@BluetoothActor`** owning all CB objects.
- Per-device **state machines + FIFO gates** inside it.
- Public **`Peripheral`** handles forward by id; **`DiscoveredPeripheral`** stays a pure value (+ manager stamp for sugar).
- Don’t add per-device actors that own `CBPeripheral`.

---

## Open questions (remaining)

1. ~~**Device API shape / naming**~~ — **Settled:** `Peripheral` (handle) + `DiscoveredPeripheral` (snapshot); `discovered.peripheral` sugar; known-id via `manager.peripheral(id:)`; option A last-discovery metadata on handle; option B `PeripheralUpdate` later. Detail: `docs/designs/discovered-peripheral-vs-peripheral-2026-07-15.md`.
2. ~~**Idle disconnect default duration**~~ — **Settled:** global config, default **5s**.
3. ~~**Ready vs subscriptions**~~ — **Settled:** catalog-ready; subscriptions = intent + re-arm.
4. ~~**UUID declaration API**~~ — **Settled:** sticky on **`Peripheral`** (e.g. `discoveryFilter` / set at obtain time); fail-closed if empty when discovery is required.
5. **Work-driven + never-seen known id** — on `run`, implicit filtered scan-until-match vs fail-fast “not discovered”? (Product choice; both fit the type model.)
6. **`Peripheral` reference semantics** — class vs struct-holding-id façade (both forward to actor); pick at implementation for identity/`===`/UI binding ergonomics.

**Settled (connections + types):** Work-driven primary; no either-or `ConnectionPolicy`; Approach B reconnect; Advanced app-hold only; idle **global 5s**; ready = catalog-ready; subscriptions = intent + re-arm; **`Peripheral` / `DiscoveredPeripheral`** split with option A metadata.

---

## Conclusion

- **Layering:** ReliaBLE = improved ObjC Core; band protocol is consumer context only.
- **Connections:** Prefer **await/park PoweredOn** for work paths (not only boot; not silent no-op). **Work-driven primary** (queue drives auto-connect; idle when empty); **Approach B** reconnect (Tier-0 while linked, cancel on idle; Tier-1 while work pending); **Advanced app-hold** `connect`/`disconnect` only — no either-or policy. Demote manager-only connect.
- **Types:** **`Peripheral`** (handle, IoT primary) + **`DiscoveredPeripheral`** (scan snapshot + `.peripheral` sugar); tracked “my devices” via handles + option A metadata; leave `Device` for apps.
- **Discovery:** FR-10 on **`Peripheral`**; sticky UUID filter on the handle.
- **Commands:** After FR-10 only.
- **Reliability bar:** Full PRD **clears ObjC Core** if work-driven default, PoweredOn await, FR-10, and command retry-after-ready ship; exceeds on restore/multi-device/observability; framing stays app-owned.
- **Concurrency:** **Single `@BluetoothActor`** + per-device state/FIFO; not separate CB-owning actors.

Until FR-10, the `Peripheral`/`DiscoveredPeripheral` split, and the work-driven path land, code remains a link-manager milestone on the way to Core parity — acceptable only because the library is unshipped and PRD-complete is the v1 bar.
