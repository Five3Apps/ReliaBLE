# ``ReliaBLE``

A reliable, modern, and easy-to-use Swift interface for apps that talk to Bluetooth Low Energy (BLE) peripherals.

## Overview

ReliaBLE is a **device-protocol-agnostic BLE Central core** for iOS and macOS. The
library owns the hard, reliability-sensitive parts of talking to a peripheral —
link lifecycle, GATT service/characteristic discovery and readiness, and the
machinery that runs commands against it — while your app owns the domain-specific
packet content (framing, CRC, application semantics). This separation lets you
build robust device integrations without becoming a CoreBluetooth expert.

It is built for apps that think in terms of **"my devices"** first: wearables,
IoT sensors, and smart-home accessories. Generic "nearby scanner" experiences are
supported too, but the design is optimized for connecting to and reliably
communicating with the specific devices your users own. To keep that model clean,
the public API is **device-centric** — you work through a ``Peripheral`` handle
rather than juggling a central manager for day-to-day tasks.

> Note: ReliaBLE is under active development toward its v1 release and is not yet
> intended for production use. The public API — particularly the `Peripheral`
> control-handle model — may change before 1.0. See the project `PRD.md` for the
> full v1 target and current status.

### What it provides

- **Reliable communication.** The focus is end-to-end reliability, not just a TCP-style
  "connected" bit: a link that stays up, discovery that reaches a *ready* state, and
  commands that run to completion. Automatic reconnection uses a two-tier model that
  combines the iOS system-managed reconnect with a configurable library-managed
  exponential-backoff ladder.
- **A device-centric public API.** ``ReliaBLEManager`` owns process-wide concerns —
  authorization, Bluetooth state, scanning, and the peripheral registry — while
  connection, discovery, and I/O are expressed against ``Peripheral`` handles. Live
  `CBPeripheral`, `CBService`, and `CBCharacteristic` objects never cross the public
  boundary.
- **App-controlled authorization.** ReliaBLE never triggers the iOS permission prompt
  on its own; you decide exactly when ``ReliaBLEManager/authorizeBluetooth()`` presents it.
- **Scanning with rich advertisement data.** Scan for all peripherals or filter by
  service UUID, and consume results as strongly-typed ``AdvertisementData`` snapshots
  through `AsyncStream`s — either per-advertisement (``PeripheralDiscoveryEvent``) or as a
  de-duplicated list of ``Peripheral`` values. Background scanning and state restoration
  are supported.
- **Multiple simultaneous peripherals.** Maintain connections to many devices at once,
  each with its own connection state and (in the v1 target) its own command queue.
- **A command-style I/O protocol.** A flexible, app-defined command protocol for
  reading, writing, and subscribing to characteristics, gated on discovery readiness so
  I/O never races ahead of the GATT table *(v1 target)*.
- **Flexible, low-overhead logging.** Enable or disable logging through the public API
  and direct output wherever you choose; when disabled it stays out of the hot path.
- **Modern Swift 6 architecture.** The library builds under complete concurrency
  checking and isolates all CoreBluetooth usage in a single internal isolation domain,
  so the public façade is safe to call without forcing `@MainActor` on your app.
- **High test coverage.** CoreBluetooth is mockable in tests (via Nordic's
  CoreBluetoothMock), so behavior is verified in CI without physical hardware.

See <doc:GettingStarted> to install ReliaBLE, authorize Bluetooth, scan for devices,
and open your first connection.

## Topics

### Essentials

- <doc:GettingStarted>

### Peripherals

- ``Peripheral``
- ``AdvertisementData``
- ``PeripheralDiscoveryEvent``
- ``PeripheralError``

### Concurrency & Isolation

- <doc:Concurrency>
- ``ReliaBLEManager``

### Advanced Usage

- <doc:Logging>
- <doc:Background>
