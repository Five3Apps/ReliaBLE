# Upstream feature request: CoreBluetoothMock state-restoration fidelity gaps
*Target: [NordicSemiconductor/IOS-CoreBluetooth-Mock](https://github.com/NordicSemiconductor/IOS-CoreBluetooth-Mock) · pinned ReliaBLE dep: **1.0.6** (revision `5748c9e`) · 2026-07-21*

## Context

ReliaBLE (Swift BLE library) uses CoreBluetoothMock 1.0.6 for unit tests via a three-target SPM seam. After migrating to per-manager `BluetoothActor` isolation, cold-relaunch restoration tests use the real production path:

1. Set `CBMCentralManagerMock.simulateStateRestoration`
2. Construct a central with `CBCentralManagerOptionRestoreIdentifierKey`
3. Observe `centralManager(_:willRestoreState:)` fired **synchronously during `init`**

That path (PR #123 / `simulateStateRestoration`) is sufficient for the common cases: restored **connected** peripherals, scan-services rehydrate, and cold-relaunch reconnect-intent re-arm. The gaps below are residual only — scenarios we still cover with a thin direct call into our `handleWillRestoreState` unit-test hook because the mock cannot present them faithfully.

Verified against checkout source:

- `CoreBluetoothMock/CBMCentralManagerMock.swift` init with options (~L314–L346)
- `CBMPeripheralMock.init(basedOn:by:andRestoreState:)` (~L955–L979)
- `public static var simulateStateRestoration` (~L419)

---

## Gap 1 — `isScanning` forced `true` for any restored scan key

### Current behavior (1.0.6)

In `CBMCentralManagerMock.init(delegate:queue:options:)`:

```swift
if let scanServiceKey = dict[CBMCentralManagerRestoredStateScanServicesKey] as? [CBMUUID] {
    state[CBMCentralManagerRestoredStateScanServicesKey] = scanServiceKey
    self.isScanning = true          // ← always, including empty []
    self.scanFilter = scanServiceKey
}
if let scanOptions = dict[CBMCentralManagerRestoredStateScanOptionsKey] as? [String : Any] {
    state[CBMCentralManagerRestoredStateScanOptionsKey] = scanOptions
    self.isScanning = true          // ← always
    self.scanOptions = scanOptions
}
```

Any non-`nil` presence of the scan-services **or** scan-options key forces `isScanning = true`, even when the services array is `[]`.

### Why it blocks faithful tests

On real iOS, a restored central may report scan services in the restore dictionary while the radio is not yet `.poweredOn`; apps must **defer** restarting the scan until powered on, and must **not** treat an empty service filter as an active background-useful scan. ReliaBLE has two defensive handlers we can only unit-test by calling the handler directly:

| Scenario | Faithful central-init path today |
|---|---|
| Defer restored scan until `.poweredOn` | Impossible — mock already claims `isScanning == true` at init, before `didUpdateState` |
| Empty scan-service filter is ignored (background-useless) | Impossible — empty `[]` still sets `isScanning = true` |

### Proposed behavior

1. **Do not set `isScanning = true` solely because restore keys are present.** Prefer one of:
   - Leave `isScanning == false` after restore-init; let the app’s normal `scanForPeripherals` (or an explicit opt-in) drive the flag; **or**
   - Gate `isScanning = true` on mock manager state already being `.poweredOn` **and** a non-empty service filter (when services key is present).
2. **Empty `[CBMUUID]` scan services:** still include the key in the `willRestoreState` dictionary (iOS can hand back what was stored), but **do not** set `isScanning = true` and ideally clear/ignore `scanFilter` for scan matching — matching “empty filter is not a live background scan.”
3. Optionally document the chosen semantics next to `simulateStateRestoration`.

### Proposed API (minimal / optional)

No new API strictly required if the init logic above is fixed. Optional knobs if callers need the old behavior:

```swift
/// When true (default false after the fix), restoring non-nil scan keys
/// immediately sets `isScanning = true` even if services are empty / radio off.
public static var simulateRestoredScanAsAlreadyActive: Bool = false
```

---

## Gap 2 — Restored peripherals cannot be `.disconnected`

### Current behavior (1.0.6)

`CBMPeripheralMock.init(basedOn:by:andRestoreState: true)`:

```swift
if restore {
    guard mock.services != nil else {
        // non-connectable → ignored
        return
    }
    self.state = mock.isConnected && mock.proximity != .outOfRange
        ? .connected
        : .connecting
}
```

Restored connectable peripherals are **only** `.connected` or `.connecting`. There is no path to `.disconnected` (or `.disconnecting`) on the restore path. Specs built without a prior virtual connection still become `.connecting` when `restore == true`.

### Why it blocks faithful tests

Apple’s docs / practice: iOS does **not** put disconnected peripherals in the restore dictionary. Defensive client code still switches on `peripheral.state` for unexpected values. ReliaBLE’s switch includes a `.disconnected` arm that must stay covered; today that arm is only hit via a direct-handler unit test with a hand-built payload, not via central init + `simulateStateRestoration`.

### Proposed behavior / API

Allow the restore fixture to control peripheral state explicitly, e.g.:

**Option A — richer restore dictionary entries (preferred):**

```swift
// In simulateStateRestoration return value:
// CBMCentralManagerRestoredStatePeripheralsKey → [CBMRestoredPeripheral]
public struct CBMRestoredPeripheral {
    public let spec: CBMPeripheralSpec
    /// State presented on the restored CBMPeripheralMock. Default: current
    /// connected/connecting inference from spec + proximity.
    public var state: CBMPeripheralState = /* inferred */
}
```

**Option B — keep `[CBMPeripheralSpec]` but honor a restore-time override on the spec:**

```swift
extension CBMPeripheralSpec {
    /// If non-nil, `andRestoreState: true` uses this instead of connected/connecting inference.
    public var restoredStateOverride: CBMPeripheralState? { get set } // or builder API
}
```

Either way, when override/explicit state is `.disconnected`, the mock should still deliver the peripheral in `willRestoreState`’s peripherals array (so clients can exercise defensive handling) without implying an active link (`virtualConnections` / GATT should match disconnected).

---

## Gap 3 — No on-demand `willRestoreState` after central creation

### Current behavior (1.0.6)

`simulateStateRestoration` is consulted **only** inside `init(delegate:queue:options:)` when a restore identifier option is present. After that, there is no public API to:

- Re-fire `willRestoreState` on an existing manager
- Deliver a second restore dictionary (e.g. testing handler idempotency)
- Inject restore after the central was created without a restore id (negative / ordering tests)

`initialize()` always schedules `centralManagerDidUpdateState` asynchronously on the manager queue; restore is always “once, sync, during init.”

### Why it blocks faithful tests

Most production code only needs the init-time path (and ReliaBLE’s cold-relaunch suite now uses it). Remaining needs:

- Handler **idempotency** / double-delivery without tearing down the stack
- Ordering experiments (`didUpdateState` already delivered, then restore) without relying solely on race timing of async state vs sync restore
- Injecting restore into a long-lived test central when spinning a second manager is undesirable

These are lower priority than Gaps 1–2; Gap 3 is a convenience. Workarounds: tear down + recreate with a new fixture, or keep a library-internal direct-handler hook (what we do today).

### Proposed API

```swift
extension CBMCentralManagerMock {
    /// Delivers `centralManager(_:willRestoreState:)` on this instance’s delegate
    /// with a dictionary built like init-time restoration (specs → peripheral mocks,
    /// scan keys, optional isScanning policy from Gap 1).
    ///
    /// - Parameter state: Same shape as `simulateStateRestoration` return value.
    /// - Parameter queue: If true (default), hop to the manager’s queue; if false,
    ///   invoke synchronously (mirrors init-time delivery).
    public func simulateWillRestoreState(
        _ state: [String: Any],
        deliverOnManagerQueue: Bool = true
    )
}
```

Semantics to document:

- Should **merge** restored peripherals into `manager.peripherals` the same way init does
- Should apply the **same** scan / `isScanning` rules as Gap 1’s fixed init path
- No-op or assert if `delegate == nil`
- Does not change `CBMCentralManagerMock.managerState` by itself

---

## Priority for ReliaBLE

| Gap | Blocks faithful tests today? | Upstream priority |
|---|---|---|
| 1 `isScanning` on restore | Yes (2 scenarios) | **High** |
| 2 `.disconnected` restored peripheral | Yes (1 defensive arm) | **Medium** (iOS doesn’t do this; still useful for clients) |
| 3 On-demand `willRestoreState` | Convenience only | **Low** |

Until Gap 1 (and optionally 2) land upstream, ReliaBLE keeps those cases as **direct-handler** unit tests and uses `simulateStateRestoration` for all other restoration coverage.

## Non-goals / out of scope for this request

- Simulating `CBConnectPeripheralOptionEnableAutoReconnect` system reconnect (separate limitation; not re-litigated here)
- Multi-process restoration domains
- Changing when `centralManagerDidUpdateState` fires relative to restore (init-time restore-before-async-state is already usable)

## How we verified

Pinned package: `IOS-CoreBluetooth-Mock` **1.0.6** / `5748c9e8b1750e0d7bc09243c099ff618f211cdf`.  
Read: `.build/checkouts/IOS-CoreBluetooth-Mock/CoreBluetoothMock/CBMCentralManagerMock.swift` (restore init, `simulateStateRestoration`, `CBMPeripheralMock` restore initializer).  
Design backdrop: `docs/designs/bluetoothactor-instance-isolation-2026-07-19.md` work item 7.
