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
       try bleManager.authorizeBluetooth()
   } catch AuthorizationError.denied {
       // Handle denied authorization
   } catch AuthorizationError.restricted {
       // Handle restricted authorization
   } catch {
       // Handle other errors
   }
   ```

3. (Optional) Monitor Bluetooth state changes by subscribing to the ``ReliaBLEManager/state`` publisher:
   ```swift
   bleManager.state
       .sink { state in
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
       .store(in: &cancellables)
   ```

Note: The authorization prompt will only appear once. It is safe to call `ReliaBLEManager.authorizeBluetooth()` multiple times. If the user already granted permission it will be a no-op. If the user denies permission, they'll need to enable it manually through the Settings app.

## Scanning for Peripherals

Once Bluetooth is authorized, you can start scanning for nearby Bluetooth Low Energy (BLE) peripheral devices.

The ReliaBLEManager provides methods to control scanning:

1. Ensure Bluetooth is ready before scanning. Scanning won't work if Bluetooth is unauthorized or powered off.
2. Use ``ReliaBLEManager/startScanning()`` to begin discovering peripherals.
3. Use ``ReliaBLEManager/stopScanning()`` to stop the scan when done.

Example of starting and stopping a scan:

```swift
// Check if Bluetooth is ready
if bleManager.currentState == .ready {
    bleManager.startScanning()

    // Stop scanning after 10 seconds
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        bleManager.stopScanning()
    }
} else {
    // Handle Bluetooth not ready (e.g., prompt user to enable Bluetooth)
    print("Bluetooth is not ready for scanning")
}
```

You can monitor the ``ReliaBLEManager/state`` publisher (as shown in the Authorizing Bluetooth section) to ensure Bluetooth is in the `.ready` state before calling `startScanning()`. Scanning will continue until you explicitly call `stopScanning()` or if Bluetooth becomes unavailable.
