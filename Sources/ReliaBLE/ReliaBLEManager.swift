//
//  ReliaBLEManager.swift
//  ReliaBLE
//
//  Created by Justin Bergen on 11/18/24.
//
//  Copyright (c) 2024 Five3 Apps, LLC <justin@five3apps.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import CoreBluetooth
import Foundation

import Willow

/// The main entry point for the ReliaBLE library.
///
/// `ReliaBLEManager` is a `nonisolated`, `Sendable` value-like façade: it owns no mutable state and
/// forwards every operation to its owned `BluetoothActor` that serializes all Core Bluetooth
/// interactions. Because it is not bound to any actor, it is callable directly from `@MainActor`
/// SwiftUI code *and* from background actors without forcing a main-actor hop on background callers.
public final class ReliaBLEManager: Sendable {
    public let loggingService: LoggingService

    /// Per-manager BLE stack. Internal so `@testable` tests can reach actor hooks.
    ///
    /// Retain graph (no cycles): manager → actor → central → shim; shim holds only the
    /// event-pipeline continuation (no actor ref). `delegateEventTask` and reconnect tasks
    /// capture `[weak self]`. Live stream subscribers retain the actor until terminated.
    let bluetooth: BluetoothActor

    /// Per-manager store of ``Peripheral`` handles, which is what makes ``peripheral(id:)`` synchronous and what
    /// guarantees one handle instance per id per manager. Owned here rather than by the actor because handles must
    /// be obtainable from a SwiftUI body and before any `CBCentralManager` exists.
    let handleRegistry: PeripheralHandleRegistry

    /// Initializes the ReliaBLEManager with the provided configuration, or a default configuration if none is provided.
    ///
    /// Initializing a ReliaBLEManager does not start the `CBCentralManager` unless the user has already authorized
    /// Bluetooth. This allows the integrating app to control when and how Bluetooth authorization is presented to the
    /// user. When the integrating app desires to request Bluetooth authorization from iOS it can call ``authorizeBluetooth()``.
    ///
    /// - Parameter config: A ReliaBLEConfig with the desired configurations set. If the value is `nil`, a default
    /// configuration is used. See ``ReliaBLEConfig`` for details on the default configuration.
    public init(config: ReliaBLEConfig = ReliaBLEConfig()) {
        loggingService = LoggingService(levels: config.logLevels, writers: config.logWriters, queue: config.logQueue)
        loggingService.enabled = config.loggingEnabled

        // Two-phase construction, and it has to be this way: `self` is unusable until every stored property is
        // initialized, so the registry cannot be handed its manager up front — and `bluetooth` needs the registry.
        // Create the registry unattached, inject it, then bind the manager once initialization is complete.
        handleRegistry = PeripheralHandleRegistry()

        bluetooth = BluetoothActor(
            log: loggingService,
            reconnectPolicy: config.reconnectPolicy,
            restoreIdentifier: config.restoreIdentifier,
            registry: handleRegistry
        )

        handleRegistry.attach(manager: self)

        // `init` stays synchronous and kicks off central creation via a fire-and-forget `Task`
        // rather than awaiting it, so the initializer never blocks. To prevent an operation invoked
        // immediately after `init` from racing ahead of that setup, every operational entry point
        // funnels through `ensureCentralManager()` (which is idempotent) before acting — so this
        // eager call is an optimization, not a correctness requirement.
        Task {
            await bluetooth.ensureCentralManager()
        }
    }

    // MARK: - State

    /// A multi-subscriber `AsyncStream` of real-time state changes of the underlying Core Bluetooth
    /// system. Each property access returns a fresh, independent stream; the current state is
    /// replayed as the first element, so a new subscriber immediately observes the latest state.
    ///
    /// Consume it with `for await`:
    /// ```swift
    /// for await state in bleManager.state {
    ///     // react to state
    /// }
    /// ```
    public var state: AsyncStream<BluetoothState> {
        bluetooth.stateStream()
    }

    /// Asynchronous, thread-safe access to the current state of the underlying Core Bluetooth
    /// system. The read is serialized on the library's internal concurrency domain, so the access
    /// is `await`-ed.
    public var currentState: BluetoothState {
        get async { await bluetooth.currentBluetoothState }
    }

    /// A multi-subscriber `AsyncStream` of connection-state changes for all peripherals.
    ///
    /// Each property access returns a fresh, independent stream. This stream does **not** replay
    /// a value on subscription — subscribe before initiating connections to observe every
    /// transition. To filter for a single peripheral:
    /// ```swift
    /// for await change in manager.connectionStateChanges where change.peripheralId == device.id {
    ///     // handle change
    /// }
    /// ```
    public var connectionStateChanges: AsyncStream<ConnectionStateChange> {
        bluetooth.connectionStateChangesStream()
    }

    /// An async snapshot of the current per-peripheral connection states, useful for seeding
    /// a view on appearance without waiting for the next change event.
    public var currentConnectionStates: [String: ConnectionState] {
        get async { await bluetooth.currentConnectionStates }
    }

    // MARK: - Authorization

    /// Requests authorization to use Bluetooth, presenting the iOS permission prompt when authorization has not yet
    /// been determined.
    ///
    /// When authorization is undetermined this call **suspends until the user responds**, returning normally only
    /// once access is granted. If the user denies the prompt (or access is already denied/restricted) it throws. A
    /// successful return can therefore be relied upon to mean Bluetooth is authorized.
    ///
    /// - Throws: An ``AuthorizationError`` if the user has denied or restricted Bluetooth access.
    public func authorizeBluetooth() async throws {
        await bluetooth.ensureCentralManager()

        // Own the cancellation wiring here, in the nonisolated façade. When authorization is
        // undetermined the actor suspends until the decision resolves; cancelling the calling task
        // unblocks that wait with a `CancellationError` rather than hanging indefinitely.
        let id = UUID()
        try await withTaskCancellationHandler {
            try await bluetooth.authorize(id: id)
        } onCancel: {
            Task { await bluetooth.cancelAuthorizationContinuation(id) }
        }
    }

    // MARK: - Scanning

    /// A multi-subscriber `AsyncStream` that emits peripheral discovery events during scanning. It
    /// is meant to be a lightweight advertisements feed for cases where the integrating app needs to
    /// process individual advertisements.
    ///
    /// Each property access returns a fresh, independent stream. Unlike ``state`` and
    /// ``discoveredPeripherals`` this stream does **not** replay a value on subscription — subscribe
    /// before you start scanning to avoid missing early advertisements.
    public var peripheralDiscoveries: AsyncStream<PeripheralDiscoveryEvent> {
        bluetooth.peripheralDiscoveriesStream()
    }

    /// A multi-subscriber `AsyncStream` that emits the current de-duplicated list of discovered
    /// peripherals each time it changes. Each property access returns a fresh, independent stream;
    /// the current list is replayed as the first element on subscription.
    public var discoveredPeripherals: AsyncStream<[DiscoveredPeripheral]> {
        bluetooth.discoveredPeripheralsStream()
    }

    /// Starts scanning for peripheral devices, optionally filtering by specific services.
    ///
    /// - Parameter services: An optional array of `CBUUID` objects representing the services to scan for. If provided,
    /// only peripherals advertising these services will be discovered. If `nil`, scans for all peripheral devices.
    ///
    /// - Note: If Bluetooth is not authorized or powered on, this method will not start scanning. It is the caller's
    /// responsibility to ensure that Bluetooth is authorized and powered on before calling this method.
    public func startScanning(services: sending [CBUUID]? = nil) async {
        await bluetooth.ensureCentralManager()
        await bluetooth.startScanning(services: services)
    }

    /// Stops scanning for peripheral devices.
    public func stopScanning() async {
        await bluetooth.ensureCentralManager()
        await bluetooth.stopScanning()
    }

    // MARK: - Peripherals

    /// Returns the control handle for a peripheral identifier, creating it on first request.
    ///
    /// This is the entry point for acting on a peripheral. Connecting, disconnecting, and reading last-known
    /// metadata all live on the returned ``Peripheral``:
    ///
    /// ```swift
    /// let band = manager.peripheral(id: "user-band")
    /// try await band.connect()
    /// ```
    ///
    /// Handles are **interned per manager**: calling this repeatedly with the same `id` returns the identical
    /// (`===`) object, and it is the same object ``DiscoveredPeripheral/peripheral`` resolves to. That makes a
    /// handle safe to store in a view model and rely on as a stable identity.
    ///
    /// The call is synchronous and requires no Bluetooth setup, so a peripheral the app already knows about — a
    /// wearable bound to the user's account, say — can be represented before it has ever been seen. Such a handle
    /// carries no metadata and throws ``PeripheralError/notFound`` from ``Peripheral/connect(autoReconnect:)`` until
    /// discovery or state restoration matches it to a real device. Matching is by identifier: a handle created as
    /// `"MyBand"` binds to a device that advertises the name `MyBand`.
    ///
    /// Two managers are two independent stacks, so each vends its own distinct handle for the same `id`.
    ///
    /// - Parameter id: The app-facing peripheral identifier.
    public func peripheral(id: String) -> Peripheral {
        handleRegistry.peripheral(id: id)
    }
}

// MARK: - Public Types

/// A typealias for the authorization status of the Core Bluetooth manager.
///
/// This typealias maps `CBManagerAuthorization` to `AuthorizationStatus`, providing a more readable and convenient
/// way to refer to the authorization status of the Bluetooth manager in the code.
public typealias AuthorizationStatus = CBManagerAuthorization

/// Represents the various states of the underlying Core Bluetooth system, as surfaced by ReliaBLE.
///
/// This enumeration provides a thread-safe representation of possible Bluetooth states that can be used across
/// concurrent environments.
public enum BluetoothState: Sendable {
    /// ReliaBLE is currently scanning for peripherals.
    case scanning
    /// Bluetooth is powered on and ReliaBLE is ready to use.
    case ready
    /// Bluetooth is currently powered off on the device.
    case poweredOff
    /// Indicates the connection with the system service was momentarily lost.
    ///
    /// This state indicates that Bluetooth is trying to reconnect. After it reconnects, ReliaBLE updates the
    /// state value.
    case resetting
    /// The app is not authorized to use Bluetooth. Associated value provides specific authorization status.
    case unauthorized(AuthorizationStatus)
    /// The platform doesn't support Bluetooth Low Energy.
    case unsupported
    /// The state of the underlying Core Bluetooth system is unknown.
    ///
    /// This is a temporary state. After Core Bluetooth initializes or resets, ReliaBLE updates the
    /// state value.
    case unknown

    /// A user-friendly string representation of the `BluetoothState`.
    ///
    /// - Returns: A string describing the `BluetoothState`.
    public var description: String {
        switch self {
        case .scanning:
            "Scanning"
        case .ready:
            "Ready"
        case .poweredOff:
            "Powered Off"
        case .resetting:
            "Resetting"
        case .unauthorized(let authorizationStatus):
            switch authorizationStatus {
            case .notDetermined:
                "Not Authorized"
            case .restricted:
                "Restricted"
            case .denied:
                "Denied"
            default:
                "Unauthorized"
            }
        case .unsupported:
            "Unsupported"
        case .unknown:
            "Unknown"
        }
    }
}

// MARK: Errors

/// A Swift error enumeration representing authorization-related errors in Bluetooth operations.
///
/// This type conforms to Swift's `Error` protocol and encapsulates various authorization failures that may occur
/// during Bluetooth operations.
public enum AuthorizationError: Error, Sendable {
    /// The user explicitly denied Bluetooth access for this app.
    case denied
    /// Indicates this app isn’t authorized to use Bluetooth.
    case restricted
    /// The authorization status is unknown.
    case unknown
}
