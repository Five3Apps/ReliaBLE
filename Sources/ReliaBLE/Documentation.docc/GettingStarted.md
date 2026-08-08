# Getting Started

Installing ReliaBLE to your project, configuration and some starter examples of the core functionality.

## Overview

[TODO] More details coming soon.

## Installing ReliaBLE

Installing and initializing ReliaBLE is very simple.

1. Initalize a ``ReliaBLEConfig`` object.
2. Customize the config as desired.
3. Initialize ``ReliaBLEManager`` with the config.

Basic initialization with logging enabled:
```swift
let bleConfig = ReliaBLEConfig()
bleConfig.loggingEnabled = true

let bleManager = ReliaBLEManager(config: bleConfig)
```

Most apps need a single ``ReliaBLEManager`` for the lifetime of the process. If you do create more than one, each is a **fully isolated stack** — its own actor, `CBCentralManager`, discovered peripherals, connection state, and streams — configured independently by the config you pass. Two rules apply when running managers side by side: Bluetooth authorization is process-global (authorizing one manager authorizes them all), and any ``ReliaBLEConfig/restoreIdentifier`` must be unique among simultaneously-live managers while remaining stable across launches. See <doc:Multi-Manager> for the full model.

## Authorizing Bluetooth

iOS requires permission from the user for BLE access. To set this up in your project:

1. Add the required permission keys to your Info.plist:
   - `NSBluetoothAlwaysUsageDescription` (iOS 13+)
   - `NSBluetoothPeripheralUsageDescription` (iOS 12 and earlier)

   These keys should include a clear description of why your app needs Bluetooth access. Think about the need from your user's perspective and how Bluetooth provides value to them.

   ```xml
   <key>NSBluetoothAlwaysUsageDescription</key>
   <string>This app uses Bluetooth to collect your health data from your wearable device.</string>
   ```

2. Request authorization when needed.

   ReliaBLE does not automatically request authorization so that you are in control of when the user is prompted. To request Bluetooth permission from the user:
   ```swift
   do {
       try await bleManager.authorizeBluetooth()
   } catch AuthorizationError.denied {
       // Handle denied authorization
   } catch AuthorizationError.restricted {
       // Handle restricted authorization
   } catch {
       // Handle other errors
   }
   ```

3. (Optional) Monitor Bluetooth state changes by iterating the ``ReliaBLEManager/state`` stream. It is an `AsyncStream`, so consume it with `for await` — typically inside a SwiftUI `.task { … }`, which cancels the loop when the view disappears:
   ```swift
   for await state in bleManager.state {
       switch state {
       case .ready:
           // Bluetooth is ready to use
       case .unauthorized(let authStatus):
           // Handle unauthorized state
       case .poweredOff:
           // Prompt user to enable Bluetooth
       default:
           break
       }
   }
   ```
   The current state is replayed as the stream's first element, so a new subscriber immediately observes the latest state.

Note: When authorization has not yet been determined, `ReliaBLEManager.authorizeBluetooth()` presents the system prompt and **suspends until the user responds** — it returns normally only once access is granted, and throws ``AuthorizationError`` if the user denies or access is restricted. A successful return therefore means Bluetooth is authorized. Cancelling the calling task unblocks the suspension with a `CancellationError`.

The prompt only appears once, and it is safe to call the method multiple times: if the user already granted permission the call returns immediately; if they denied it, they'll need to re-enable access through the Settings app.

## Scanning for Peripherals

Once Bluetooth is authorized, you can start scanning for nearby Bluetooth Low Energy (BLE) peripheral devices, optionally filtering by specific services.

The ReliaBLEManager provides methods to control scanning:

1. Ensure Bluetooth is ready before scanning. Scanning won't work if Bluetooth is unauthorized or powered off.
2. Use ``ReliaBLEManager/startScanning(services:)`` to begin discovering peripherals. You can pass an optional array of `CBUUID` objects to filter for peripherals advertising specific services, or omit the parameter to scan for all peripherals.
3. Use ``ReliaBLEManager/stopScanning()`` to stop the scan when done.

Example of starting and stopping a scan for all peripherals:

```swift
// Check if Bluetooth is ready
if await bleManager.currentState == .ready {
    try await bleManager.startScanning()

    // Stop scanning after 10 seconds
    try? await Task.sleep(for: .seconds(10))
    await bleManager.stopScanning()
} else {
    // Handle Bluetooth not ready (e.g., prompt user to enable Bluetooth)
    print("Bluetooth is not ready for scanning")
}
```

Example of scanning for peripherals with specific services (e.g., Heart Rate and Battery):

```swift
import CoreBluetooth

// Check if Bluetooth is ready
if await bleManager.currentState == .ready {
    let serviceUUIDs = [CBUUID(string: "180D"), CBUUID(string: "180F")] // Heart Rate and Battery services
    try await bleManager.startScanning(services: serviceUUIDs)

    // Stop scanning after 10 seconds
    try? await Task.sleep(for: .seconds(10))
    await bleManager.stopScanning()
} else {
    // Handle Bluetooth not ready (e.g., prompt user to enable Bluetooth)
    print("Bluetooth is not ready for scanning")
}
```

You can monitor the ``ReliaBLEManager/state`` stream (as shown in the Authorizing Bluetooth section) to ensure Bluetooth is in the `.ready` state before calling `startScanning()`. Scanning will continue until you explicitly call `stopScanning()` or if Bluetooth becomes unavailable.

## Observing Discovered Peripherals

While scanning, ReliaBLE surfaces results two ways:

- ``ReliaBLEManager/peripheralDiscoveries`` emits a lightweight ``PeripheralDiscoveryEvent`` for every advertisement received — useful when you need to process individual advertisement packets.
- ``ReliaBLEManager/discoveredPeripherals`` emits the current de-duplicated list of ``DiscoveredPeripheral`` snapshots each time it changes.

Both are `AsyncStream`s. Each property access returns a *fresh, independent* stream, so multiple subscribers are supported by design — consume each with `for await`, typically inside a SwiftUI `.task { … }` (which cancels the loop automatically when the view disappears). ``ReliaBLEManager/state`` and ``ReliaBLEManager/discoveredPeripherals`` replay their latest value to every new subscriber; ``ReliaBLEManager/peripheralDiscoveries`` does **not** replay, so subscribe before you start scanning to avoid missing early advertisements. The discoveries feed is also bounded, so a subscriber that consumes slower than advertisements arrive drops the oldest pending events rather than growing memory without bound.

A ``DiscoveredPeripheral`` is an immutable, `Sendable` value snapshot: it carries the device's ``DiscoveredPeripheral/id``, ``DiscoveredPeripheral/name``, ``DiscoveredPeripheral/rssi``, ``DiscoveredPeripheral/lastSeen``, and a strongly-typed ``AdvertisementData`` rather than a raw `[String: Any]` dictionary. Because it is a value type, it is safe to diff and to hand straight to your UI.

To *act* on a device — connect, disconnect, or read its last-known metadata — cross over to its control handle via ``DiscoveredPeripheral/peripheral``:

```swift
for await peripherals in bleManager.discoveredPeripherals {
    for snapshot in peripherals {
        print(snapshot.name ?? snapshot.id, snapshot.advertisement?.serviceUUIDs ?? [])
        let handle = snapshot.peripheral  // same object `manager.peripheral(id:)` returns
    }
}
```

If your app already knows a peripheral's identity ahead of time — for example, a wearable bound to the user's account — obtain a handle directly through ``ReliaBLEManager/peripheral(id:)``:

```swift
let band = bleManager.peripheral(id: "user-band")
```

Such a handle carries no ``Peripheral/advertisement`` and throws ``PeripheralError/notFound`` from ``Peripheral/connect(autoReconnect:)`` until discovery or state restoration matches it to a real device.

## Connecting & Managing Peripherals

All actions — connect, disconnect, and reading last-known metadata — live on a ``Peripheral`` **handle**, not on the manager. Obtain a handle from a discovery snapshot or from a known identifier (see the previous section), then act on it directly:

```swift
let band = bleManager.peripheral(id: "user-band")
try await band.connect()
// … session …
try await band.disconnect()
```

``Peripheral/connect(autoReconnect:)`` is an `async throws` call that throws ``PeripheralError/notFound`` when the device has never been discovered and ``PeripheralError/bluetoothUnavailable`` when the manager that vended the handle has been deallocated or shut down.

### Reading handle metadata

A ``Peripheral`` handle carries synchronous, cached, **last-known** metadata:

- ``Peripheral/name``, ``Peripheral/rssi``, ``Peripheral/lastSeen``, ``Peripheral/advertisement`` — from the most recent discovery
- ``Peripheral/connectionState`` — mirrored from the library's internal connection tracking

All of these are synchronous (no `await`) so they read inline from SwiftUI row bodies.

> **Important: there is no change notification.** ``Peripheral`` is a plain `Sendable` class — it is not `@Observable` and publishes nothing. A view that reads handle metadata directly will render once and go stale. Re-read metadata inside the ``ReliaBLEManager/discoveredPeripherals`` loop (which emits on every advertisement, serving as the "something changed" tick), and re-read ``Peripheral/connectionState`` inside a ``ReliaBLEManager/connectionStateChanges`` loop. Without this your "my devices" list stops updating after the first render.

### Observing connection state

Consume ``ReliaBLEManager/connectionStateChanges`` (an `AsyncStream<ConnectionStateChange>`) to observe the full lifecycle — filter by ``ConnectionStateChange/peripheralId`` for a specific device:

```swift
for await change in manager.connectionStateChanges where change.peripheralId == band.id {
    switch change.state {
    case .connected:
        print("Connected to \(band.id)")
    case .disconnected(let reason):
        print("Disconnected", reason ?? "clean")
    case .reconnecting(let source, _, _):
        print("Reconnecting (\(source))")
    default:
        break
    }
}
```

Each access to `connectionStateChanges` yields a fresh stream with no replay, so begin iteration before calling ``Peripheral/connect(autoReconnect:)``.

### Reconnection

Reconnection is **on by default** via the `autoReconnect` parameter (default `true`). ReliaBLE uses a **two-tier model**:

1. **Tier 0 — System-managed (primary).** The connection request includes `CBConnectPeripheralOptionEnableAutoReconnect`, which asks the iOS daemon to re-establish the link itself after an unexpected drop. This is power-efficient, daemon-held, and keeps trying across app suspension. While the system retries, ReliaBLE emits ``ConnectionState/reconnecting(source:attempt:nextRetryAt:)`` with ``ReconnectSource/system`` (`attempt` and `nextRetryAt` are both `nil` — iOS exposes neither).
2. **Tier 1 — Library-managed (supplement).** Covers what the OS option doesn't: initial-connect failures and drops where the OS gives up. The library arms an exponential-backoff ladder governed by ``ReconnectPolicy``, emitting ``ReconnectSource/library`` with populated `attempt` and `nextRetryAt` so your UI can show a countdown.

To disable auto-reconnect for a one-shot connection, pass `autoReconnect: false`:

```swift
try await band.connect(autoReconnect: false)
```

Tune the library backoff via ``ReliaBLEConfig/reconnectPolicy``:

```swift
var config = ReliaBLEConfig()
config.reconnectPolicy.maxAttempts = 3
config.reconnectPolicy.initialDelay = 1.0   // seconds before first retry
config.reconnectPolicy.maxDelay = 10.0      // cap exponential growth
config.reconnectPolicy.jitter = 0.2         // ±20% randomization
let bleManager = ReliaBLEManager(config: config)
```

> Note: iOS's Tier-0 auto-reconnect give-up budget and timing are not publicly documented. The exact retry duration and failure threshold still require on-device verification.

For keeping a session alive while your app is backgrounded or after it is
terminated by the system, see <doc:Background>.
