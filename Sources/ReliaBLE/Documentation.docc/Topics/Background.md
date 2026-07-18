# Background Scanning & State Restoration

Keep a BLE session alive across app suspension and termination.

## Overview

iOS can terminate your app while it is in the background. ReliaBLE supports
CoreBluetooth state restoration so the system can relaunch you into a working
BLE session — restoring an active scan and any connected or connecting
peripherals — without losing state.

## Prerequisites

1. Add `bluetooth-central` to the `UIBackgroundModes` array in your
   `Info.plist`. Without this entry, your app cannot scan in the background
   and will not be relaunched for BLE events.

   ```xml
   <key>UIBackgroundModes</key>
   <array>
       <string>bluetooth-central</string>
   </array>
   ```

2. Set a stable ``ReliaBLEConfig/restoreIdentifier`` on your configuration.
   This value **must be the same across launches** — changing it breaks the
   restoration chain. Use a fixed string, such as a bundle-derived constant:

   ```swift
   var config = ReliaBLEConfig()
   config.restoreIdentifier = "\(Bundle.main.bundleIdentifier!).ble-central"
   let bleManager = ReliaBLEManager(config: config)
   ```

   When `restoreIdentifier` is set, constructing ``ReliaBLEManager`` with
   an already-authorized Bluetooth state creates the underlying central
   manager immediately (with its delegate attached) so that the
   `willRestoreState` callback is reachable on relaunch. The authorization
   gate (`.allowedAlways`) is unchanged — the prompt still belongs to your
   app via ``ReliaBLEManager/authorizeBluetooth()``.

> Note: This eager central-manager creation is the one exception to ReliaBLE's
> otherwise lazy initialization. When ``ReliaBLEConfig/restoreIdentifier`` is
> set and Bluetooth authorization is already `.allowedAlways`, the internal
> central manager is created eagerly at ``ReliaBLEManager`` init (with its
> delegate attached) so that the `willRestoreState` callback is reachable on
> relaunch. The authorization gate and lazy-prompt contract are otherwise
> unchanged — setting a restore identifier without `.allowedAlways` auth does
> not create the central early.

## Background scanning

When scanning in the background, iOS requires a **non-nil, non-empty service
filter**. Scans with `nil` or empty `services` return no discoveries while
your app is backgrounded; the same call works normally in the foreground.

```swift
// Always pass a service filter for background-capable scans.
await bleManager.startScanning(services: [CBUUID(string: "180D")])
```

> Important: Background advertisement data may be truncated or absent compared
> to foreground scans. ``AdvertisementData`` fields that originate from scan
> response data (such as local name) are especially affected.

## Restored connections

If your app had connected or connecting peripherals when it was terminated,
those connections are restored automatically. You do **not** call a separate
restoration API — restored peripherals appear on the same streams you already
use:

- ``ReliaBLEManager/discoveredPeripherals`` emits restored peripherals (along
  with any newly discovered ones).
- ``ReliaBLEManager/connectionStateChanges`` emits the rehydrated connection
  states — ``ConnectionState/connected`` for preserved connections,
  ``ConnectionState/connecting`` for in-progress attempts.

Restored peripherals are **not** emitted on
``ReliaBLEManager/peripheralDiscoveries`` — restoration carries no
advertisement payload or RSSI, so that feed remains reserved for real
advertisements.

The Tier-0 system-managed reconnection (``ReconnectSource/system``) survives
app termination because it runs in the iOS daemon. Tier-1 library-managed
reconnection (``ReconnectSource/library``) does not, so ReliaBLE persists your
per-connect intent: when you call ``ReliaBLEManager/connect(to:autoReconnect:)``
with `autoReconnect: true` (and a ``ReliaBLEConfig/restoreIdentifier`` is
configured), that intent is stored in `UserDefaults` and re-armed for the
restored connection on relaunch, so a post-relaunch drop still triggers the
exponential-backoff ladder governed by ``ReconnectPolicy``. Connections made
with `autoReconnect: false` are restored — their state and live reference are
rehydrated — but reconnection stays disarmed.

> Note: Restored `CBPeripheral` objects arrive without a peripheral-level
> delegate. ReliaBLE does not yet use peripheral (GATT) callbacks, so no
> delegate is re-attached during restoration. When GATT support lands, the
> restoration path must also re-wire the peripheral delegate.

> Note: ReliaBLE deliberately does **not** pass
> `CBConnectPeripheralOptionNotifyOnConnection` or
> `CBConnectPeripheralOptionNotifyOnDisconnection`. These options cause iOS to
> post a system alert when your app is not running and a connection or
> disconnection occurs. They can be added non-breakingly in a future release
> if a use case emerges.
