//
//  BluetoothManager.swift
//  ReliaBLE
//
//  Created by Justin Bergen on 1/16/25.
//
//  Copyright (c) 2025 Five3 Apps, LLC <justin@five3apps.com>
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

/// Internal intermediary that forwards BLE operations to ``BluetoothActor`` and exposes
/// synchronous `AsyncStream` properties for consumption by ``ReliaBLEManager``.
///
/// This class is removed in Step 4 when `ReliaBLEManager` collapses the indirection and
/// becomes `nonisolated Sendable`.
class BluetoothManager {
    private let log: LoggingService

    // MARK: - Initialization

    /// Initializes the BluetoothManager with the provided LoggingService. Initializing a BluetoothManager does not
    /// start the `CBCentralManager` *unless* the user has already authorized Bluetooth. This allows the integrating
    /// app to control when and how Bluetooth autorization is presented to the user.
    ///
    /// When the integrating app desires to request Bluetooth authorization from iOS it can call ``authorize()``.
    ///
    /// - Parameter loggingService: The LoggingService to use for logging.
    /// - Returns: A new instance of BluetoothManager.
    init(loggingService: LoggingService) {
        self.log = loggingService

        // `init` stays synchronous and dispatches actor setup via a fire-and-forget `Task`
        // rather than awaiting it. The initial `setupCentralManager()` (if already
        // `.allowedAlways`) and `updateState()` land on the actor's queue on the next
        // run-loop turn, which is indistinguishable from prior behavior for callers that
        // observe `state`/`currentState` after init.
        //
        // This does mean a caller that immediately awaits `startScanning()`/`stopScanning()`
        // could in theory have that call's actor job ordered ahead of `initialize`'s, since
        // Swift actors don't guarantee FIFO ordering across jobs enqueued from separate
        // top-level Tasks. Both methods already guard on `centralManager == nil` and no-op
        // with a log warning in that case, so the worst case is a missed scan start rather
        // than a crash. Revisit if this race proves observable in practice — e.g. by making
        // `init` `async` or exposing an explicit `await manager.ready()`.
        Task { await BluetoothActor.shared.initialize(log: loggingService) }
    }

    // MARK: - State

    /// A fresh `AsyncStream` of real-time state changes of the underlying Core Bluetooth system.
    /// Each access mints an independent stream via the ``BluetoothActor`` broadcaster.
    var state: AsyncStream<BluetoothState> {
        BluetoothActor.shared.stateStream()
    }

    /// Synchronous access to the current state of the underlying Core Bluetooth system.
    /// Reads the `nonisolated(unsafe)` snapshot on ``BluetoothActor``.
    var currentState: BluetoothState {
        BluetoothActor.shared.currentBluetoothState
    }

    // MARK: - Authorization

    /// Requests authorization to use Bluetooth. This method will throw an error if the user
    /// has denied or restricted Bluetooth access.
    ///
    /// - Throws: An ``AuthorizationError`` error if the user has denied or restricted Bluetooth
    ///   access.
    func authorize() async throws {
        try await BluetoothActor.shared.authorize()
    }

    // MARK: - Scanning

    /// A fresh `AsyncStream` that emits peripheral discovery events during scanning. It is meant to
    /// be a lightweight advertisements feed for cases where the integrating app needs to process
    /// individual advertisements. This stream does not replay; subscribe before scanning.
    var peripheralDiscoveries: AsyncStream<PeripheralDiscoveryEvent> {
        BluetoothActor.shared.peripheralDiscoveriesStream()
    }

    /// A fresh `AsyncStream` that emits the current list of discovered peripherals, replaying the
    /// latest list on subscription.
    var discoveredPeripherals: AsyncStream<[Peripheral]> {
        BluetoothActor.shared.discoveredPeripheralsStream()
    }

    /// Starts (or restarts) scanning for peripherals. If scanning is already in progress,
    /// this method will replace the current scan with a new scan.
    ///
    /// - Parameter services: An array of CBUUID objects that the app is interested in scanning
    ///   for. If the value is `nil`, the app scans for all peripherals.
    ///
    /// - Note: If Bluetooth is not authorized or powered on, this method will not start
    ///   scanning.
    func startScanning(services: sending [CBUUID]? = nil) async {
        await BluetoothActor.shared.startScanning(services: services)
    }

    /// Stops scanning for peripherals.
    func stopScanning() async {
        await BluetoothActor.shared.stopScanning()
    }

    // MARK: - Connection

    /// Initiates a connection to the given peripheral.
    ///
    /// - Parameter peripheral: A peripheral previously delivered via ``discoveredPeripherals``.
    /// - Throws: ``PeripheralError/notFound`` if the peripheral is no longer known to the library.
    func connect(to peripheral: Peripheral) async throws {
        try await BluetoothActor.shared.connect(id: peripheral.id)
    }
}

// MARK: - Public Types

/// A typealias for the authorization status of the Core Bluetooth manager.
/// 
/// This typealias maps `CBManagerAuthorization` to `AuthorizationStatus`, providing a more readable and convenient
/// way to refer to the authorization status of the Bluetooth manager in the code.
public typealias AuthorizationStatus = CBManagerAuthorization

/// Represents the various states of `BluetoothManager` and the underlying Core Bluetooth system.
///
/// This enumeration provides a thread-safe representation of possible Bluetooth states that can be used across
/// concurrent environments.
public enum BluetoothState: Sendable {
    /// The `BluetoothManager` is currently scanning for peripherals.
    case scanning
    /// Bluetooth is powered on and the `BluetoothManager` is ready to use.
    case ready
    /// Bluetooth is currently powered off on the device.
    case poweredOff
    /// Indicates the connection with the system service was momentarily lost.
    ///
    /// This state indicates that Bluetooth is trying to reconnect. After it reconnects, `BluetoothManager` updates the
    /// state value.
    case resetting
    /// The app is not authorized to use Bluetooth. Associated value provides specific authorization status.
    case unauthorized(AuthorizationStatus)
    /// The platform doesn't support Bluetooth Low Energy.
    case unsupported
    /// The state of the `BluetoothManager` is unknown.
    ///
    /// This is a temporary state. After Core Bluetooth initializes or resets, `BluetoothManager` updates the
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
public enum AuthorizationError: Error {
    /// The user has not yet been asked for Bluetooth permissions.
    case unauthorized
    /// The user explicitly denied Bluetooth access for this app.
    case denied
    /// Indicates this app isn’t authorized to use Bluetooth.
    case restricted
    /// The authorization status is unknown.
    case unknown
}
