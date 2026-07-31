# Multi-Manager

Patterns beyond the single-manager happy path: running more than one
``ReliaBLEManager``, and how configuration applies when you do.

## Overview

Most apps hold a single ``ReliaBLEManager`` for the process lifetime. When you
need more than one — for example, separate stacks for different product
features or test harnesses that drive two live centrals side by side — each
manager is an independent unit. This topic covers that multi-manager model and
the few process-level rules that still apply.

Each ``ReliaBLEManager`` is a **fully isolated stack**: its own actor,
`CBCentralManager`, discovered-peripheral snapshots, connection state, and event
streams. Constructing a second manager gives you a second, independent stack —
their discovered peripherals, connection state, and streams never cross over.
Two managers scanning the same physical device each hold their own
``Peripheral`` snapshot; there is no shared, cross-manager discovered list.

Configuration — including `ReconnectPolicy` and logging — is applied **per
manager**. The config you pass to `init(config:)` governs only that instance.
Constructing a second `ReliaBLEManager(config:)` with different settings gives
you a second, independently-configured stack; it does not affect the first.

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
> terminates. As long as you are iterating one of the event streams
> (``ReliaBLEManager/state``, ``ReliaBLEManager/discoveredPeripherals``,
> ``ReliaBLEManager/peripheralDiscoveries``, or
> ``ReliaBLEManager/connectionStateChanges``), the underlying actor and central
> stay alive — dropping your reference to the manager alone is not enough to
> tear the stack down.

For how each manager serializes Core Bluetooth work on its own actor, see
<doc:Concurrency>.
