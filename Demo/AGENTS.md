# AGENTS.md

This file provides guidance to  AI Agents (Claude Code, Codex, Grok Build, OpenCode, etc.) when working with code in this repository.

## What this project is

The **ReliaBLE Demo** is a sample iOS app whose only purpose is to exercise and show off the ReliaBLE library that lives one directory up. It is not shipped, not a product, and not held to the same bar as the library:

- **Looser style bar.** The target does build under Swift 6 complete concurrency checking, but `@Observable` view models, `DispatchQueue.main`-based Combine sinks, `try?` discards, and `print(...)` for error paths are all fine here. Don't port library patterns (actors, custom `LoggingService`, three-target mocking, etc.) into the demo unless they're needed to talk to the library's public API.
- **Exploratory code is welcome.** Quick wiring, hardcoded values, `TODO` stubs, and view-model shortcuts are acceptable as long as they demonstrate a library feature clearly.
- **Don't refactor demo code "for quality"** unless asked. If something looks wrong in the demo, it's often deliberately minimal.

If you're working on a feature here and it forces you to also change the library, surface that — it usually means the library's public API needs work, which is a separate conversation.

## Build / run

Uses `CoreBluetooth` (central) and `CBPeripheralManager` (peripheral), plus SwiftData. The root workspace must be used — not the project file — so the local `ReliaBLE` package resolves correctly.

**Preferred: XcodeBuildMCP**

When using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools. Always verify defaults before the first build.

```
workspace: /path/to/ReliaBLE/ReliaBLE.xcworkspace
scheme:    ReliaBLE Demo
```

- Simulator: `build_run_sim` (BLE radio unavailable — UI only)
- Device: `build_run_device` with `-allowProvisioningUpdates`; on first run the user must trust the developer certificate at **Settings → General → VPN & Device Management**

Real device recommended for full BLE. The peripheral tab requires a device with a BLE radio to actually advertise.

To open in Xcode manually:

```sh
open ../ReliaBLE.xcworkspace        # from the Demo/ dir
```

Scheme: **"ReliaBLE Demo"**.

## App structure

`ReliaBLE Demo.xcodeproj` lives at `Demo/ReliaBLE Demo/ReliaBLE Demo.xcodeproj`. The app is a 3-tab SwiftUI app:

- **Central** (`Central/`) — uses `ReliaBLEManager` (the library) to scan, surfaces discoveries into a SwiftData store. `CentralView` subscribes to the library's `AsyncStream` surfaces in `.task { for await … }` loops; `CentralViewModel` holds UI state and BLE actions only. All SwiftData writes go through `DeviceStoreActor` (`@ModelActor`). State observed via `@Observable`.
- **Peripheral** (`Peripheral/`) — uses raw `CBPeripheralManager` directly (not the library — the library doesn't yet expose peripheral mode). This is intentional; the demo shows both sides of BLE even though only the central side flows through ReliaBLE.
- **Settings** (`Settings/`) — app-level toggles.

### How the library is wired in

- `ReliaBLE_DemoApp.swift` constructs a single `ReliaBLEManager` with `loggingEnabled = true` and injects it via a custom `EnvironmentKey` (`@Environment(\.bleManager)`).
- There's also a `BLEManagerKey.defaultValue` for previews — keep that working when changing the env injection.
- A `ModelContainer` for `Device` and `DiscoveryEvent` is set on the root scene. `CentralView` creates a `DeviceStoreActor` off the main thread via `DeviceStoreActor.create(container:)` and routes all SwiftData writes through it as the library emits events. Reads stay on `@MainActor` via `@Query`.

## Swift Concurrency

The library is built with Swift 6 and **complete concurrency checking**. Therefore, `ReliaBLE Demo` is also built with Swift 6 and complete concurrency checking.

### SwiftData models

- `Device` — one row per unique discovered peripheral (by `ReliaBLE.Peripheral.id`), updated on each `discoveredPeripherals` stream tick via `DeviceStoreActor.syncDevices`.
- `DiscoveryEvent` — one row per raw advertisement (every `peripheralDiscoveries` event), inserted via `DeviceStoreActor.insertDiscovery`. Grows quickly; "Clear All Data" in the Central view nukes both tables.

### Off-main persistence pattern

`DeviceStoreActor` is the canonical pattern for library consumers: hold `ReliaBLEManager` on the main actor, consume `AsyncStream`s in `.task`, and `await` the store for every SwiftData write. See the file-level comment in `Central/DeviceStoreActor.swift`.

## Don't

- Don't add the library's `CBCentralManagerFactory` indirection here — the demo imports `CoreBluetooth` directly for the peripheral side and that's fine.
- Don't replace `print(...)` debug calls in `CentralViewModel` with a logging service. The library has logging; the demo doesn't need one.
