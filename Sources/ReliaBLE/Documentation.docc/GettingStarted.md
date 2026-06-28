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
    await bleManager.startScanning()

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
    await bleManager.startScanning(services: serviceUUIDs)

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
- ``ReliaBLEManager/discoveredPeripherals`` emits the current de-duplicated list of ``Peripheral`` values each time it changes.

Both are `AsyncStream`s. Each property access returns a *fresh, independent* stream, so multiple subscribers are supported by design — consume each with `for await`, typically inside a SwiftUI `.task { … }` (which cancels the loop automatically when the view disappears). ``ReliaBLEManager/state`` and ``ReliaBLEManager/discoveredPeripherals`` replay their latest value to every new subscriber; ``ReliaBLEManager/peripheralDiscoveries`` does **not** replay, so subscribe before you start scanning to avoid missing early advertisements. The discoveries feed is also bounded, so a subscriber that consumes slower than advertisements arrive drops the oldest pending events rather than growing memory without bound.

A ``Peripheral`` is an immutable, `Sendable` value snapshot: it carries the peripheral's ``Peripheral/id``, ``Peripheral/name``, ``Peripheral/rssi``, ``Peripheral/lastSeen``, and a strongly-typed ``AdvertisementData`` rather than a raw `[String: Any]` dictionary. Because it is a value type, it is safe to hand directly to your UI.

```swift
for await peripherals in bleManager.discoveredPeripherals {
    for peripheral in peripherals {
        print(peripheral.name ?? peripheral.id, peripheral.advertisement?.serviceUUIDs ?? [])
    }
}
```

If your app already knows a peripheral's identity ahead of time — for example, a wearable bound to the user's account — you can construct a ``Peripheral`` directly with ``Peripheral/init(id:)``. Such a snapshot has no ``Peripheral/advertisement`` until ReliaBLE matches it against the corresponding device during discovery.

## Connecting to a Peripheral

Pass a discovered ``Peripheral`` to ``ReliaBLEManager/connect(to:)``. The snapshot carries only a stable identifier; ReliaBLE looks up the live CoreBluetooth peripheral it owns internally and initiates the connection.

```swift
do {
    try await bleManager.connect(to: peripheral)
} catch PeripheralError.notFound {
    // The snapshot is stale — its underlying peripheral reference was invalidated
    // (for example, after a Bluetooth reset). Re-scan to rediscover it.
} catch PeripheralError.bluetoothUnavailable {
    // Bluetooth has not been set up yet (for example, not authorized). Authorize and wait
    // for the `.ready` state before retrying.
}
```

- Note: `connect(to:)` currently initiates the connection request only. The full connection lifecycle (connection-state updates and disconnection handling) will arrive in a later release.
