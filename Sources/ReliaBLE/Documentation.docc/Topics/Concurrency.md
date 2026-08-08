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
holds its own actor, so concurrent calls into one manager are serialized on that
manager's actor alone. For running more than one manager at once, see
<doc:Multi-Manager>.

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

> Note: `ReliaBLEManager` init never prompts for Bluetooth permission. Creating
> the internal central stays gated on existing `.allowedAlways` authorization so
> the prompt remains under your app's control via
> ``ReliaBLEManager/authorizeBluetooth()``. When authorization is already
> `.allowedAlways`, init eagerly creates the central (via a fire-and-forget
> `Task` into `BluetoothActor`) so a live stack is ready immediately.
> ``ReliaBLEConfig/restoreIdentifier`` only affects the options passed at that
> creation — it does not change *when* the central is created — so
> `willRestoreState` can be delivered on relaunch. See <doc:Background> for
> details.

### Calling actions

All mutating actions are `async` and hop onto the Bluetooth actor for you:

- ``ReliaBLEManager/authorizeBluetooth()``
- ``ReliaBLEManager/startScanning(services:)``
- ``ReliaBLEManager/stopScanning()``
- ``Peripheral/connect(autoReconnect:)``
- ``Peripheral/disconnect()``

> Note: ``ReliaBLEManager/startScanning(services:)`` now **throws**. A usable radio is awaited
> before scanning begins: a transient state (`.resetting` / `.unknown`) is awaited, while a
> terminal state (powered off or unsupported) fails fast with a typed ``PeripheralError``.
> Cancelling the calling task while the scan is parked on a transient state unblocks the pending
> radio wait with a `CancellationError`.

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

### Value types and handles

The value types you receive from streams — ``DiscoveredPeripheral``, ``AdvertisementData``,
and ``PeripheralDiscoveryEvent`` — are `Sendable` value types, so they cross
isolation boundaries freely.

``Peripheral`` is a checked `Sendable` `final class`, *not* a value type. It is
interned one-per-id-per-manager and carries synchronous, cached, last-known
metadata behind a single `Mutex`. The contract:

- No `CBPeripheral` or other CoreBluetooth object is ever stored on a handle.
- Metadata writes happen only from library-ordered paths (the Bluetooth actor's
  discovery and restore pipelines); the lock exists to make *reads* safe from any
  concurrency domain, not to order writes.
- The lock is never held across a suspension — `withLock` closures are
  non-`async`, and no CoreBluetooth call or `Task` creation occurs inside them.
- Per-property reads are **not** one atomic snapshot: reading ``Peripheral/name``
  then ``Peripheral/rssi`` can straddle two discovery updates.

Handles are not `@Observable` and publish nothing. Use
``ReliaBLEManager/discoveredPeripherals`` as the change-signal tick and re-read
handle metadata inside that loop.
