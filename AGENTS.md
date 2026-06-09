# AGENTS.md

This file provides guidance to AI Agents (Claude Code, Codex, Grok Build, OpenCode, etc.) when working with code in this repository.

## Repository layout

Two related projects share this repo:

- **ReliaBLE library** (this directory) — Swift Package at `Package.swift` / `Sources/` / `Tests/`. swift-tools-version 6.1, iOS 18+ / macOS 10.15+, builds under **Swift 6 with complete concurrency checking**. This is the supported, shipped product.
- **Demo app** — `Demo/ReliaBLE Demo/`, consumes the library locally. Has its own `Demo/CLAUDE.md` with different conventions (looser concurrency, exploratory code). Treat it as a separate project — don't carry its patterns back into the library.

Open `ReliaBLE.xcworkspace` at the root to work on both together.

## Build, test

```sh
swift build                                          # build all targets
swift test                                           # run ReliaBLETests
swift test --filter ReliaBLETests.correctFunction    # single test
```

## Architecture

### Three-target SPM trick for CoreBluetooth mocking

The package declares **three targets** that share a single source tree to make `CoreBluetooth` mockable in tests without polluting the production binary:

- `ReliaBLE` — production target. Uses real `CoreBluetooth`. Includes `Sources/ReliaBLE/CBCentralManagerFactory.swift`, a thin enum that returns a real `CBCentralManager`.
- `ReliaBLEMock` — same sources as `ReliaBLE`, but **excludes** `CBCentralManagerFactory.swift` and the DocC catalog, and links `CoreBluetoothMock` (Nordic Semi). In `Sources/ReliaBLEMock/CoreBluetoothMockAliases.swift`, public typealiases rebind `CBCentralManager`, `CBPeripheral`, `CBCentralManagerFactory`, etc. to their `CBM*` mock counterparts.
- `ReliaBLETests` — depends on `ReliaBLEMock` (not `ReliaBLE`).

**Consequence:** the library code only ever calls `CBCentralManagerFactory.instance(...)`, never `CBCentralManager(...)` directly. The factory's identity is swapped at compile time per target. When editing core BLE code, keep this constraint — `import CoreBluetooth` is fine, but instantiate the central via the factory.

### Swift Concurrency

The library is built with Swift 6 and **complete concurrency checking**. The `ReliaBLEManager` public API should be callable from `@MainActor`, but the library itself should avoid `@MainActor` and instead use `@BluetoothActor` (a custom actor defined in `BluetoothManager.swift`) to serialize all Bluetooth interactions. This keeps the library thread-safe and allows the integrating app to decide how to bridge to the main thread for UI updates.

### Logging

`LoggingService` wraps Willow's `Logger` with an async execution queue. The service is `Sendable` and passed by reference into both managers. Default writer is an `OSLogWriter` (`subsystem: com.five3apps.relia-ble`, `category: BLE`), configurable via `ReliaBLEConfig`. Logging is **disabled by default** — `config.loggingEnabled` must be set to true. Log calls take a `tags: [LogTag]` array; use `.category(.scanning)`, `.peripheral(id)`, etc. rather than embedding the category in the message.

### Authorization flow

`ReliaBLEManager.init` does **not** instantiate `CBCentralManager` unless the user has already granted `.allowedAlways`. This is deliberate so the integrating app controls when the iOS permission prompt appears — callers invoke `authorizeBluetooth()` when they want the prompt. Preserve this lazy-init behavior when touching `BluetoothManager.setupCentralManager()`.

## Notes for editing

- Public API on `ReliaBLEManager` is the supported surface for external consumers. Adding/removing methods there is a breaking change.
- `forceMock: true` is currently passed to `CBCentralManagerFactory.instance(...)` in `BluetoothManager`. The production factory ignores this parameter; the mock factory honors it. Don't "clean it up" — it's load-bearing for the test target.
- DocC catalog lives at `Sources/ReliaBLE/Documentation.docc/`. The `swift-docc-plugin` is a package dep so `swift package generate-documentation` works. This documentation **must** be kept up to date with the public API on `ReliaBLEManager` and the overall architecture and usage patterns.
