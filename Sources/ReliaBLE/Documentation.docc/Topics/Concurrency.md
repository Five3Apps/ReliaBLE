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
`actor` (`BluetoothActor`) that serializes all Core Bluetooth interactions.
Because the manager is `Sendable` and nonisolated, you can hold a single
instance and share it freely across isolation domains — there is no implicit
`@MainActor` requirement and no forced main-thread hop.

`BluetoothActor` is a plain `actor` **instance owned by each manager** — not a
`@globalActor` and not a shared singleton. Every ``ReliaBLEManager`` creates and
holds its own actor, so each manager is a self-contained isolated stack (see
**One stack per manager**, below).

```
ReliaBLEManager (nonisolated, Sendable)
        │  forwards async calls
        ▼
BluetoothActor (per-manager actor instance, internal)
        │  serializes all access
        ▼
CBCentralManager delegate shim
        │
        ▼
CoreBluetooth
```

`BluetoothActor` is an **internal** implementation detail. Consumers must not
reference it; interact only through ``ReliaBLEManager``.

### One stack per manager

Each ``ReliaBLEManager`` is a **fully isolated stack**: its own actor,
`CBCentralManager`, discovered-peripheral snapshots, connection state, and event
streams. Constructing a second manager gives you a second, independent stack —
their discovered peripherals, connection state, and streams never cross over.
Two managers scanning the same physical device each hold their own
``Peripheral`` snapshot; there is no shared, cross-manager discovered list.

A few things are shared at the process level and are worth keeping in mind when
you run more than one manager at once:

- **Authorization is process-global.** `CBCentralManager.authorization` is
  app-wide, so calling ``ReliaBLEManager/authorizeBluetooth()`` on one manager
  affects every other manager in the process. Stacks are isolated in *state*,
  not in *permission*.
- **The Bluetooth radio is shared.** Running multiple concurrent, aggressive
  scans degrades all of them — prefer a single scanning manager, or coordinate
  scan windows yourself.
- **Restore identifiers must be unique among simultaneously-live managers.** If
  two live managers use the same ``ReliaBLEConfig/restoreIdentifier`` they
  contend for the same reconnect-intent storage and CoreBluetooth's per-id
  restoration domain, which is unsupported. Reusing the *same* identifier across
  app launches, however, is **required** for state restoration to work. See
  <doc:Background>.

> Note: A live subscriber stream retains its manager's stack until the stream
> terminates. As long as you are iterating one of the event streams below, the
> underlying actor and central stay alive — dropping your reference to the
> manager alone is not enough to tear the stack down.

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
