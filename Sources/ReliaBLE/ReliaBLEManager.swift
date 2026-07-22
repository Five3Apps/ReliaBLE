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
/// forwards every operation to its owned ``BluetoothActor`` that serializes all Core Bluetooth
/// interactions. Because it is not bound to any actor, it is callable directly from `@MainActor`
/// SwiftUI code *and* from background actors without forcing a main-actor hop on background callers.
public final class ReliaBLEManager: Sendable {
    public let loggingService: LoggingService

    private let log: LoggingService

    /// Per-manager BLE stack. Internal so `@testable` tests can reach actor hooks.
    let bluetooth: BluetoothActor

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

        log = loggingService

        bluetooth = BluetoothActor(
            log: loggingService,
            reconnectPolicy: config.reconnectPolicy,
            restoreIdentifier: config.restoreIdentifier
        )

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
    public var discoveredPeripherals: AsyncStream<[Peripheral]> {
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

    // MARK: - Connection

    /// Initiates a connection to a previously discovered peripheral.
    ///
    /// The ``Peripheral`` is a value snapshot captured at discovery time. This method forwards its ``Peripheral/id``
    /// to the live CoreBluetooth peripheral held internally and requests a connection.
    ///
    /// - Parameter peripheral: A peripheral previously delivered via ``discoveredPeripherals``.
    /// - Parameter autoReconnect: When `true` (the default), the library passes
    ///   `CBConnectPeripheralOptionEnableAutoReconnect` to the system and arms the app-side
    ///   exponential-backoff ladder for cases the OS option doesn't cover. Set to `false` for
    ///   one-shot connections where reconnection is not desired.
    /// - Throws: ``PeripheralError/notFound`` if the peripheral's live reference has been invalidated (a stale
    ///   snapshot), or ``PeripheralError/bluetoothUnavailable`` if Bluetooth has not been set up (for example, not
    ///   yet authorized).
    public func connect(to peripheral: Peripheral, autoReconnect: Bool = true) async throws {
        await bluetooth.ensureCentralManager()
        try await bluetooth.connect(id: peripheral.id, autoReconnect: autoReconnect)
    }

    /// Initiates a disconnection from a previously connected peripheral.
    ///
    /// The ``Peripheral`` is a value snapshot. This forwards its ``Peripheral/id`` to the live
    /// CoreBluetooth peripheral and cancels the connection.
    ///
    /// - Parameter peripheral: A peripheral previously delivered via ``discoveredPeripherals``.
    /// - Throws: ``PeripheralError/notFound`` if the peripheral's live reference has been
    ///   invalidated, or ``PeripheralError/bluetoothUnavailable`` if Bluetooth has not been set up.
    public func disconnect(from peripheral: Peripheral) async throws {
        await bluetooth.ensureCentralManager()
        try await bluetooth.disconnect(id: peripheral.id)
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
