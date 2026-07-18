# Design note: `DiscoveredPeripheral` vs `Peripheral`

**Date:** 2026-07-15  
**Status:** Proposed product direction (not yet implemented)  
**Audience:** iOS / BLE engineers reviewing ReliaBLE’s public API shape  
**Repo:** [ReliaBLE](https://github.com/Five3Apps/ReliaBLE) (public; unshipped, PRD-driven)

Related: `docs/investigations/objc-ble-vs-reliable-architecture-2026-07-15.md`, `PRD.md` (incl. FR-10 service/characteristic discovery), `Sources/ReliaBLE/Models/Peripheral.swift` (current snapshot type).

---

## Why this note exists

We need a second opinion on how ReliaBLE should expose **“a device I talk to”** vs **“something I just saw advertising”** under **Swift 6 strict concurrency**, without teaching every integrating developer CoreBluetooth.

This document summarizes constraints, options we considered, and where we landed. Feedback welcome—especially from people who have shipped multi-device BLE apps or multi-transport IoT stacks (BLE + Matter + Wi‑Fi, etc.).

---

## Context: what ReliaBLE is

**ReliaBLE** is an open-source Swift package that aims to be a **reliable BLE Central** layer for iOS (and related Apple platforms): scan, connection lifecycle, (planned) GATT discovery/readiness, and a command-style API for peripheral I/O. It is intentionally **device-protocol-agnostic**—command *content* (framing, CRC, domain packets) stays in the integrating app (`PRD` FR-4.1). Think “modern CoreBluetooth Core,” not a band-specific SDK.

**Status:** In active development; **not intended for production use until the PRD is implemented**. Today’s shipped surface is roughly: authorize, scan streams, connect/disconnect, connection-state streams, reconnect policy, logging, background restore hooks. **GATT discovery and commands are not implemented yet** (FR-10 and FR-4/5).

**Primary product targets:** wearables, IoT sensors, smart-home accessories—apps that think in **“my devices”** first. Generic “BLE scanner” UIs are supported but secondary.

**Historical inspiration:** An older in-house ObjC stack used a device-centric Core (`CCBTPeripheral` + `runCommand:`) with demand-driven connect and a discovery gate before work. ReliaBLE wants that ergonomics in Swift 6, not a central-manager-shaped API that forces every app to re-learn CB.

---

## The problem

### What we have today

`Peripheral` is an **immutable, `Sendable` value snapshot**: id, optional `cbIdentifier`, name, rssi, lastSeen, advertisement. Live `CBPeripheral` never leaves an internal actor; `ReliaBLEManager.connect(to:)` takes a snapshot and looks up the live object by id.

That was a good milestone for **scan lists + Swift 6 safety**. It is an awkward long-term home for:

- sticky GATT discovery filters (FR-10),
- readiness / subscription intent,
- a per-device command queue,
- work-driven auto-connect and idle teardown,
- Advanced explicit `connect`/`disconnect` (“app hold”).

### Two jobs that fight each other

| Job | Needs |
|---|---|
| **Nearby / scan UI** | Cheap copies, `Sendable` across actors, high churn (rssi/ads every advertisement) |
| **Device control** | Stable identity across ads and sessions, long-lived config (UUID filter, hold), streams, `run(command)` |

ObjC solved this with a **reference-type peripheral wrapper** on a serial queue. Swift 6 + non-`Sendable` CoreBluetooth types push us to split **public values** from **internal CB ownership**, and to be deliberate about what the app holds.

### Constraints (non-negotiable)

1. **`CBCentralManager` / `CBPeripheral` / GATT objects are not `Sendable`.** They must stay inside one isolation domain (ReliaBLE uses an internal `@BluetoothActor` + delegate shim). Public API must not vending live CB objects.
2. **Complete concurrency checking** (Swift 6) — public models crossing `@MainActor` UI and library code must be safe.
3. **Ergonomics for developers who may never have used CoreBluetooth** — “my device does work,” not “central connects to peripheral identifier.”
4. **Don’t block multi-transport apps** — many IoT products wrap BLE + Matter + Wi‑Fi. The library should not steal the name **`Device`** if apps need it for that umbrella type.
5. **Known-id devices before first scan** — account-bound locks/bands must be representable offline, then matched when advertising appears (and eventually FR-8.5 manufacturer-data identity).

---

## Options we considered

### Option 1 — One type: keep `Peripheral` as snapshot; all control on `ReliaBLEManager`

```text
manager.connect(to: peripheral)
manager.run(command, on: peripheral.id)  // hypothetical
```

| Pros | Cons |
|---|---|
| One public model type | Teaches central-manager shape; poor match to work-driven “device does work” |
| Snapshot stays pure | Sticky filter / queue / ready have no natural home |
| | Easy to pass stale snapshots; id-keyed manager APIs everywhere |

**Rejected** as the primary long-term API (may remain as internal/advanced plumbing).

### Option 2 — One type: make `Peripheral` both snapshot and controller

Grow methods on the current struct/class and use it in lists and for `run`.

| Pros | Cons |
|---|---|
| Single noun | Either loses pure value semantics (harder lists/SwiftUI) or pretends a snapshot can own queues/filters |
| | High churn ads vs stable control state on the same type gets messy |

**Rejected** without a split: the two jobs above don’t share a single good representation under Sendable + CB isolation.

### Option 3 — Two types: `Peripheral` (snapshot) + `Device` / `PeripheralHandle` (control)

| Pros | Cons |
|---|---|
| Clear separation of jobs | “Device” is vague and often wanted by multi-transport app layers |
| | Primary noun for control isn’t Apple’s BLE term |
| | Risk apps say `Device` for BLE-only and paint into a corner later |

**Rejected naming** (`Device` as library type). Split of jobs is right; names were not.

### Option 4 — Two types: `DiscoveredPeripheral` (snapshot) + `Peripheral` (control handle) ✅

| Pros | Cons |
|---|---|
| Control object uses Apple-aligned **Peripheral** | Rename vs today’s snapshot-named `Peripheral` (breaking for unshipped API — acceptable) |
| Snapshot name signals ephemeral “what we heard” | Two types to learn (mitigated by sugar and docs) |
| Leaves **`Device`** free for app multi-transport models | |
| Matches wearables/IoT: hold a `Peripheral`, optionally show discoveries | |

**Chosen.**

---

## Chosen design (summary)

```text
ReliaBLEManager
  ├── scan → AsyncStream<DiscoveredPeripheral>    // “nearby”
  ├── peripheral(id:) → Peripheral                // “my device” (known id, may be unseen)
  └── tracked peripherals feed (optional)         // handles + last-seen metadata

DiscoveredPeripheral  (Sendable value)
  ├── advertisement, rssi, lastSeen, id, …
  ├── stamped with vending manager
  └── var peripheral: Peripheral                  // sugar → interned handle

Peripheral  (long-lived handle, interned by id)
  ├── discoveryFilter (sticky; FR-10)
  ├── run(command) / ready / connection streams
  ├── Advanced connect(autoReconnect:) / disconnect()
  └── lastSeen / rssi / lastAdvertisement?        // option A metadata for “my devices” UI
```

### Interning

All paths resolve to **one handle per id per manager**:

- `manager.peripheral(id:)` creates or returns the interned handle.
- `discovered.peripheral` is **syntactic sugar** over the same registry (not a new instance per ad).
- Discovery matching binds the live `CBPeripheral` (actor-internal) onto that handle when ids align.

### Sugar: `discovered.peripheral`

Preferred over forcing `manager.peripheral(for: discovered)` at every call site. Implementation: manager-stamped discovery + registry lookup by id. Multi-manager safe because the stamp identifies the registry.

### Known id without scan

```swift
let lock = manager.peripheral(id: "user-bound-lock-id")
// configure filter, show in “My devices” UI even if offline
// later: advertising matches → same Peripheral gains live radio
try await lock.run(SyncCommand())
```

Whether `run` on a never-seen handle **implicitly scans until match** vs **fails fast** is a separate product choice; the type model supports both.

### UI: don’t fake discoveries

| List | Source |
|---|---|
| **My devices** (primary for IoT) | Known/tracked **`Peripheral`** handles |
| **Nearby** (scanner / provisioning) | Real **`DiscoveredPeripheral`** stream only |

**Do not** vend synthetic `DiscoveredPeripheral` rows for offline bound devices (lies about advertisements, pollutes “nearby”). Enrich handles when a real match arrives.

### Option A now, option B later (tracked devices feed)

**Option A (planned now):** put **last discovery metadata** on `Peripheral` (e.g. lastSeen, rssi, optional last advertisement snapshot) so “my devices” UI can bind a single object.

**Option B (later, if needed):** a thin stream payload such as `PeripheralUpdate { peripheral, discovery: DiscoveredPeripheral? }` for fully immutable event logs—**not** a third control type.

### What we are not doing

- Vending `CBPeripheral` / GATT objects publicly.
- Making `Device` a ReliaBLE type (reserved for apps).
- Treating the raw discovery stream as the only device list.
- Placeholder/fake discoveries for known ids.
- Per-peripheral actors that own `CBPeripheral` (CB stays on the single Bluetooth actor; handles forward by id).

---

## How this fits connection & discovery direction (brief)

For full connection/reconnect/FR-10 discussion see the investigation doc. Short version:

- **Work-driven default:** non-empty command queue → auto-connect; idle teardown (global default 5s) when quiet; Advanced `connect` is rare **app hold**.
- **FR-10:** GATT discovery/readiness on **`Peripheral`**; sticky UUID filter on the handle; **connected ≠ ready**.
- **Commands (after FR-10):** `peripheral.run(...)`; serial per-device queue; reconnect-and-rerun after ready.

The type split is what makes that API teachable without CB.

---

## Conceptual app usage

```swift
// --- Wearables / IoT primary path ---
let band = manager.peripheral(id: account.deviceId)
band.discoveryFilter = .init(services: [...], characteristics: [...])

// “My devices” UI observes tracked peripherals / handle metadata (option A)
for await p in manager.trackedPeripherals { /* rssi, lastSeen, connection/ready */ }

try await band.run(SyncDayCommand())  // connect + discover to ready + work (planned)

// --- Scanner / add-device path ---
for await discovered in manager.peripheralDiscoveries {
    let p = discovered.peripheral
    // show ads; on user pick, keep `p` as the bound handle
}
```

---

## Questions for reviewers

1. Does **`Peripheral` = handle** and **`DiscoveredPeripheral` = scan row** read cleanly if you’ve never used this library?
2. Is **`discovered.peripheral` sugar** worth it, or do you prefer an explicit `manager.peripheral(for:)` only?
3. For **known-id + never seen**, do you prefer **implicit scan-on-`run`** or **fail-fast** until the app has seen an advertisement?
4. Option A metadata **on the handle** vs pushing sooner to option B **update events**—any strong preference for SwiftUI list diffing?
5. Any naming collision or confusion with Apple’s `CBPeripheral` in docs/API (we never expose CB types, but the word overlaps)?
6. Multi-transport: does leaving **`Device`** free match how you’d structure an app above ReliaBLE?

---

## References in-repo

| Item | Path |
|---|---|
| Current snapshot type (to be split/renamed) | `Sources/ReliaBLE/Models/Peripheral.swift` |
| Manager façade | `Sources/ReliaBLE/ReliaBLEManager.swift` |
| Concurrency model | `Sources/ReliaBLE/Documentation.docc/Topics/Concurrency.md` |
| PRD (incl. FR-10 discovery gate) | `PRD.md` |
| Broader ObjC Core vs ReliaBLE investigation | `docs/investigations/objc-ble-vs-reliable-architecture-2026-07-15.md` |

---

## Decision log (short)

| Decision | Choice |
|---|---|
| Two public layers | Yes — required by scan-value vs control-handle jobs under Swift 6 |
| Control type name | **`Peripheral`** |
| Scan type name | **`DiscoveredPeripheral`** |
| Multi-transport name | Leave **`Device`** to apps |
| Cross-link sugar | **`discovered.peripheral`** via manager stamp + id registry |
| Known id | **`manager.peripheral(id:)`** first; discovery binds later |
| “My devices” UI | Tracked **handles** + option A last-discovery metadata; no fake discoveries |
| Future | Optional option B `PeripheralUpdate` stream; not a third control object |
