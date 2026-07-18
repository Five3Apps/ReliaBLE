# Concurrency

How ReliaBLE isolates Bluetooth state and how to safely call it from your app.

## Overview

ReliaBLE is built with the Swift 6 language mode and complete strict concurrency
checking. Its public surface is designed so you can call it from anywhere — a
SwiftUI view on the `@MainActor`, a background actor, or a detached `Task` —
without manual locking or forced actor hops.

### The isolation contract

``ReliaBLEManager`` is a `nonisolated`, `Sendable` `final class`. It owns no
mutable state itself; instead it forwards every operation to an internal
`@globalActor` (`BluetoothActor`) that serializes all Core Bluetooth
interactions. Because the manager is `Sendable` and nonisolated, you can hold a
single instance and share it freely across isolation domains — there is no
implicit `@MainActor` requirement and no forced main-thread hop.

```
ReliaBLEManager (nonisolated, Sendable)
        │  forwards async calls
        ▼
BluetoothActor (@globalActor, internal)
        │  serializes all access
        ▼
CBCentralManager delegate shim
        │
        ▼
CoreBluetooth
```

`BluetoothActor` is an **internal** implementation detail. Consumers must not
reference it; interact only through ``ReliaBLEManager``.

> Note: The internal central manager is created lazily and only once Bluetooth
> authorization is `.allowedAlways` — the permission prompt stays under your
> app's control via ``ReliaBLEManager/authorizeBluetooth()``. The one exception:
> when ``ReliaBLEConfig/restoreIdentifier`` is set and authorization was already
> granted, the central is created eagerly at ``ReliaBLEManager`` init so state
> restoration can deliver its `willRestoreState` callback on relaunch. See
> <doc:Background> for details.

### Calling actions

All mutating actions are `async` and hop onto the Bluetooth actor for you:

- ``ReliaBLEManager/authorizeBluetooth()``
- ``ReliaBLEManager/startScanning(services:)``
- ``ReliaBLEManager/stopScanning()``
- ``ReliaBLEManager/connect(to:autoReconnect:)``

The current Bluetooth state is exposed as an `async` getter,
``ReliaBLEManager/currentState``:

```swift
let state = await manager.currentState
```

### Observing events

ReliaBLE exposes three event surfaces, each of which returns a **fresh,
per-subscriber** `AsyncStream`. Iterate them with `for await`, ideally from a
SwiftUI `.task` so iteration is tied to the view's lifetime:

```swift
.task {
    for await state in manager.state {
        self.state = state
    }
}
```

Replay semantics differ per stream:

- ``ReliaBLEManager/state`` — replays the **latest** value to new subscribers
  (`.bufferingNewest(1)`).
- ``ReliaBLEManager/discoveredPeripherals`` — replays the **latest** value to new
  subscribers (`.bufferingNewest(1)`).
- ``ReliaBLEManager/peripheralDiscoveries`` — does **not** replay; a new
  subscriber only receives discoveries that occur after it begins iterating. Its
  buffer is bounded (`.bufferingNewest`), so a slow subscriber drops the oldest
  pending advertisements rather than growing memory without bound.

Because each call returns an independent stream, multiple parts of your app can
observe the same surface concurrently without interfering with one another.

### Value types

The model types you receive — ``Peripheral``, ``AdvertisementData``, and
``PeripheralDiscoveryEvent`` — are `Sendable` value structs, so they cross
isolation boundaries freely.
