# ReliaBLE

[![CI](https://github.com/Five3Apps/ReliaBLE/actions/workflows/ci.yml/badge.svg)](https://github.com/Five3Apps/ReliaBLE/actions/workflows/ci.yml)

A reliable, modern, and easy-to-use Swift package for apps that talk to Bluetooth Low Energy (BLE) peripherals.

## Overview

ReliaBLE is a **device-protocol-agnostic BLE Central core** for iOS and macOS. The
library owns the hard, reliability-sensitive parts of talking to a peripheral — link
lifecycle, GATT service/characteristic discovery and readiness, and the machinery that
runs commands against it — while your app owns the domain-specific packet content
(framing, CRC, application semantics). This lets you build robust device integrations
without becoming a CoreBluetooth expert.

It is built for apps that think in terms of **"my devices"** first — wearables, IoT
sensors, and smart-home accessories — so the public API is **device-centric**: you work
through a `Peripheral` handle rather than juggling a central manager for everyday tasks.
Generic "nearby scanner" experiences are supported too, but secondary.

> **Note:** ReliaBLE is under active development toward its v1 release and is not yet
> intended for production use. The public API may change before 1.0. See
> [`PRD.md`](PRD.md) for the full v1 target and current status.

### What it provides

- **Reliable communication** — not just a "connected" bit, but a link that stays up,
  discovery that reaches a *ready* state, and commands that run to completion, with a
  two-tier (system + library-managed exponential backoff) automatic reconnect model.
- **A device-centric API** — `ReliaBLEManager` owns authorization, Bluetooth state,
  scanning, and the peripheral registry; connection, discovery, and I/O live on
  `Peripheral` handles. Live CoreBluetooth objects never cross the public boundary.
- **App-controlled authorization** — ReliaBLE never triggers the iOS permission prompt
  on its own; you decide when it appears.
- **Scanning with rich advertisement data** — filter by service UUID, consume results as
  strongly-typed `AsyncStream`s, with background scanning and state restoration.
- **Multiple simultaneous peripherals** — connect to and manage many devices at once.
- **A command-style I/O protocol** — a flexible, app-defined protocol for read/write/
  notify, gated on discovery readiness *(v1 target)*.
- **Flexible, low-overhead logging** — enable/disable and route output as you choose.
- **Modern Swift 6 architecture** — builds under complete concurrency checking, isolating
  all CoreBluetooth usage in a single internal isolation domain.
- **High test coverage** — CoreBluetooth is mocked in tests, so behavior is verified in
  CI without physical hardware.

## Installation

### Swift Package Manager

- File > Swift Packages > Add Package Dependency
- Add https://github.com/Five3Apps/ReliaBLE.git
- Select "Up to Next Major" with "1.0.0"

## Documentation

- [ReliaBLE Documentation](https://five3apps.github.io/ReliaBLE/documentation/reliable/)
- [Getting Started](https://five3apps.github.io/ReliaBLE/documentation/reliable/gettingstarted)
