# Manual Hardware Test Plan — Work-Driven Connection Lifecycle

| Field | Value |
|-------|--------|
| **Branch** | `51-work-driven-connection-lifecycle` |
| **Tracking** | [#51](https://github.com/Five3Apps/ReliaBLE/issues/51) (#57–#60) |
| **Plan** | `docs/plans/work-driven-connection-lifecycle-2026-08-02.md` |
| **App under test** | **ReliaBLE Demo** (Xcode → physical devices) |
| **Library** | ReliaBLE (local package dependency) |
| **Date** | 2026-08-09 (Faraday box notes added same day) |
| **Scope** | Feature validation of Phase 2 lifecycle + regression of scan/connect/restore/background |
| **Audience** | Manual execution on real hardware (2–3 Apple devices) + Faraday box for RF drops |

---

## 1. Purpose

Validate that the Demo + library on real radios behave according to the work-driven connection model:

1. **#57 — PoweredOn await** — scan/connect fail fast on terminal radio states; do not silently no-op.
2. **#58 — Idle + Manual connect hold** — Manual `connect` holds the link (no idle teardown); `disconnect` clears the hold and tears down intentionally.
3. **#59 — Reconnect gating** — Tier-0 (OS) and Tier-1 (library ladder) only run while demand wants reconnect; quiet links stay quiet.
4. **#60 — Work-driven auto-connect** — primarily covered by unit tests (internal work leases). On device, validate the public half: Manual hold drives a standing link, idle is suppressed while held, and restore rehydrates holds.

Also re-check **regressions**: discovery, multi-device advertising, background modes, authorization, logging, and multi-central behavior.

---

## 2. What you can (and cannot) see in the Demo

### 2.1 Public surfaces exercised by the Demo

| Surface | Where in Demo |
|---------|----------------|
| `startScanning` (now `async throws`) | Central tab → **Start Scanning**; errors as red `scanError` text |
| `stopScanning` | Central tab → **Stop Scanning** |
| Bluetooth `state` stream | Top of Central: `ReliaBLE state: …` |
| Discovery streams | **Devices** / **Discoveries** lists |
| `Peripheral.connect(autoReconnect:)` | Device detail → **Connect** + **Auto Reconnect** toggle |
| `Peripheral.disconnect()` | Device detail → **Disconnect** |
| Connection-state stream | List caption + detail `Connection: …` |
| `idleDisconnectInterval` | Settings → **Connection Lifecycle** (takes effect **next launch**) |
| `ReconnectPolicy` | Settings → **Reconnect Policy** (next launch) |
| State restoration | App always uses `restoreIdentifier = com.five3apps.relia-ble-demo.central` |
| Peripheral role | **Peripheral** tab (raw `CBPeripheralManager`, not ReliaBLE) |

### 2.2 Not available in Demo UI (unit-test only)

| Behavior | Why |
|----------|-----|
| `acquireWorkLease` / `releaseWorkLease` | Internal / `@testable` only until the command queue (Phase 3) |
| Idle teardown after “work finished” | Idle fires only when **demand is zero**. Demo connect always sets a **manual-connect hold**, which suppresses idle |
| Double-release / refcount lease edge cases | Test hooks only |

**Implication for idle testing on HW:** you primarily prove that a **manual hold keeps the link up** past several idle intervals, and that **intentional disconnect does not arm reconnect**. True “queue drained → idle cancel” is trusted via automated tests unless you build a temporary debug hook.

### 2.3 Connection captions (expected strings)

From Demo `ConnectionState.description`:

| State | UI text | Color (approx.) |
|-------|---------|-----------------|
| `.connecting` | `Connecting` | orange |
| `.connected` | `Connected` | green |
| `.disconnecting` | `Disconnecting` | orange |
| `.disconnected(nil)` | `Disconnected` | secondary |
| `.disconnected(reason)` | `Disconnected (…)` | orange |
| `.failed(reason)` | `Failed (…)` | red |
| `.reconnecting(.system, …)` | `System reconnecting…` | yellow |
| `.reconnecting(.library, attempt, …)` | `Reconnecting (attempt N)` — **N may be 0** when waiting for radio (`attempt == nil` displays as 0) | yellow |
| Ladder step | Same + optional `Next retry in: Xs` countdown | yellow |

**Radio-await projection (important):** after Bluetooth power-off **while linked or connecting** with Auto Reconnect demand, expect roughly:

1. `Disconnected (bluetoothUnavailable)` (or similar reason text)
2. then `Reconnecting (attempt 0)` **without** a retry countdown (library waiting for radio, not ladder)

When Auto Reconnect was **off** and the device was still linked, expect settle at `Disconnected (bluetoothUnavailable)` **without** a lasting “reconnecting” claim.

When the peripheral was **already** cleanly `Disconnected` / `Failed` before power-off (e.g. intentional Disconnect, then BT off), the library does **not** rewrite the caption to `bluetoothUnavailable` — stay on the prior terminal text (Demo stream cache) or clear to untracked.

---

## 3. Hardware and environment

### 3.1 Recommended device roster

Assign stable labels and stick to them for the whole session:

| Label | Device | Primary role(s) |
|-------|--------|------------------|
| **C1** | iPhone A | Primary **Central** (ReliaBLE under test) |
| **P1** | iPhone B | **Peripheral** advertiser (Demo Peripheral tab) |
| **C2** | iPad | Second **Central** (multi-central / concurrent regression) |

Optional swaps: use iPad as P1 or C1 if convenient. Prefer two physical centrals for multi-central regression.

### 3.2 Software

- Xcode open on `ReliaBLE.xcworkspace` (or Demo project that consumes the local package).
- Branch: `51-work-driven-connection-lifecycle` (or the PR branch that contains these commits).
- Deploy **Debug** builds from Xcode to each device (Run to device).
- iOS versions: note in the results log (Tier-0 OS auto-reconnect requires **iOS 17+**).
- Keep devices unlocked, screen on for time-sensitive connection captions, or use Console (below).

### 3.3 Default Demo UUIDs / names

| Item | Default |
|------|---------|
| Demo service UUID | `12345678-90AB-CDEF-1234-567890ABCDEF` |
| Peripheral local name | `ReliaBLE Demo` (change per device if running two advertisers) |
| Central service filter field | Pre-filled with the same UUID (required for meaningful background scan) |
| Idle default | `5.0` s (Settings → change + **force quit & relaunch** to apply) |
| Restore ID | `com.five3apps.relia-ble-demo.central` (hard-coded in app) |

### 3.4 Faraday box (preferred for RF drop / reconnect)

You have a **Faraday box without USB passthrough**. That does **not** change which behaviors to test; it **does** change how drop cases are run and how evidence is collected.

#### Preferred geometry: isolate the **peripheral**, observe the **central**

| Role | Where | Why |
|------|--------|-----|
| **P1** (advertiser) | **Inside** the sealed box for the outage window | Drops the ACL/RF path cleanly and repeatably |
| **C1** (ReliaBLE under test) | **Outside** the box | You can watch connection captions live; Xcode/Console may stay attached to C1 |
| **C2** | Outside (multi-central cases) | Same as C1 |

Do **not** put C1 in the box for primary F3/F10 runs unless you are specifically testing “central RF isolation.” Without USB passthrough you lose the debug cable, and opaque boxes prevent watching the central UI during the critical transition.

#### Standard drop / restore procedure

1. Outside the box: P1 **Start Advertising**, C1 scan → connect to the desired Auto Reconnect setting → confirm **Connected**.
2. Keep C1 screen awake on P1’s device detail (connection caption visible). Optional: leave Xcode/Console attached to **C1 only**.
3. Place **P1** in the Faraday box, close/seal fully. Do not rely on a USB cable to P1.
4. On C1, note time-to-leave-Connected and intermediate captions (`System reconnecting…`, library reconnect, disconnected reason, etc.).
5. For recovery cases: open box / remove P1 (still advertising if the app was not killed) → note time-to-**Connected** on C1 without tapping Connect.
6. For “stay dead” cases (Auto Reconnect OFF): leave P1 out and advertising ≥ 30–60 s → must **not** auto-connect.

#### Constraints the box imposes (non-blocking)

| Constraint | Impact | Mitigation |
|------------|--------|------------|
| No USB while sealed | Cannot keep Xcode debugger on the **device inside** the box | Put only P1 inside; instrument C1 outside |
| Opaque enclosure | Cannot watch UI on the boxed device mid-outage | Observe C1; only glance at P1 after unsealing if needed |
| Wireless debug / Console to boxed device | Often fails or is flaky inside RF shield | Prefer Console/Xcode on C1; treat P1 as a dumb advertiser for drop suites |
| App may suspend on locked P1 | Advertising can stop if P1 sleeps aggressively | Before boxing: keep P1 unlocked, screen on, Low Power Mode off; Guided Access optional; confirm **Advertising** still true |
| Charge | Long sealed runs drain battery | Start drop suites with P1 ≥ ~50% battery |
| Incomplete seal / lid ajar | Partial isolation → flaky “still connected” | If Connected never drops after ~30–60 s, reseal and retry once before PARTIAL |

#### What still does **not** use the Faraday box

Leave these as Control Center / Settings / app lifecycle tests (box adds nothing):

- F1 radio gating (central BT off)
- F2 hold / idle suppression
- F4 **central** Bluetooth power cycle
- F5 force quit / restore
- F6–F9 multi-central, filters, settings

#### When to put the **central** in the box (optional, rare)

Only if you want a secondary check that C1 loses the peer when *its* RF is blocked. Then:

1. Pre-deploy Demo to C1 from Xcode; disconnect the cable.
2. Launch Demo from the home screen (standalone).
3. Connect to P1 (P1 outside, advertising).
4. Seal C1 in the box; you will **not** see live UI — use a wall-clock timer.
5. Unseal and read the connection caption (may already show reconnecting/connected/disconnected).

This is inferior to P1-in-box for pass/fail of intermediate states; treat as optional stress, not the ship bar.

### 3.5 Console logging

Demo enables logging by default (`OSLogWriter`, subsystem `com.five3apps.relia-ble-demo`, category `BLE`). Optional:

1. Mac: Console.app → select the **outside** central (C1) → filter `relia-ble` or `BLE`.
2. Xcode: keep the debug session on **C1** for Faraday drop suites; do not depend on a cable to P1.
3. Settings → **Enable Logging** if you turned it off.
4. Wireless logging to a device **inside** the sealed box is unreliable — do not require it for PASS/FAIL.

Useful log themes (info): Manual connect, Manual disconnect, idle timer armed / idle disconnect (latter mainly if demand hits zero — rare via pure Manual path).

### 3.6 Pass / fail conventions

| Result | Meaning |
|--------|---------|
| **PASS** | Observed behavior matches Expected |
| **FAIL** | Deviates; capture device, OS, steps, UI/console evidence |
| **BLOCKED** | Could not run (no advertiser, permission stuck, OS limitation, box isolation failure after retry) |
| **N/A** | Not applicable to this hardware (e.g. Tier-0 on iOS &lt; 17) |
| **PARTIAL** | Behavior close but timing/UI ambiguity; note details |

Prefer the Faraday box over walking-away for RF drops. If Connected never drops with P1 sealed, reseal once; then mark **BLOCKED** (isolation) rather than library FAIL. Crowded 2.4 GHz is less relevant for sealed-box runs but still applies to multi-central discovery suites.

---

## 4. Session setup checklist

Complete once at the start of the session (and after any Settings policy change that needs relaunch).

### 4.1 Clean slate (recommended first pass)

On each Central (**C1**, **C2**):

1. Install/run Demo from Xcode.
2. Settings → note Idle Disconnect (start with **5.0 s** unless a case asks otherwise).
3. Settings → Reconnect Policy defaults are fine for first pass (`maxAttempts 5`, `initialDelay 1.0`, `maxDelay 30`, `jitter 0.2`).
4. Central tab → if prompted, **Authorize Bluetooth** (Allow).
5. System Settings → Bluetooth **On**.
6. Optional: Central → **Clear All** to wipe SwiftData devices/discoveries between major suites.

On Peripheral (**P1**):

1. Open **Peripheral** tab.
2. Confirm name (e.g. `ReliaBLE Demo P1`) and service UUID = default above.
3. **Start Advertising** → Status shows **Advertising** / Powered On.

### 4.2 Baseline discovery smoke (must pass before features)

| Step | Action | Expected |
|------|--------|----------|
| 1 | C1 Central ready → leave service filter as default UUID → **Start Scanning** | `ReliaBLE state: scanning` (or equivalent); no red error |
| 2 | P1 advertising | C1 **Devices** shows P1 within ~10–30 s; **Discoveries** accumulates RSSI events |
| 3 | C1 **Stop Scanning** | State leaves scanning; discoveries stop growing |
| 4 | Open device detail on P1 | Shows ID, last seen; Connection unknown/disconnected; **Connect** enabled |

Record: **PASS / FAIL** baseline. If discovery fails, do not proceed to connection suites until advertising UUID match and BT authorization are fixed.

### 4.3 Optional: faster idle-related observation

For cases that wait multiple idle multiples (e.g. “still connected after 3× interval”):

1. Settings → Idle Disconnect = **2.0 s** (or **1.0 s**).
2. Force quit Demo on that central → relaunch from Xcode or home screen.
3. Note the value in the results log. **Revert to 5.0 s** before restore/battery-oriented cases if you care about production-like timing.

---

## 5. Feature tests

### Suite F1 — Radio gating / PoweredOn await (#57)

**Goal:** Terminal Bluetooth states fail scan/connect with typed errors; no silent no-op. Ready radio works.

#### F1.1 Scan while Bluetooth off

| | |
|--|--|
| **Devices** | C1 |
| **Steps** | 1. System Settings → Bluetooth **Off** (or Control Center long-press → toggle). 2. Return to Demo Central (state should reflect powered off). 3. If UI still shows Start Scanning, tap it. |
| **Expected** | Red scan error mentioning `bluetoothPoweredOff` (or `PeripheralError.bluetoothPoweredOff`). **No** discoveries. Manager state reflects powered off. |
| **Regression note** | Pre-change bug was silent return; any “nothing happened, no error” is **FAIL**. |

#### F1.2 Scan recovers after power on

| | |
|--|--|
| **Devices** | C1 + P1 advertising |
| **Steps** | 1. From F1.1, turn Bluetooth **On**. 2. Wait until Central shows ready (not unauthorized). 3. **Start Scanning**. |
| **Expected** | Scanning starts; P1 appears; no residual error (or error clears on new attempt). |

#### F1.3 Connect while Bluetooth off (hold-before-wait)

| | |
|--|--|
| **Devices** | C1 + P1 (P1 must have been discovered **before** BT off, so a device row/handle exists) |
| **Steps** | 1. With BT on, scan and ensure P1 is in Devices. 2. Stop scan optional. 3. Turn BT **Off**. 4. Open P1 detail → Auto Reconnect **ON** → **Connect**. |
| **Expected** | Connection does **not** succeed. Prefer: visible failed/disconnected path and/or no stuck “Connecting” forever. Demo device detail should show a red error caption for the thrown `bluetoothPoweredOff` (or similar). Watch for not stuck connecting and for later relink behavior in F1.4. |
| **Important** | Hold is registered **before** the radio wait. Intent survives the throw when Auto Reconnect is on. |

#### F1.4 Auto Reconnect ON: relink when radio returns

| | |
|--|--|
| **Devices** | C1 + P1 advertising |
| **Steps** | 1. Complete F1.3 (Connect with Auto Reconnect ON while BT off). 2. Turn BT **On**. 3. Leave UI on P1 detail; wait up to ~30–60 s. P1 should still be advertising. |
| **Expected** | Link eventually reaches **Connected** without needing another Connect tap (radio-return re-issue). May pass through Connecting / Reconnecting. |
| **FAIL if** | Stays permanently disconnected with no attempt after radio is clearly ready and P1 is still discoverable. |

#### F1.5 Auto Reconnect OFF: no radio-return re-issue

| | |
|--|--|
| **Devices** | C1 + P1 |
| **Steps** | 1. Ensure disconnected (Disconnect if needed). 2. BT **Off**. 3. Auto Reconnect **OFF** → **Connect**. 4. BT **On**. Wait ≥ 30 s. |
| **Expected** | **Does not** auto-connect. Stays disconnected (or non-connected). Idle remains suppressed while hold exists, but **no** re-issue. |
| **Cleanup** | **Disconnect** (or Connect then Disconnect) to clear residual hold if the UI still thinks a session is active. |

#### F1.6 Unauthorized / restricted (if practical)

| | |
|--|--|
| **Devices** | C1 |
| **Steps** | System Settings → Demo app → Bluetooth → **Don't Allow** / disable, or reset location & privacy if needed. Relaunch Demo. Try authorize / scan. |
| **Expected** | State shows unauthorized; scan fails with unavailability-style error (`bluetoothUnavailable`), not hang. Re-enable permission afterward. |
| **Note** | Optional if privacy reset is too disruptive; mark N/A. |

#### F1.7 Stop scanning cleans up

| | |
|--|--|
| **Devices** | C1 + P1 |
| **Steps** | Start Scanning → confirm discoveries → Stop Scanning → wait 15 s watching Discoveries timestamps. |
| **Expected** | Scanning stops; no continuous new discoveries; Start Scanning available again in ready state. |

**Suite F1 result:** ___ / PASS FAIL

---

### Suite F2 — Manual connect hold & idle suppression (#58)

**Goal:** Manual connect establishes a durable hold; hold suppresses idle teardown; disconnect is intentional and quiet.

#### F2.1 Happy-path connect / disconnect

| | |
|--|--|
| **Devices** | C1 + P1 advertising |
| **Steps** | 1. Scan → open P1. 2. Auto Reconnect **ON**. 3. **Connect**. 4. Observe Connecting → Connected. 5. **Disconnect**. |
| **Expected** | Connected (green). Disconnect → Disconnecting (brief) → **Disconnected** with **no** reason (or reason-less caption). **No** System/Library reconnect after intentional disconnect. Button returns to Connect. |

#### F2.2 Hold suppresses idle (critical)

| | |
|--|--|
| **Devices** | C1 + P1 |
| **Prep** | Idle interval known (e.g. 5 s or 2 s after relaunch). |
| **Steps** | 1. Connect Auto Reconnect ON → Connected. 2. Stop scanning optional. 3. Wait **≥ 3 × idle interval** (for 5 s → wait ≥ 15 s; for 2 s → ≥ 6 s). Prefer ≥ 30 s to be obvious. 4. Watch connection caption continuously. |
| **Expected** | Remains **Connected** the entire time. |
| **FAIL if** | Spontaneous Disconnect after ~idle interval (would mean hold not suppressing idle). |

#### F2.3 Auto Reconnect OFF still holds the live link

| | |
|--|--|
| **Devices** | C1 + P1 |
| **Steps** | 1. Disconnect if needed. 2. Auto Reconnect **OFF** → Connect → Connected. 3. Wait ≥ 3 × idle interval. |
| **Expected** | Stays **Connected** (hold present, `reconnectDesired == false` still suppresses idle). |
| **Note** | Differs from F2.2 only for later unexpected-drop behavior (Suite F3). |

#### F2.4 Intentional disconnect does not arm ladder

| | |
|--|--|
| **Devices** | C1 + P1 |
| **Steps** | 1. Connect Auto Reconnect ON. 2. Disconnect. 3. Wait ≥ max(idle, 2× initialDelay) with P1 still advertising. |
| **Expected** | Stays **Disconnected** (clean). No `Reconnecting (attempt N)` with countdown. |
| **FAIL if** | Library ladder starts after manual disconnect. |

#### F2.5 Toggle disabled while active

| | |
|--|--|
| **Devices** | C1 + P1 |
| **Steps** | Connect → while Connecting/Connected, try Auto Reconnect toggle. |
| **Expected** | Toggle **disabled** while connection is active (`canEditAutoReconnect`). |

#### F2.6 Logging smoke (optional)

| | |
|--|--|
| **Steps** | Console filter on → Connect → Disconnect. |
| **Expected** | Info-level connection logs tagged for the peripheral (Manual connect / disconnect). No crash spam. |

**Suite F2 result:** ___

---

### Suite F3 — Reconnect tiers & demand gating (#59)

**Goal:** Unexpected drops recover only when Auto Reconnect demand wants them; system vs library captions make sense.

#### F3.1 RF drop with Auto Reconnect ON (Tier-0 / system path) — **Faraday**

| | |
|--|--|
| **Devices** | C1 outside + P1 (iOS 17+ preferred); Faraday box |
| **Steps** | 1. Outside box: Connect Auto Reconnect **ON** → Connected. Keep C1 on device detail. 2. Place **P1** in Faraday box and seal (§3.4). 3. Observe **C1** caption during outage (note timestamps). 4. Unseal / remove P1 (still advertising). 5. Wait for recovery on C1 — do not tap Connect. |
| **Expected** | During outage: often `System reconnecting…` and/or disconnected/reconnecting captions — **not** permanent silent stuck “Connected”. On return: **Connected** again without tapping Connect. |
| **PARTIAL OK** | Exact system vs library wording depends on CoreBluetooth callbacks; recovery without user Connect is the bar. |
| **Fallback** | If box isolation fails after reseal, walk P1 away / stop advertising — note method in results log. |

#### F3.2 RF drop with Auto Reconnect OFF — **Faraday**

| | |
|--|--|
| **Devices** | C1 outside + P1; Faraday box |
| **Steps** | 1. Connect Auto Reconnect **OFF** → Connected. 2. Seal **P1** in box until C1 leaves Connected. 3. Remove P1 (advertising). Wait ≥ 30–60 s on C1. |
| **Expected** | Link does **not** come back on its own. Stays disconnected/failed. No library ladder countdown. |
| **Cleanup** | Disconnect if UI still shows active, then Connect again only if needed. |

#### F3.3 Peripheral reboot while held (Auto Reconnect ON)

| | |
|--|--|
| **Devices** | C1 + P1 (no Faraday required) |
| **Steps** | Connected with Auto Reconnect ON → reboot P1 (or force-quit Peripheral advertising app and relaunch + Start Advertising). Wait for recovery. |
| **Expected** | Eventually Connected again (system and/or library). |
| **Note** | Distinct from Faraday RF block: process death on the advertiser vs RF isolation while the app may still be “Advertising” with no path. |

#### F3.4 Library ladder visibility (optional, timing-sensitive) — **Faraday**

| | |
|--|--|
| **Devices** | C1 outside + P1; Settings with short `initialDelay` (e.g. 1.0) after relaunch; Faraday box |
| **Steps** | 1. Connect Auto Reconnect ON → Connected. 2. Seal P1 long enough that OS Tier-0 may give up (can be minutes — document wall time). 3. Watch C1 for `Reconnecting (attempt N)` with **Next retry in: Xs** (library ladder). 4. Optionally unseal mid-ladder to confirm recovery. |
| **Expected** | If ladder arms: attempt ≥ 1 and countdown present; eventually Connected or Failed after max attempts. |
| **Note** | Mock gap #40 makes OS give-up hard to unit-test; **this is an on-device observation**. Mark PARTIAL if only system reconnect is seen for the whole sealed window. |

#### F3.4b Cancel / clear demand *during* an OS reconnect attempt (on-device only) — **Faraday**

| | |
|--|--|
| **Devices** | C1 outside + P1; Faraday box; short idle interval optional (see §4.3) |
| **Steps** | 1. Get to Connected with Auto Reconnect **ON**. 2. Seal **P1** so the OS starts a Tier-0 reconnect — C1 caption shows system reconnecting (or equivalent). 3. While that reconnect is still in flight, remove demand on C1: **Disconnect** (clearing the manual hold). 4. Unseal P1 (advertising) and wait ≥ 60 s. |
| **Expected** | The link is torn down and does **not** come back: clearing demand cancels trust in the in-flight OS reconnect. Caption settles to a clean disconnected state, never `Disconnecting…` indefinitely. |
| **Note** | CoreBluetoothMock always resolves a Tier-0 attempt (relink or `didFailToConnect`), so the in-flight window cannot be held open in unit tests; the cancel is pinned white-box by `idleTeardownDuringCachedSystemReconnectCancels`. **This is the on-device confirmation.** Faraday helps hold the “OS still trying” window open longer than walking away. |

#### F3.5 Quiet after clean disconnect (regression of arming)

| | |
|--|--|
| **Steps** | After any F3 recovery, **Disconnect** intentionally, leave P1 advertising 60 s. |
| **Expected** | No spontaneous reconnect. |

**Suite F3 result:** ___

---

### Suite F4 — Radio power cycle while demanded (#59 / event 13)

**Goal:** Turning Bluetooth off/on on the **central** preserves demand for Auto Reconnect holds and re-establishes the link; projection is honest.

#### F4.1 Power cycle with Auto Reconnect ON

| | |
|--|--|
| **Devices** | C1 + P1 advertising throughout |
| **Steps** | 1. Connect Auto Reconnect ON → Connected. 2. Control Center / Settings → Bluetooth **Off** on C1. 3. Observe caption sequence (~5–15 s). 4. Bluetooth **On**. 5. Wait up to 60 s. |
| **Expected** | Off: leaves Connected; expect disconnected with unavailability reason, then preferably **Reconnecting (attempt 0)** (radio wait — no countdown). On: returns to **Connected** without user Connect. |
| **FAIL if** | After BT on, remains disconnected forever while P1 advertises and hold was Auto Reconnect ON. |
| **FAIL if** | Stays showing Connected while BT is off (stale cache). |

#### F4.2 Power cycle with Auto Reconnect OFF

| | |
|--|--|
| **Devices** | C1 + P1 |
| **Steps** | Connect Auto Reconnect OFF → Connected → BT Off → observe → BT On → wait 30–60 s. |
| **Expected** | Does **not** auto re-link. Prefer: no sustained “Reconnecting” claiming recovery. Hold still suppressed idle while present, but issue gate refuses radio-return connect. |
| **Cleanup** | **Disconnect** to drop hold. |

#### F4.3 Disconnect during radio outage

| | |
|--|--|
| **Devices** | C1 + P1 |
| **Steps** | 1. Connect Auto Reconnect ON. 2. BT Off (demand/reconnecting projection). 3. Tap **Disconnect** (button may still show as active while reconnecting). 4. BT On. Wait 30 s. |
| **Expected** | Disconnect succeeds (no hard error UI required). After BT on, **no** auto-connect (hold cleared). |
| **FAIL if** | Link comes back after outage disconnect (hold not cleared). |

**Suite F4 result:** ___

---

### Suite F5 — State restoration & durable holds (#59 D-restore)

**Goal:** Manual-connect holds survive process death when `restoreIdentifier` is set; restored standing sessions reappear.

**Prep:** C1 has `UIBackgroundModes` = `bluetooth-central` (already in Demo Info.plist). Use **non-empty service filter** (default UUID) for any background scan expectations. Keep Auto Reconnect **ON** for durability cases.

#### F5.1 Background briefly (connection retained by OS/app)

| | |
|--|--|
| **Devices** | C1 + P1 |
| **Steps** | Connect Auto Reconnect ON → Connected → home button / app switcher leave Demo in background 30–60 s → return. |
| **Expected** | Still Connected (or briefly reconnecting then Connected). App does not crash. |

#### F5.2 Force quit + relaunch with Auto Reconnect ON (durable hold)

| | |
|--|--|
| **Devices** | C1 + P1 keep advertising |
| **Steps** | 1. Connect Auto Reconnect ON → Connected. 2. App switcher → **force quit** Demo. 3. Wait ~5–10 s. 4. Relaunch Demo from Xcode or icon. 5. Open Central → device list / detail for P1. Wait up to 60 s. |
| **Expected** | Connection state for P1 returns to **Connected** (or reconnecting then Connected) **without** tapping Connect. Restored hold rehydrated. |
| **Notes** | First launch after upgrade may drop old-format persistence once; re-run Connect → force quit → relaunch. If OS does not restore peripherals quickly, still expect library re-issue once central is ready and peripheral is known. |
| **FAIL if** | Always idle-disconnects within ~idle interval after relaunch despite Auto Reconnect ON connect before kill. |

#### F5.3 Force quit after intentional Disconnect

| | |
|--|--|
| **Devices** | C1 + P1 |
| **Steps** | Connect → Disconnect (clean) → force quit → relaunch → wait 30 s. |
| **Expected** | Does **not** reconnect on its own (hold cleared before kill). |

#### F5.4 Force quit with Auto Reconnect OFF hold

| | |
|--|--|
| **Devices** | C1 + P1 |
| **Steps** | Connect Auto Reconnect OFF → Connected → force quit → relaunch → wait ≥ 3 × idle interval. |
| **Expected** | Prefer: link restored or idle-suppressed standing behavior per hold map (`reconnectDesired: false` — suppress idle, no tiers). Exact OS restore of the ACL link varies; **must not** start library ladder / system auto-reconnect storm. If link is up, it should **not** idle-drop solely because process restarted. If OS did not restore the ACL, library should **not** re-issue connect. |
| **Document** | What you actually see (Connected vs Disconnected) — valuable for restore matrix validation. |

#### F5.5 Background scan with service filter (regression + restore adjacent)

| | |
|--|--|
| **Devices** | C1 + P1 |
| **Steps** | Service filter = default UUID → Start Scanning → background Demo 30–60 s → foreground. Optionally force quit mid-scan and relaunch. |
| **Expected** | No crash. With filter set, scanning can continue in background per OS; discoveries may lag. Without filter, background discovery is not guaranteed (by design caption in UI). |

**Suite F5 result:** ___

---

### Suite F6 — Multi-device / multi-central regression

**Goal:** ReliaBLE central stacks remain independent; second central does not break the first.

#### F6.1 Two centrals discover one peripheral

| | |
|--|--|
| **Devices** | C1, C2, P1 advertising |
| **Steps** | Both centrals Start Scanning with same service UUID. |
| **Expected** | Both list P1. Independent device IDs/lists (per-install SwiftData). |

#### F6.2 Two centrals connect concurrently

| | |
|--|--|
| **Devices** | C1, C2, P1 |
| **Steps** | C1 Connect Auto Reconnect ON; C2 Connect Auto Reconnect ON (if peripheral allows multiple centrals — Demo peripheral may support one or more depending on stack). |
| **Expected** | At least one Connected. If second fails, note OS/peripheral limit (**PARTIAL**, not necessarily library bug). Neither central should crash or wedge scanning. |
| **Note** | Many simple peripherals accept only one central; treat dual-connect success as bonus. |

#### F6.3 Cross-traffic isolation

| | |
|--|--|
| **Devices** | C1 connected; C2 scanning only |
| **Steps** | C1 Disconnect / power-cycle BT; watch C2. |
| **Expected** | C2 discoveries continue; no cross-process crash. |

#### F6.4 Two advertisers, one central

| | |
|--|--|
| **Devices** | C1; P1 and C2-as-peripheral (or second phone as P2) with **distinct names**, same service UUID |
| **Steps** | C1 scan → both appear → connect to one → other still listed. |
| **Expected** | Connection state only for the connected id; second remains disconnected. Disconnect first; connect second. |

**Suite F6 result:** ___

---

### Suite F7 — Discovery & scan filter regression

#### F7.1 Empty service filter (foreground)

| | |
|--|--|
| **Steps** | Clear service UUID field on C1 → Start Scanning. |
| **Expected** | Scan starts; may see broader set of BLE devices. P1 still appears if advertising. |

#### F7.2 Wrong service filter

| | |
|--|--|
| **Steps** | Set filter to a random UUID not used by P1 → Start Scanning. |
| **Expected** | P1 **not** listed (or not as matching service). Switch back to correct UUID → appears. |

#### F7.3 Stop / start scan thrash

| | |
|--|--|
| **Steps** | Rapidly Start → Stop → Start 5 times. |
| **Expected** | No crash; final state matches last action; no permanent red error. |

#### F7.4 Clear All data

| | |
|--|--|
| **Steps** | With devices present → Clear All → rescan. |
| **Expected** | Lists empty then refill from live scan. Connection holds are **library** state — clearing SwiftData rows does not by itself call `disconnect()`; if a link was up, behavior may still show connection until disconnect. Prefer Disconnect before Clear All for clean slate. |

**Suite F7 result:** ___

---

### Suite F8 — Authorization & first-run regression

#### F8.1 Fresh install authorize path (optional wipe)

| | |
|--|--|
| **Steps** | Delete Demo from C1 → Run from Xcode → Central → Authorize if shown → Allow. |
| **Expected** | Reaches ready; scan works. |

#### F8.2 Peripheral tab permission

| | |
|--|--|
| **Steps** | On a device that has never advertised: Peripheral → Start Advertising. |
| **Expected** | Permission prompt if needed; reaches Advertising when powered on. |

**Suite F8 result:** ___

---

### Suite F9 — Settings knobs regression

#### F9.1 Idle interval applies after relaunch

| | |
|--|--|
| **Steps** | Set Idle to 10 s → force quit → relaunch → F2.2 style hold test still stays connected past 30 s. |
| **Expected** | Hold still suppresses idle (interval change must not drop held links). |

#### F9.2 Reconnect policy applies after relaunch

| | |
|--|--|
| **Steps** | Set maxAttempts = 2, initialDelay = 1 → relaunch → provoke hard unexpected disconnect if possible; observe limited retries. |
| **Expected** | If library ladder is visible, attempts cap near 2 then settle failed/disconnected. If only system reconnect runs, mark PARTIAL. |

#### F9.3 Logging toggle

| | |
|--|--|
| **Steps** | Settings → disable logging → Connect → enable logging → Disconnect. |
| **Expected** | No crash; console volume changes appropriately. |

**Suite F9 result:** ___

---

### Suite F10 — Stress / edge (timeboxed)

Run only if time remains; each is optional.

| ID | Scenario | Expected |
|----|----------|----------|
| F10.1 | Connect while P1 **not** advertising | Connecting then failed/disconnected; no infinite spinner without state change |
| F10.2 | Airplane Mode on C1 mid-connection | Leaves connected cleanly; recovers when mode off + BT on (similar to F4) |
| F10.3 | Lock screen 2+ minutes while connected | Still connected or recovers on unlock |
| F10.4 | Low power mode on C1 | Connect/scan still function |
| F10.5 | **Faraday:** seal P1 until ladder/system gives up, then unseal | Either auto-recovers if demand remains, or stays failed after budget — document which + sealed duration |
| F10.6 | Cancel connect quickly (Connect then Disconnect within 1 s) | Settles disconnected; no stuck Connecting; no reconnect storm |
| F10.7 | **Faraday optional:** C1 inside box, P1 outside (standalone C1, no USB) | After unseal, caption is reconnecting/connected/disconnected consistently — intermediate states may be missed |

**Suite F10 result:** ___

---

## 6. Behaviors to treat as known limitations (not automatic FAIL)

| Topic | Guidance |
|-------|----------|
| **Work-lease auto-connect** | Not Demo-exposed; covered by unit tests. Do not FAIL HW plan for missing lease UI. |
| **Idle teardown of work-only links** | Not Demo-exposed; prove hold **suppresses** idle instead. |
| **Tier-0 give-up timing** | OS-defined; document observed seconds. |
| **Dual central to one peripheral** | Peripheral may reject second link. |
| **Background ads truncated** | iOS may omit local name; rely on service UUID filter. |
| **Demo `try?` on connect** | Thrown `bluetoothPoweredOff` may lack an alert; use F1.4 relink and scanError for scan path. |
| **`Reconnecting (attempt 0)`** | Means radio-await (`attempt == nil`), not ladder step 0. |
| **Upgrade persistence shape** | One relaunch after upgrading from pre-hold-map builds may lose standing holds — re-connect once. |

---

## 7. Suggested execution order (half-day pass)

| Phase | Suites | Est. time | Devices |
|-------|--------|-----------|---------|
| Setup + baseline | §4 | 15 min | All |
| Radio gating | F1 | 25 min | C1, P1 |
| Manual hold / idle suppress | F2 | 20 min | C1, P1 |
| Reconnect (Faraday: P1 in box) | F3 | 30–45 min | C1 outside, P1 in box |
| Central BT power cycle | F4 | 20 min | C1, P1 |
| Restore / force quit | F5 | 25 min | C1, P1 |
| Multi-central | F6 | 20 min | C1, C2, P1 |
| Scan/auth/settings | F7–F9 | 20 min | C1, P1 |
| Stress (optional) | F10 | 20 min | C1, P1 |

**Minimum ship bar (feature):** F1.1, F1.2, F1.4, F2.1, F2.2, F2.4, F3.1, F3.2, F4.1, F5.2, F5.3, F6.1, baseline discovery.

**Minimum regression bar:** F1.7, F7.2, F7.3, F8.1 or existing-auth OK, F5.1, F6.3.

---

## 8. Results log template

Copy per session:

```text
Date:
Branch / commit:
Xcode:
C1: device model / iOS:
C2: device model / iOS:
P1: device model / iOS:
Faraday box used (Y/N); isolation method for drops (P1-in-box / walk-away / stop advertising):
Idle interval used:
Reconnect policy overrides:

Baseline discovery: PASS/FAIL — notes:

F1.1:  F1.2:  F1.3:  F1.4:  F1.5:  F1.6:  F1.7:
F2.1:  F2.2:  F2.3:  F2.4:  F2.5:  F2.6:
F3.1:  F3.2:  F3.3:  F3.4:  F3.5:
F4.1:  F4.2:  F4.3:
F5.1:  F5.2:  F5.3:  F5.4:  F5.5:
F6.1:  F6.2:  F6.3:  F6.4:
F7.1:  F7.2:  F7.3:  F7.4:
F8.1:  F8.2:
F9.1:  F9.2:  F9.3:
F10.*:

Blockers / FAIL details:
Screenshots / Console excerpts:

Overall: PASS / FAIL / PASS WITH NOTES
```

---

## 9. Mapping to plan acceptance

| Plan / issue | HW coverage |
|--------------|-------------|
| #57 PoweredOn await | F1 |
| #58 Idle + Manual hold | F2 (hold suppress + intentional disconnect); idle **teardown** via leases = unit tests |
| #59 Reconnect gating | F3, F4 |
| #60 Work-driven auto-connect | Unit tests + hold-driven standing session as public proxy |
| D-hold (hold before wait) | F1.3–F1.5 |
| D-restore durable holds | F5 |
| D-1 event 13 radio drop projection | F4.1 |
| FR-9.2 logging | F2.6 |
| Mock gaps #40 / #42 | F3.4, F5.2 (on-device only) |
| Multi-device regression | F6–F8 |

---

## 10. Quick operator cheat sheet

**P1 advertising**

1. Peripheral tab → name + UUID `12345678-90AB-CDEF-1234-567890ABCDEF` → Start Advertising.

**C1 connect**

1. Central → filter UUID same → Start Scanning → Devices → P1 → Auto Reconnect as required → Connect.

**Prove hold**

1. Stay Connected &gt; 3× idle interval without touching UI.

**Prove intentional quiet**

1. Disconnect → wait → must not reconnect.

**Prove Auto Reconnect (Faraday)**

1. C1 Connected (Auto Reconnect ON), screen on device detail.
2. Seal **P1** in Faraday box → C1 should leave Connected / show system or library reconnecting.
3. Unseal P1 → Connected without Connect tap.

**Prove no reconnect when Auto Reconnect OFF (Faraday)**

1. Connect with toggle OFF → seal P1 → unseal → must **not** auto-connect within 30–60 s.

**Prove BT power cycle** (no box)

1. Connected + Auto Reconnect ON → BT off on **C1** → reconnecting/disconnected → BT on → Connected.

**Prove restore** (no box)

1. Connected + Auto Reconnect ON → force quit → relaunch → Connected without Connect tap.

**Clear stuck demand**

1. Open device → Disconnect (even if already disconnected looking) before starting the next contradictory case.

**Faraday reminder**

1. Instrument **C1 outside**; only **P1** goes in the box (no USB passthrough). Keep P1 unlocked/advertising before sealing.

---

## 11. References

- `docs/plans/work-driven-connection-lifecycle-2026-08-02.md`
- `docs/reviews/work-driven-connection-lifecycle-plan-critique-2026-08-02.md`
- `docs/reviews/work-driven-connection-lifecycle-poweredoff-feedback-2026-08-05.md`
- `docs/plans/corebluetoothmock-upstream-gaps-2026-07-21.md` (#40, #42)
- Demo: `CentralView.swift`, `CentralViewModel.swift`, `SettingsView.swift`, `ReliaBLE_DemoApp.swift`, `PeripheralView.swift`
- Library: `Peripheral.connect` / `disconnect`, `ReliaBLEConfig.idleDisconnectInterval`, `ConnectionState.reconnecting` docs
