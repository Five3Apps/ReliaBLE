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
public class ReliaBLEManager {
    public let loggingService: LoggingService
    
    private let log: LoggingService
    private let bluetoothManager: BluetoothManager
    
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
        bluetoothManager = BluetoothManager(loggingService: loggingService)
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
        bluetoothManager.state
    }
    
    /// Synchronous, thread-safe access to the current state of the underlying Core Bluetooth system.
    public var currentState: BluetoothState {
        bluetoothManager.currentState
    }
    
    /// Requests authorization to use Bluetooth. This method will throw an error if the user has denied or restricted
    /// Bluetooth access.
    ///
    /// - Throws: An ``AuthorizationError`` error if the user has denied or restricted Bluetooth access.
    public func authorizeBluetooth() async throws {
        try await bluetoothManager.authorize()
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
        bluetoothManager.peripheralDiscoveries
    }

    /// A multi-subscriber `AsyncStream` that emits the current de-duplicated list of discovered
    /// peripherals each time it changes. Each property access returns a fresh, independent stream;
    /// the current list is replayed as the first element on subscription.
    public var discoveredPeripherals: AsyncStream<[Peripheral]> {
        bluetoothManager.discoveredPeripherals
    }
    
    /// Starts scanning for peripheral devices, optionally filtering by specific services.
    ///
    /// - Parameter services: An optional array of `CBUUID` objects representing the services to scan for. If provided,
    /// only peripherals advertising these services will be discovered. If `nil`, scans for all peripheral devices.
    ///
    /// - Note: If Bluetooth is not authorized or powered on, this method will not start scanning. It is the caller's
    /// responsibility to ensure that Bluetooth is authorized and powered on before calling this method.
    public func startScanning(services: sending [CBUUID]? = nil) async {
        await bluetoothManager.startScanning(services: services)
    }
    
    /// Stops scanning for peripheral devices.
    public func stopScanning() async {
        await bluetoothManager.stopScanning()
    }
    
    // MARK: - Connection

    /// Initiates a connection to a previously discovered peripheral.
    ///
    /// The ``Peripheral`` is a value snapshot captured at discovery time. This method forwards its ``Peripheral/id``
    /// to the live CoreBluetooth peripheral held internally and requests a connection.
    ///
    /// - Parameter peripheral: A peripheral previously delivered via ``discoveredPeripherals``.
    /// - Throws: ``PeripheralError/notFound`` if the peripheral's live reference has been invalidated (a stale
    ///   snapshot).
    ///
    /// - Note: This currently only initiates the connection request. The full connection lifecycle is deferred to a
    ///   later release.
    public func connect(to peripheral: Peripheral) async throws {
        try await bluetoothManager.connect(to: peripheral)
    }
    
    func testFunction() -> String {
        return "Hello, this is ReliaBLE!"
    }
}
