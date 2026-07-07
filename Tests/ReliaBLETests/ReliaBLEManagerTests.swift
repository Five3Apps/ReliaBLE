//
//  ReliaBLEManagerTests.swift
//  ReliaBLETests
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

import Foundation
import Testing

import CoreBluetoothMock
import Willow
@testable import ReliaBLEMock

// MARK: - Test Suite

/// All ReliaBLE behavioral tests live in a single **serialized** suite.
///
/// Two process-wide singletons make parallel execution unsafe:
/// 1. ``BluetoothActor/shared`` is a process-lifetime actor whose `CBCentralManager` is created once and never
///    torn down (the `centralManager == nil` guard in `setupCentralManager()`).
/// 2. Nordic's `CBMCentralManagerMock` keeps global static simulation state (authorization, power, peripherals).
///
/// `.serialized` guarantees no two tests mutate that shared state concurrently — without it, a scan started by one
/// test would deliver advertisements into another test's `peripheralDiscoveries` subscriber. Every test creates its
/// manager via ``Mock/makeManager(loggingEnabled:)`` (which registers the simulated peripheral and pins
/// authorization before any central can be created), and stateful tests re-establish their baseline via
/// ``Mock/ensureReady(_:)``, so the suite is order-independent.
@Suite(.serialized)
struct ReliaBLEManagerTests {

    // MARK: - Compile-Time Sendable Proofs

    @Test func reliaBLEManagerIsSendable() async throws {
        let manager = await Mock.makeManager()

        // Capturing the manager in a `Task.detached` closure and exercising every public member is a
        // compile-time proof that `ReliaBLEManager` is `Sendable` — the closure crosses an isolation
        // boundary. The behavior of the calls is irrelevant here; this test asserts compilation.
        await Task.detached {
            _ = manager.loggingService
            _ = await manager.currentState
            _ = manager.state
            _ = manager.peripheralDiscoveries
            _ = manager.discoveredPeripherals
            await manager.startScanning()
            await manager.startScanning(services: [])
            await manager.stopScanning()
            try? await manager.connect(to: Peripheral(id: "unused"))

            // `authorizeBluetooth()` suspends until the authorization decision resolves; under the mock's
            // undetermined default that never happens, so drive it from a child task and cancel after a
            // beat. This exercises the member for the Sendable proof while relying on authorize()'s
            // cancellation handling to avoid hanging.
            let authTask = Task { try? await manager.authorizeBluetooth() }
            try? await Task.sleep(nanoseconds: 100_000_000)
            authTask.cancel()
            _ = await authTask.value
        }.value
    }

    @Test func peripheralIsSendable() async throws {
        let peripheral = Peripheral(id: "sendable-id")

        // Capturing the value in a `Task.detached` closure is a compile-time proof that
        // `Peripheral` is `Sendable` — the closure crosses an isolation boundary.
        let capturedId = await Task.detached { peripheral.id }.value

        #expect(capturedId == "sendable-id")
    }

    // MARK: - Public Value Types

    @Test func bluetoothStateDescriptionsCoverEveryCase() {
        #expect(BluetoothState.scanning.description == "Scanning")
        #expect(BluetoothState.ready.description == "Ready")
        #expect(BluetoothState.poweredOff.description == "Powered Off")
        #expect(BluetoothState.resetting.description == "Resetting")
        #expect(BluetoothState.unsupported.description == "Unsupported")
        #expect(BluetoothState.unknown.description == "Unknown")
        #expect(BluetoothState.unauthorized(.notDetermined).description == "Not Authorized")
        #expect(BluetoothState.unauthorized(.restricted).description == "Restricted")
        #expect(BluetoothState.unauthorized(.denied).description == "Denied")
        // Any other authorization status falls through to the generic label.
        #expect(BluetoothState.unauthorized(.allowedAlways).description == "Unauthorized")
    }

    @Test func peripheralEqualityAndHashKeyOnIDOnly() {
        let a = Peripheral(id: "shared-id")
        let b = Peripheral(id: "shared-id")
        let c = Peripheral(id: "other-id")

        // `init(id:)` leaves every discovery-populated field empty.
        #expect(a.cbIdentifier == nil)
        #expect(a.name == nil)
        #expect(a.rssi == nil)
        #expect(a.lastSeen == nil)
        #expect(a.advertisement == nil)

        // Equality and hashing key on `id` only.
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)

        let set: Set<Peripheral> = [a, b, c]
        #expect(set.count == 2)
    }

    @Test func advertisementDataExtractsTypedValues() {
        let uuid = CBMUUID(string: "180D")
        let raw: [String: Any] = [
            CBMAdvertisementDataLocalNameKey: "Heart Rate Monitor",
            CBMAdvertisementDataServiceUUIDsKey: [uuid],
            CBMAdvertisementDataManufacturerDataKey: Data([0x01, 0x02, 0x03]),
            CBMAdvertisementDataTxPowerLevelKey: NSNumber(value: -50),
            CBMAdvertisementDataIsConnectable: NSNumber(value: true),
            CBMAdvertisementDataServiceDataKey: [uuid: Data([0xAA])],
            CBMAdvertisementDataOverflowServiceUUIDsKey: [uuid],
            CBMAdvertisementDataSolicitedServiceUUIDsKey: [uuid]
        ]

        let advertisement = AdvertisementData(rawAdvertisementData: raw)

        #expect(advertisement.localName == "Heart Rate Monitor")
        #expect(advertisement.serviceUUIDs == [uuid])
        #expect(advertisement.manufacturerData == Data([0x01, 0x02, 0x03]))
        #expect(advertisement.txPowerLevel == -50)
        #expect(advertisement.isConnectable == true)
        #expect(advertisement.serviceData[uuid] == Data([0xAA]))
        #expect(advertisement.overflowServiceUUIDs == [uuid])
        #expect(advertisement.solicitedServiceUUIDs == [uuid])
    }

    @Test func advertisementDataDefaultsForEmptyDictionary() {
        let advertisement = AdvertisementData(rawAdvertisementData: [:])

        #expect(advertisement.localName == nil)
        #expect(advertisement.serviceUUIDs.isEmpty)
        #expect(advertisement.manufacturerData == nil)
        #expect(advertisement.txPowerLevel == nil)
        #expect(advertisement.isConnectable == nil)
        #expect(advertisement.serviceData.isEmpty)
        #expect(advertisement.overflowServiceUUIDs.isEmpty)
        #expect(advertisement.solicitedServiceUUIDs.isEmpty)
    }

    @Test func reliaBLEConfigDefaults() {
        let config = ReliaBLEConfig()

        #expect(config.loggingEnabled == false)
        #expect(config.logLevels == LogLevel.all)
        #expect(config.logWriters.count == 1)

        var custom = ReliaBLEConfig()
        custom.loggingEnabled = true
        #expect(custom.loggingEnabled == true)
    }

    // MARK: - Authorization

    @Test func authorizeThrowsWhenDenied() async throws {
        let manager = await Mock.makeManager()
        CBMCentralManagerMock.simulateAuthorization(.denied)

        do {
            try await manager.authorizeBluetooth()
            #expect(Bool(false), "Expected AuthorizationError.denied")
        } catch AuthorizationError.denied {
            // expected
        } catch {
            #expect(Bool(false), "Expected AuthorizationError.denied, got \(error)")
        }
    }

    @Test func authorizeThrowsWhenRestricted() async throws {
        let manager = await Mock.makeManager()
        CBMCentralManagerMock.simulateAuthorization(.restricted)

        do {
            try await manager.authorizeBluetooth()
            #expect(Bool(false), "Expected AuthorizationError.restricted")
        } catch AuthorizationError.restricted {
            // expected
        } catch {
            #expect(Bool(false), "Expected AuthorizationError.restricted, got \(error)")
        }
    }

    @Test func authorizeWhenAllowedBecomesReady() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        #expect(await Mock.waitForState("Ready", on: manager))
    }

    @Test func authorizeCanBeCancelledWhileAwaitingDecision() async throws {
        let manager = await Mock.makeManager()

        // Force the undetermined path so `authorizeBluetooth()` suspends awaiting the user's decision.
        // Cancelling the task must unblock the suspension instead of hanging forever.
        CBMCentralManagerMock.simulateAuthorization(.notDetermined)

        let task = Task { try await manager.authorizeBluetooth() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        // We only assert that the call resolves (it throws on cancel, or already returned if authorized) —
        // i.e. that it does not hang.
        _ = await task.result
    }

    @Test func updateStateReflectsUnauthorizedAuthorizations() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        CBMCentralManagerMock.simulateAuthorization(.denied)
        await BluetoothActor.shared.updateState()
        #expect(await manager.currentState.description == "Denied")

        CBMCentralManagerMock.simulateAuthorization(.restricted)
        await BluetoothActor.shared.updateState()
        #expect(await manager.currentState.description == "Restricted")

        CBMCentralManagerMock.simulateAuthorization(.notDetermined)
        await BluetoothActor.shared.updateState()
        #expect(await manager.currentState.description == "Not Authorized")

        // Restore the baseline so later tests start from a known-good authorization.
        CBMCentralManagerMock.simulateAuthorization(.allowedAlways)
        await BluetoothActor.shared.updateState()
    }

    // MARK: - Scanning

    @Test func startAndStopScanningTransitionsState() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await manager.startScanning(services: nil)
        #expect(await Mock.waitForState("Scanning", on: manager))

        await manager.stopScanning()
        #expect(await Mock.waitForState("Ready", on: manager))
    }

    @Test func startScanningIsNoOpWhenNotPoweredOn() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        CBMCentralManagerMock.simulatePowerOff()
        #expect(await Mock.waitForState("Powered Off", on: manager))

        await manager.startScanning()
        // The guard on `centralManager.state == .poweredOn` means the scan never starts.
        #expect(await manager.currentState.description == "Powered Off")

        // Restore power so later tests start from a known-good state.
        CBMCentralManagerMock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)
    }

    // MARK: - Discovery

    @Test func scanningDeliversDiscoveryEventsAndPeripherals() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        // `peripheralDiscoveries` does not replay, so subscribe before scanning starts.
        let discoveries = manager.peripheralDiscoveries

        await manager.startScanning()

        let peripheral = await Mock.waitForPeripheral(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        #expect(peripheral?.id == Mock.testPeripheralID)
        #expect(peripheral?.advertisement?.localName == Mock.testPeripheralID)
        #expect(peripheral?.cbIdentifier != nil)

        let event = await firstEvent(from: discoveries, withinNanoseconds: 3_000_000_000)
        #expect(event != nil)
        #expect(event?.advertisement.localName == Mock.testPeripheralID)

        // Exercise `PeripheralDiscoveryEvent`'s id-based `Hashable`/`Equatable` semantics.
        if let event {
            #expect(event == event)
            #expect(event.hashValue == event.hashValue)
            var set: Set<PeripheralDiscoveryEvent> = []
            set.insert(event)
            set.insert(event)
            #expect(set.count == 1)
            #expect(set.contains(event))
        }

        await manager.stopScanning()
    }

    @Test func discoveredPeripheralsReplaysCurrentListOnSubscribe() async throws {
        let manager = await Mock.makeManager()

        // `discoveredPeripherals` replays the current (possibly empty) list as its first element on
        // subscription, mirroring `state`. The replay proves a value is delivered without waiting for a
        // change broadcast.
        var subscriber = manager.discoveredPeripherals.makeAsyncIterator()
        let replay = await subscriber.next()

        #expect(replay != nil)
    }

    @Test func discoveredPeripheralsReplaysDiscoveredList() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await manager.startScanning()
        _ = await Mock.waitForPeripheral(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        await manager.stopScanning()

        // A fresh subscriber replays the current (now non-empty) list as its first element.
        var iterator = manager.discoveredPeripherals.makeAsyncIterator()
        let replayed = await iterator.next()
        #expect(replayed?.contains(where: { $0.id == Mock.testPeripheralID }) == true)
    }

    @Test func peripheralDiscoveriesDoesNotReplay() async throws {
        let manager = await Mock.makeManager()

        // Establish a not-scanning, powered-on baseline, then drain any advertisement already in flight
        // from an earlier scan (callbacks hop through the mock delegate queue and an actor `Task`).
        await Mock.ensureReady(manager)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // The feed does not replay, so a fresh subscriber must see no event while scanning is stopped.
        let event = await firstEvent(from: manager.peripheralDiscoveries, withinNanoseconds: 200_000_000)
        #expect(event == nil)
    }

    @Test func powerCycleAfterDiscoveryRefreshesPeripherals() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await manager.startScanning()
        _ = await Mock.waitForPeripheral(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        await manager.stopScanning()

        // Powering off then on drives the `centralManagerDidUpdateState` path, which re-resolves
        // the live references for already-discovered peripherals on power-on.
        CBMCentralManagerMock.simulatePowerOff()
        #expect(await Mock.waitForState("Powered Off", on: manager))

        CBMCentralManagerMock.simulatePowerOn()
        #expect(await Mock.waitForState("Ready", on: manager))
    }

    // MARK: - Connection

    @Test func connectToDiscoveredPeripheralSucceeds() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await manager.startScanning()
        let peripheral = await Mock.waitForPeripheral(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )

        // Stop scanning before any potential throw so leaked scan state can't affect later tests.
        await manager.stopScanning()

        let discovered = try #require(peripheral)
        // The live `CBPeripheral` is registered under this snapshot's id, so connect must not throw.
        try await manager.connect(to: discovered)
    }

    @Test func connectToUnknownPeripheralThrows() async throws {
        let manager = await Mock.makeManager()
        let staleSnapshot = Peripheral(id: "never-discovered")

        // Connecting to a peripheral that was never discovered must throw. Which `PeripheralError` is
        // thrown depends on whether a central manager exists in the shared actor at the time: `.notFound`
        // when it does (the id is simply not in the live registry) or `.bluetoothUnavailable` when it
        // does not (Bluetooth was never set up). Either is a correct outcome.
        do {
            try await manager.connect(to: staleSnapshot)
            Issue.record("Expected connect(to:) to throw for an unknown peripheral")
        } catch let error as PeripheralError {
            #expect(error == .notFound || error == .bluetoothUnavailable)
        }
    }

    // MARK: - Logging

    @Test func loggingEnabledExercisesLogPaths() async throws {
        let manager = await Mock.makeManager(loggingEnabled: true)
        #expect(manager.loggingService.enabled == true)

        // Drive a scan cycle so the enabled logger evaluates its message autoclosures.
        await Mock.ensureReady(manager)
        await manager.startScanning()
        _ = await Mock.waitForState("Scanning", on: manager)
        await manager.stopScanning()
    }

    @Test func loggingServiceForwardsEveryLevelWhenEnabled() {
        let writer = ReliaBLEMock.OSLogWriter(subsystem: "com.five3apps.relia-ble.tests", category: "Test")
        let service = LoggingService(
            levels: .all,
            writers: [writer],
            queue: DispatchQueue(label: "com.five3apps.relia-ble.tests.logging")
        )

        service.enabled = true
        #expect(service.enabled == true)

        // Exercise every entry point so each message autoclosure and `LogMessage` construction runs.
        service.debug(tags: [.category(.scanning)], "debug message")
        service.info(tags: [.peripheral("device-1")], "info message")
        service.warn(tags: [.category(.connection), .peripheral("device-1")], "warn message")
        service.error("error message")

        service.enabled = false
        #expect(service.enabled == false)
    }

    @Test func logMessageMapsTagsToAttributes() {
        let message = ReliaBLEMock.LogMessage(
            tags: [.category(.scanning), .category(.connection), .peripheral("device-1")],
            message: "scanning"
        )

        #expect(message.name == "scanning")
        let attributes = message.attributes
        #expect(attributes["Peripheral"] as? String == "device-1")
        #expect(attributes["Categories"] as? String == "scanning, connection")

        // No tags yields empty attributes.
        let untagged = ReliaBLEMock.LogMessage(tags: nil, message: "plain")
        #expect(untagged.attributes.isEmpty)
    }

    @Test func osLogWriterWritesMessagesAndMapsLevels() {
        let writer = ReliaBLEMock.OSLogWriter(subsystem: "com.five3apps.relia-ble.tests", category: "Test")
        #expect(writer.subsystem == "com.five3apps.relia-ble.tests")
        #expect(writer.category == "Test")

        let source = LogSource(file: #file, function: #function, line: #line, column: #column)

        // Both `writeMessage` overloads: the plain `String` and the structured `LogMessage` (with tags).
        writer.writeMessage("plain string", logLevel: .info, logSource: source)
        writer.writeMessage(
            ReliaBLEMock.LogMessage(tags: [.peripheral("device-1"), .category(.scanning)], message: "tagged"),
            logLevel: .warn,
            logSource: source
        )

        // Every `LogLevel` → `OSLogType` mapping, including the default branch.
        #expect(writer.logType(forLogLevel: .debug) == .debug)
        #expect(writer.logType(forLogLevel: .info) == .info)
        #expect(writer.logType(forLogLevel: .warn) == .default)
        #expect(writer.logType(forLogLevel: .error) == .error)
        #expect(writer.logType(forLogLevel: .event) == .default)
    }

    @Test func capturingWriterRecordsForwardedMessagesAndLevels() {
        let queue = DispatchQueue(label: "com.five3apps.relia-ble.tests.capturing")
        let writer = CapturingLogWriter()
        let service = LoggingService(levels: .all, writers: [writer], queue: queue)
        service.enabled = true

        // Each entry point wraps its text in a `LogMessage`, so the structured overload fires for all four.
        service.debug(tags: [.category(.scanning)], "debug message")
        service.info(tags: [.peripheral("device-1")], "info message")
        service.warn(tags: [.category(.connection)], "warn message")
        service.error("error message")

        // Writes are dispatched asynchronously onto the serial `queue`; a sync barrier flushes them.
        queue.sync {}

        let captured = writer.captured
        #expect(captured.map(\.message) == ["debug message", "info message", "warn message", "error message"])
        #expect(captured.map(\.level) == [.debug, .info, .warn, .error])

        // Disabling the service stops forwarding to the writer entirely.
        service.enabled = false
        service.error("dropped message")
        queue.sync {}
        #expect(writer.captured.count == 4)
    }

        // MARK: - Connection Lifecycle

    @Test func connectionStateChangesEmitsConnectSuccessSequence() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let changes = manager.connectionStateChanges

        // Discover the connectable test peripheral.
        await manager.startScanning()
        let peripheral = await Mock.waitForPeripheral(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let discovered = try #require(peripheral)
        await manager.stopScanning()

        try await manager.connect(to: discovered)

        let connecting = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        #expect(connecting?.peripheralId == discovered.id)
        #expect(connecting?.state == .connecting)

        let connected = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        #expect(connected?.peripheralId == discovered.id)
        #expect(connected?.state == .connected)
    }

    @Test func connectionStateChangesEmitsDisconnectSequence() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let changes = manager.connectionStateChanges

        await manager.startScanning()
        let peripheral = await Mock.waitForPeripheral(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let discovered = try #require(peripheral)
        await manager.stopScanning()

        try await manager.connect(to: discovered)

        // Drain .connecting and .connected.
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)

        try await manager.disconnect(from: discovered)

        let disconnecting = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        #expect(disconnecting?.peripheralId == discovered.id)
        #expect(disconnecting?.state == .disconnecting)

        let disconnected = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        #expect(disconnected?.peripheralId == discovered.id)
        #expect(disconnected?.state == .disconnected(reason: nil))
    }

    @Test func connectionStateChangesEmitsConnectFailureSequence() async throws {
        // Pre-condition: no stale connection state from a preceding lifecycle test.
        Mock.connectionTestSpec.simulateDisconnection()
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Drain any spurious events that simulateDisconnection may have injected
        // into the actor's stream continuations.
        await BluetoothActor.shared.updateState()

        Mock.connectionTestDelegate.connectionResult = .failure(CBMError(.connectionTimeout))
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let changes = manager.connectionStateChanges

        await manager.startScanning()
        let peripheral = await Mock.waitForPeripheral(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let discovered = try #require(peripheral)
        await manager.stopScanning()

        // Force a clean disconnection on the spec to reset any lingering
        // `virtualConnections` / `isConnected` state left by a preceding test.
        Mock.connectionTestSpec.simulateDisconnection()
        try? await Task.sleep(nanoseconds: 100_000_000)

        try await manager.connect(to: discovered)

        var events: [ConnectionStateChange] = []
        for _ in 0..<3 {
            if let change = await firstConnectionStateChange(from: changes, withinNanoseconds: 3_000_000_000) {
                events.append(change)
            }
        }

        // The mock's connection callback fires on an async timer (0.045 s), so the
        // time spent collecting events is well under the 3 s timeout per event.  The
        // failure test must see .connecting then .failed(reason: .connectionTimeout).
        guard events.count >= 2 else {
            #expect(Bool(false), "Expected at least 2 events, got \(events.count): \(events)")
            return
        }
        #expect(events[0].peripheralId == discovered.id)
        #expect(events[0].state == .connecting)
        #expect(events[1].peripheralId == discovered.id)
        #expect(events[1].state == .failed(reason: .connectionTimeout))
    }

    @Test func connectionStateChangesSupportsConcurrentSubscribers() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        var subscriberA = manager.connectionStateChanges.makeAsyncIterator()
        var subscriberB = manager.connectionStateChanges.makeAsyncIterator()

        // Force an actor hop to guarantee the registration Tasks have completed
        // before we issue the connect (connectionStateChanges has no replay).
        _ = await manager.currentConnectionStates

        await manager.startScanning()
        let peripheral = await Mock.waitForPeripheral(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let discovered = try #require(peripheral)
        await manager.stopScanning()

        try await manager.connect(to: discovered)

        // Both subscribers see the .connecting event.
        let a1 = await subscriberA.next()
        let b1 = await subscriberB.next()
        #expect(a1?.state == .connecting)
        #expect(b1?.state == .connecting)

        // Both subscribers see the .connected event.
        let a2 = await subscriberA.next()
        let b2 = await subscriberB.next()
        #expect(a2?.state == .connected)
        #expect(b2?.state == .connected)
    }

    // MARK: - Reconnection

    /// A fast reconnect policy for tests: tiny delays, no jitter, small max attempts.
    private static let testReconnectPolicy: ReconnectPolicy = {
        var policy = ReconnectPolicy()
        policy.maxAttempts = 3
        policy.initialDelay = 0.001
        policy.maxDelay = 0.005
        policy.jitter = 0
        return policy
    }()

    @Test func systemReconnectOnUnexpectedDrop() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager(reconnectPolicy: Self.testReconnectPolicy)
        await Mock.ensureReady(manager)
        await BluetoothActor.shared.setReconnectPolicy(Self.testReconnectPolicy)

        let changes = manager.connectionStateChanges

        await manager.startScanning()
        let peripheral = await Mock.waitForPeripheral(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let discovered = try #require(peripheral)
        await manager.stopScanning()

        try await manager.connect(to: discovered)

        // Drain .connecting and .connected.
        let c1 = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        #expect(c1?.state == .connecting)
        let c2 = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        #expect(c2?.state == .connected)

        // Simulate an unexpected disconnect with the OS auto-reconnect option active.
        Mock.connectionTestSpec.simulateDisconnection()

        // Tier 0: OS sends isReconnecting=true → library emits .system with nil metadata.
        let c3 = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        guard case .reconnecting(let source, let attempt, let nextRetryAt) = c3?.state else {
            Issue.record("Expected .reconnecting, got \(String(describing: c3?.state))")
            return
        }
        #expect(source == .system)
        #expect(attempt == nil)
        #expect(nextRetryAt == nil)

        // No library ladder should have been armed — verify no .library reconnecting events.
        let remaining = await drainConnectionStateChanges(from: changes, withinNanoseconds: 2_000_000_000)
        let libraryReconnects = remaining.filter {
            if case .reconnecting(.library, _, _) = $0.state { return true }
            return false
        }
        #expect(libraryReconnects.isEmpty, "Expected no .library reconnect events, got \(libraryReconnects.count)")

        // Cleanup: explicit disconnect to cancel any pending reconnect state.
        try? await manager.disconnect(from: discovered)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func reconnectGivesUpAfterMaxAttempts() async throws {
        var giveUpPolicy = ReconnectPolicy()
        giveUpPolicy.maxAttempts = 2
        giveUpPolicy.initialDelay = 0.001
        giveUpPolicy.maxDelay = 0.005
        giveUpPolicy.jitter = 0

        Mock.connectionTestDelegate.connectionResult = .failure(CBMError(.connectionTimeout))
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager(reconnectPolicy: giveUpPolicy)
        await Mock.ensureReady(manager)
        await BluetoothActor.shared.setReconnectPolicy(giveUpPolicy)

        let changes = manager.connectionStateChanges

        await manager.startScanning()
        let peripheral = await Mock.waitForPeripheral(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let discovered = try #require(peripheral)
        await manager.stopScanning()

        // Force a clean disconnection to reset any lingering mock state.
        Mock.connectionTestSpec.simulateDisconnection()
        try? await Task.sleep(nanoseconds: 100_000_000)

        try await manager.connect(to: discovered)

        let events = await drainConnectionStateChanges(from: changes, withinNanoseconds: 5_000_000_000)
        let states = events.map { $0.state }

        #expect(states.count >= 6, "Expected at least 6 events, got \(states.count)")

        // Sequence: .connecting, .failed, .reconnecting(1), .connecting, .failed, .reconnecting(2), .connecting, .failed
        #expect(states[0] == .connecting)
        guard case .failed = states[1] else {
            Issue.record("Expected .failed at index 1, got \(String(describing: states[1]))")
            return
        }
        guard case .reconnecting(let source1, let a1, _) = states[2] else {
            Issue.record("Expected .reconnecting at index 2, got \(String(describing: states[2]))")
            return
        }
        #expect(source1 == .library)
        #expect(a1 == 1)
        #expect(states[3] == .connecting)
        guard case .failed = states[4] else {
            Issue.record("Expected .failed at index 4, got \(String(describing: states[4]))")
            return
        }
        guard case .reconnecting(let source2, let a2, _) = states[5] else {
            Issue.record("Expected .reconnecting at index 5, got \(String(describing: states[5]))")
            return
        }
        #expect(source2 == .library)
        #expect(a2 == 2)

        // The terminal state after give-up should be .failed, not .reconnecting.
        if events.count >= 8 {
            #expect(states[6] == .connecting)
            guard case .failed = states[7] else {
                Issue.record("Expected terminal .failed at index 7, got \(String(describing: states[7]))")
                return
            }
        }

        // Verify no more .reconnecting events after the terminal state.
        let reconnectingCount = states.filter {
            if case .reconnecting = $0 { return true }
            return false
        }.count
        #expect(reconnectingCount == 2, "Expected exactly 2 .reconnecting events, got \(reconnectingCount)")

        // Cleanup: the ladder has exhausted its attempts, but an explicit disconnect
        // removes the id from reconnectEnabled so no stray event can re-arm it.
        try? await manager.disconnect(from: discovered)
        var cleanup = ReconnectPolicy()
        cleanup.maxAttempts = 0
        await BluetoothActor.shared.setReconnectPolicy(cleanup)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func explicitDisconnectDoesNotReconnect() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager(reconnectPolicy: Self.testReconnectPolicy)
        await Mock.ensureReady(manager)
        await BluetoothActor.shared.setReconnectPolicy(Self.testReconnectPolicy)

        let changes = manager.connectionStateChanges

        await manager.startScanning()
        let peripheral = await Mock.waitForPeripheral(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let discovered = try #require(peripheral)
        await manager.stopScanning()

        try await manager.connect(to: discovered)

        // Drain .connecting and .connected.
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)

        // Explicit disconnect.
        try await manager.disconnect(from: discovered)

        let events = await drainConnectionStateChanges(from: changes, withinNanoseconds: 3_000_000_000)
        let states = events.map { $0.state }

        // Sequence: .disconnecting, .disconnected(reason: nil). No .reconnecting.
        #expect(states.count == 2, "Expected 2 events, got \(states.count)")
        #expect(states[0] == .disconnecting)
        guard case .disconnected(let reason) = states[1] else {
            Issue.record("Expected .disconnected at index 1, got \(String(describing: states[1]))")
            return
        }
        #expect(reason == nil, "Expected nil reason for explicit disconnect, got \(String(describing: reason))")

        let hasReconnecting = states.contains {
            if case .reconnecting = $0 { return true }
            return false
        }
        #expect(!hasReconnecting, "Expected no .reconnecting events after explicit disconnect")

        // Cleanup: prevent further reconnect attempts from interfering with subsequent tests.
        var cleanup = ReconnectPolicy()
        cleanup.maxAttempts = 0
        await BluetoothActor.shared.setReconnectPolicy(cleanup)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func transientConnectFailureArmsReconnect() async throws {
        Mock.connectionTestDelegate.connectionResult = .failure(CBMError(.connectionTimeout))
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager(reconnectPolicy: Self.testReconnectPolicy)
        await Mock.ensureReady(manager)
        await BluetoothActor.shared.setReconnectPolicy(Self.testReconnectPolicy)

        let changes = manager.connectionStateChanges

        await manager.startScanning()
        let peripheral = await Mock.waitForPeripheral(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let discovered = try #require(peripheral)
        await manager.stopScanning()

        // Force a clean disconnection to reset any lingering mock state.
        Mock.connectionTestSpec.simulateDisconnection()
        try? await Task.sleep(nanoseconds: 100_000_000)

        try await manager.connect(to: discovered)

        let events = await drainConnectionStateChanges(from: changes, withinNanoseconds: 5_000_000_000)
        let states = events.map { $0.state }

        #expect(states.count >= 3, "Expected at least 3 events, got \(states.count)")

        // Sequence: .connecting, .failed, .reconnecting(attempt: 1, ...)
        #expect(states[0] == .connecting)
        guard case .failed = states[1] else {
            Issue.record("Expected .failed at index 1, got \(String(describing: states[1]))")
            return
        }
        guard case .reconnecting(let source3, let attempt3, _) = states[2] else {
            Issue.record("Expected .reconnecting at index 2, got \(String(describing: states[2]))")
            return
        }
        #expect(source3 == .library)
        #expect(attempt3 == 1)

        // Cleanup: cancel the pending reconnect task via explicit disconnect, then
        // prevent further arming so no stray reconnect fires during subsequent tests.
        try? await manager.disconnect(from: discovered)
        var cleanup = ReconnectPolicy()
        cleanup.maxAttempts = 0
        await BluetoothActor.shared.setReconnectPolicy(cleanup)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// CoreBluetoothMock hardcodes `isReconnecting: true` after any connect that passes
    /// `CBConnectPeripheralOptionEnableAutoReconnect`, so `isReconnecting: false` scenarios
    /// (OS give-up, or an unexpected drop after a non-auto-reconnect connect) must be injected
    /// via ``BluetoothActor/testInjectDisconnect(for:isReconnecting:error:)`` rather than
    /// driven through the mock's `simulateDisconnection()`.

    @Test func autoReconnectFalseDoesNotArmLadder() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager(reconnectPolicy: Self.testReconnectPolicy)
        await Mock.ensureReady(manager)
        await BluetoothActor.shared.setReconnectPolicy(Self.testReconnectPolicy)

        let changes = manager.connectionStateChanges

        await manager.startScanning()
        let peripheral = await Mock.waitForPeripheral(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let discovered = try #require(peripheral)
        await manager.stopScanning()

        // Connect with autoReconnect: false — the OS option is NOT passed, and the
        // library ladder is NOT armed.
        try await manager.connect(to: discovered, autoReconnect: false)

        // Drain .connecting and .connected.
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)

        // Inject an unexpected drop via the test hook (mock would emit isReconnecting: false anyway
        // since the OS option wasn't passed, but we use the hook for explicitness).
        await BluetoothActor.shared.testInjectDisconnect(for: discovered.id, isReconnecting: false)

        let events = await drainConnectionStateChanges(from: changes, withinNanoseconds: 3_000_000_000)
        let states = events.map { $0.state }

        guard case .disconnected = states.first else {
            Issue.record("Expected .disconnected, got \(states)")
            return
        }

        let hasReconnecting = states.contains {
            if case .reconnecting = $0 { return true }
            return false
        }
        #expect(!hasReconnecting, "Expected no .reconnecting events when autoReconnect is false")

        // Cleanup: explicit disconnect and prevent further reconnect attempts.
        try? await manager.disconnect(from: discovered)
        var cleanup = ReconnectPolicy()
        cleanup.maxAttempts = 0
        await BluetoothActor.shared.setReconnectPolicy(cleanup)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func osGiveUpHandsOffToTier1() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager(reconnectPolicy: Self.testReconnectPolicy)
        await Mock.ensureReady(manager)
        await BluetoothActor.shared.setReconnectPolicy(Self.testReconnectPolicy)

        let changes = manager.connectionStateChanges

        await manager.startScanning()
        let peripheral = await Mock.waitForPeripheral(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let discovered = try #require(peripheral)
        await manager.stopScanning()

        // Connect with autoReconnect: true (default). The library ladder is armed
        // and the OS option is passed. We inject an OS give-up (isReconnecting: false)
        // via the test hook to simulate the OS giving up on its own reconnect.
        try await manager.connect(to: discovered)

        // Drain .connecting and .connected.
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)

        // Inject OS give-up: isReconnecting: false unexpected disconnect.
        await BluetoothActor.shared.testInjectDisconnect(for: discovered.id, isReconnecting: false)

        // Observe .disconnected(reason:).
        let c1 = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        guard case .disconnected = c1?.state else {
            Issue.record("Expected .disconnected, got \(String(describing: c1?.state))")
            return
        }

        // Tier 1 library ladder arms.
        let c2 = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        guard case .reconnecting(let source, let attempt, let nextRetryAt) = c2?.state else {
            Issue.record("Expected .reconnecting, got \(String(describing: c2?.state))")
            return
        }
        #expect(source == .library)
        #expect(attempt == 1)
        #expect(nextRetryAt != nil)

        // Cleanup: cancel the pending reconnect task via explicit disconnect.
        try? await manager.disconnect(from: discovered)
        var cleanup = ReconnectPolicy()
        cleanup.maxAttempts = 0
        await BluetoothActor.shared.setReconnectPolicy(cleanup)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - Event Stream Broadcaster

    @Test func stateStreamReplaysToConcurrentSubscribers() async throws {
        let manager = await Mock.makeManager()

        // Two independent streams from two separate property accesses.
        var subscriberA = manager.state.makeAsyncIterator()
        var subscriberB = manager.state.makeAsyncIterator()

        // Each subscriber replays the current state as its first element. A shared single stream
        // could not replay to both, so independent replay proves each access mints a distinct stream.
        let replayA = await subscriberA.next()
        let replayB = await subscriberB.next()

        #expect(replayA != nil)
        #expect(replayB != nil)
    }

    @Test func stateBroadcastReachesAllSubscribers() async throws {
        let manager = await Mock.makeManager()

        var subscriberA = manager.state.makeAsyncIterator()
        var subscriberB = manager.state.makeAsyncIterator()

        // Drain the replayed element. Awaiting it also guarantees both continuations are registered
        // (the replay is yielded during registration), so the broadcast below cannot be missed.
        _ = await subscriberA.next()
        _ = await subscriberB.next()

        // Force a state broadcast through the real actor path; both live subscribers receive it.
        await BluetoothActor.shared.updateState()

        let broadcastA = await subscriberA.next()
        let broadcastB = await subscriberB.next()

        #expect(broadcastA != nil)
        #expect(broadcastB != nil)
    }
}

// MARK: - Logging Test Support

/// A configurable ``CBMPeripheralSpecDelegate`` used by the connection-lifecycle tests.
///
/// The connection result returned from ``peripheralDidReceiveConnectionRequest(_:)`` is set on the
/// instance before a test runs. The delegate is registered once in ``SimulationConfig/ensureConfigured()``
/// and shared across all connection tests via ``Mock/connectionTestDelegate``.
final class ConnectionTestDelegate: @unchecked Sendable {
    var connectionResult: Result<Void, Error> = .success(())
}

extension ConnectionTestDelegate: CBMPeripheralSpecDelegate {
    func reset() {}

    func peripheralDidReceiveConnectionRequest(_ peripheral: CBMPeripheralSpec) -> Result<Void, Error> {
        connectionResult
    }

    func peripheral(_ peripheral: CBMPeripheralSpec, didDisconnect error: Error?) {}
}

/// A ``LogWriter`` that records every forwarded message so tests can assert on exactly what the
/// ``LoggingService`` emitted — message text and level — at the writer boundary.
///
/// Thread-safe: writes land on the service's logging queue while assertions read from the test
/// thread, so access to the backing store is guarded by a lock.
final class CapturingLogWriter: LogWriter, @unchecked Sendable {
    struct Entry {
        let message: String
        let level: LogLevel
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    /// A snapshot of everything captured so far, in the order it was written.
    var captured: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func writeMessage(_ message: String, logLevel: LogLevel, logSource: LogSource) {
        append(Entry(message: message, level: logLevel))
    }

    func writeMessage(_ message: any Willow.LogMessage, logLevel: LogLevel, logSource: LogSource) {
        append(Entry(message: message.name, level: logLevel))
    }

    private func append(_ entry: Entry) {
        lock.lock()
        storage.append(entry)
        lock.unlock()
    }
}

// MARK: - Mock Harness

/// Helpers for driving the Nordic `CBMCentralManagerMock` simulation under the constraints of the
/// process-wide ``BluetoothActor`` singleton.
enum Mock {
    /// The resolved ``Peripheral/id`` of the simulated test peripheral.
    ///
    /// The actor resolves a peripheral's id as `name ?? advertisement.localName ?? identifier`. Our spec advertises
    /// this exact local name, so the discovered snapshot's `id` is deterministic.
    static let testPeripheralID = "ReliaBLE-Test-Peripheral"

    /// The resolved ``Peripheral/id`` of the connectable test peripheral.
    ///
    /// This peripheral is backed by a ``CBMPeripheralSpec`` whose ``connectionDelegate`` is
    /// ``connectionTestDelegate``, so the connection outcome (success or failure) is configurable per-test.
    static let connectionTestPeripheralID = "ReliaBLE-Connection-Test"

    /// Configurable connection delegate shared across all lifecycle tests.
    ///
    /// Set ``ConnectionTestDelegate/connectionResult`` to `.failure(...)` before a test to simulate a
    /// failed connection; reset to `.success(())` in a `defer` or at the start of each test.
    static let connectionTestDelegate = ConnectionTestDelegate()

    /// The spec registered with the mock so tests can force a clean disconnection between
    /// lifecycle tests that otherwise leak `virtualConnections` state.
    nonisolated(unsafe) static let connectionTestSpec = makeConnectionTestPeripheralSpec()

    /// Builds a `ReliaBLEManager` after ensuring the one-time mock configuration has run.
    ///
    /// Every test routes manager creation through here so the simulated peripheral set is registered and authorization
    /// is pinned to `.notDetermined` **before** any central can be created — including by the maintainer's
    /// authorization tests, whose `.notDetermined` `authorize()` path itself creates a central. Use
    /// ``ensureReady(_:)`` afterwards to bring the shared central online.
    static func makeManager(loggingEnabled: Bool = false, reconnectPolicy: ReconnectPolicy? = nil) async -> ReliaBLEManager {
        await SimulationConfig.shared.ensureConfigured()

        var config = ReliaBLEConfig()
        config.loggingEnabled = loggingEnabled
        if let reconnectPolicy {
            config.reconnectPolicy = reconnectPolicy
        } else {
            // Disable the library ladder by default so non-reconnect tests don't
            // accidentally arm it (default autoReconnect: true on connect(to:) still
            // passes the OS option, but the library ladder won't schedule retries).
            var defaultPolicy = ReconnectPolicy()
            defaultPolicy.maxAttempts = 0
            config.reconnectPolicy = defaultPolicy
        }
        return ReliaBLEManager(config: config)
    }

    /// Brings the shared central online: authorized, powered on, and reporting `.ready`.
    ///
    /// Resets authorization to `.allowedAlways` (undoing any `.denied`/`.restricted`/`.notDetermined` left by an
    /// earlier test), ensures power is on, triggers central creation if needed, clears any leaked scan, then waits for
    /// the powered-on state. With `.allowedAlways`, `authorizeBluetooth()` sets up the central and returns without
    /// suspending.
    static func ensureReady(_ manager: ReliaBLEManager) async {
        CBMCentralManagerMock.simulateAuthorization(.allowedAlways)
        CBMCentralManagerMock.simulatePowerOn()

        // Creates the central on first call (peripherals are already registered); a no-op once it exists.
        try? await manager.authorizeBluetooth()

        _ = await pollUntil(timeout: 3.0) {
            await BluetoothActor.shared.isCentralPoweredOn
        }

        // Clear any scan leaked by an earlier test (the central is process-lifetime) and recompute the
        // broadcast state now that authorization and power are settled. `stopScanning()` re-runs
        // `updateState()`, so this also resolves to `.ready` when powered on and authorized.
        await manager.stopScanning()
        await BluetoothActor.shared.updateState()
    }

    /// Builds the simulated, discoverable, connectable test peripheral.
    static func makeTestPeripheralSpec() -> CBMPeripheralSpec {
        CBMPeripheralSpec
            .simulatePeripheral(proximity: .immediate)
            .advertising(
                advertisementData: [
                    CBMAdvertisementDataLocalNameKey: testPeripheralID,
                    CBMAdvertisementDataServiceUUIDsKey: [CBMUUID(string: "180D")],
                    CBMAdvertisementDataIsConnectable: NSNumber(value: true)
                ],
                withInterval: 0.05
            )
            .connectable(name: testPeripheralID, services: [], delegate: nil)
            .build()
    }

    /// Builds the simulated peripheral used by connection-lifecycle tests, backed by
    /// ``connectionTestDelegate`` so connection outcomes are configurable per-test.
    private static func makeConnectionTestPeripheralSpec() -> CBMPeripheralSpec {
        CBMPeripheralSpec
            .simulatePeripheral(proximity: .immediate)
            .advertising(
                advertisementData: [
                    CBMAdvertisementDataLocalNameKey: connectionTestPeripheralID,
                    CBMAdvertisementDataServiceUUIDsKey: [CBMUUID(string: "180D")],
                    CBMAdvertisementDataIsConnectable: NSNumber(value: true)
                ],
                withInterval: 0.05
            )
            .connectable(name: connectionTestPeripheralID, services: [], delegate: connectionTestDelegate)
            .build()
    }

    /// Polls `manager.currentState` until its description matches `description` or the timeout elapses.
    static func waitForState(_ description: String, on manager: ReliaBLEManager, timeout: Double = 3.0) async -> Bool {
        await pollUntil(timeout: timeout) {
            await manager.currentState.description == description
        }
    }

    /// Waits for `discoveredPeripherals` to contain a peripheral with the given `id`.
    static func waitForPeripheral(
        id: String,
        on manager: ReliaBLEManager,
        withinNanoseconds nanoseconds: UInt64
    ) async -> Peripheral? {
        await withTaskGroup(of: Peripheral?.self) { group in
            group.addTask {
                for await list in manager.discoveredPeripherals {
                    if let match = list.first(where: { $0.id == id }) {
                        return match
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - One-Time Simulation Configuration

/// Process-wide sentinel that performs the Nordic mock's one-time global configuration exactly once.
///
/// `CBMCentralManagerMock.simulateInitialState(_:)` and `simulatePeripherals(_:)` must run once, before any central
/// is created. Keying this off "a central exists yet" is wrong — tests that never create a central (or that create one
/// lazily via `authorize()`) would let these run repeatedly. This actor provides a correct one-shot guard.
actor SimulationConfig {
    static let shared = SimulationConfig()
    private var configured = false

    func ensureConfigured() {
        guard !configured else { return }
        configured = true
        CBMCentralManagerMock.simulateInitialState(.poweredOn)
        CBMCentralManagerMock.simulatePeripherals([Mock.makeTestPeripheralSpec(), Mock.connectionTestSpec])
        // Pin authorization to `.notDetermined` so `ReliaBLEManager.init`'s `.allowedAlways` auto-setup cannot
        // create a central before the peripheral set is registered.
        CBMCentralManagerMock.simulateAuthorization(.notDetermined)
    }
}

// MARK: - Actor Test Accessors

/// Test-only accessors that derive `Sendable` values **inside** the actor's isolation, so the
/// non-`Sendable` `CBCentralManager` never crosses the isolation boundary.
extension BluetoothActor {
    var hasCentralManager: Bool { centralManager != nil }
    var isCentralPoweredOn: Bool { centralManager?.state == .poweredOn }
}

// MARK: - Polling Helper

/// Repeatedly evaluates `predicate` until it returns `true` or `timeout` seconds elapse.
@discardableResult
func pollUntil(
    timeout seconds: Double,
    interval: UInt64 = 20_000_000,
    _ predicate: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(nanoseconds: interval)
    }
    return await predicate()
}

/// Returns the first event from `stream`, or `nil` if none arrives within `nanoseconds`.
func firstEvent(
    from stream: AsyncStream<PeripheralDiscoveryEvent>,
    withinNanoseconds nanoseconds: UInt64
) async -> PeripheralDiscoveryEvent? {
    await withTaskGroup(of: PeripheralDiscoveryEvent?.self) { group in
        group.addTask {
            for await event in stream {
                return event
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: nanoseconds)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Returns the first connection-state change from `stream`, or `nil` if none arrives within `nanoseconds`.
func firstConnectionStateChange(
    from stream: AsyncStream<ConnectionStateChange>,
    withinNanoseconds nanoseconds: UInt64
) async -> ConnectionStateChange? {
    await withTaskGroup(of: ConnectionStateChange?.self) { group in
        group.addTask {
            for await change in stream {
                return change
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: nanoseconds)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Drains all connection-state changes from `stream` within `nanoseconds`, returning them in arrival order.
func drainConnectionStateChanges(
    from stream: AsyncStream<ConnectionStateChange>,
    withinNanoseconds nanoseconds: UInt64
) async -> [ConnectionStateChange] {
    await withTaskGroup(of: [ConnectionStateChange].self) { group in
        group.addTask {
            var events: [ConnectionStateChange] = []
            for await change in stream {
                events.append(change)
            }
            return events
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: nanoseconds)
            return []
        }
        _ = await group.next()
        group.cancelAll()
        return await group.next() ?? []
    }
}
