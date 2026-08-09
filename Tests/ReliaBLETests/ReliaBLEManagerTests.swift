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

@preconcurrency import CoreBluetoothMock
import Willow
@testable import ReliaBLEMock

// MARK: - Test Suite

/// All ReliaBLE behavioral tests live in a single **serialized** suite.
///
/// Each test owns a fresh ``ReliaBLEManager`` / ``BluetoothActor`` stack via ``Mock/makeManager``.
/// Stacks are instance-isolated; Nordic's `CBMCentralManagerMock` globals (authorization, power,
/// peripheral specs, `simulateStateRestoration`) remain process-wide, so `.serialized` keeps tests
/// from racing the mock.
///
/// **Lifetime:** by default the suite keeps one active stack — ``makeManager`` tears down the
/// previous via ``tearDown(_:)``. Cold-relaunch tests shut down stack 1 without resetting mock
/// connections, install a spec-based `simulateStateRestoration` fixture, then build stack 2 with
/// the same restore id so central init delivers faithful `willRestoreState`. Always clear
/// `simulateStateRestoration` in a `defer`.
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
            // Compile-time proof that stream factories stay `nonisolated` — sync getters must not require `await`.
            let _: AsyncStream<BluetoothState> = manager.state
            let _: AsyncStream<PeripheralDiscoveryEvent> = manager.peripheralDiscoveries
            let _: AsyncStream<[DiscoveredPeripheral]> = manager.discoveredPeripherals
            let _: AsyncStream<ConnectionStateChange> = manager.connectionStateChanges

            // `peripheral(id:)` is synchronous and nonisolated — callable from any isolation domain.
            _ = manager.peripheral(id: "unused")

            try? await manager.startScanning()
            try? await manager.startScanning(services: [])
            await manager.stopScanning()

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
        let manager = await Mock.makeManager()
        let peripheral = manager.peripheral(id: "sendable-id")

        // Capturing the class handle in a `Task.detached` closure is a compile-time proof that
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

    @Test func peripheralIdInternsSingleInstance() async {
        let manager = await Mock.makeManager()

        // Under interning, repeated calls with the same id return the identical object.
        let a = manager.peripheral(id: "shared-id")
        let b = manager.peripheral(id: "shared-id")
        #expect(a === b)
        #expect(a.id == "shared-id")
        #expect(b.id == "shared-id")

        // Fresh handle carries empty metadata.
        #expect(a.cbIdentifier == nil)
        #expect(a.name == nil)
        #expect(a.rssi == nil)
        #expect(a.lastSeen == nil)
        #expect(a.advertisement == nil)
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
        await Mock.simulateAuthorization(.denied)

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
        await Mock.simulateAuthorization(.restricted)

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
        await Mock.simulateAuthorization(.notDetermined)

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

        await Mock.simulateAuthorization(.denied)
        await manager.bluetooth.updateState()
        #expect(await manager.currentState.description == "Denied")

        await Mock.simulateAuthorization(.restricted)
        await manager.bluetooth.updateState()
        #expect(await manager.currentState.description == "Restricted")

        await Mock.simulateAuthorization(.notDetermined)
        await manager.bluetooth.updateState()
        #expect(await manager.currentState.description == "Not Authorized")

        // Restore the baseline so later tests start from a known-good authorization.
        await Mock.simulateAuthorization(.allowedAlways)
        await manager.bluetooth.updateState()
    }

    @Test func freshManagerBroadcastsUnauthorizedNotDeterminedWithoutCentral() async throws {
        // Pin auth before construction: ensureConfigured only does this once, and the prior
        // test may have left .allowedAlways. Init's fire-and-forget ensureCentralManager must
        // publish .unauthorized(.notDetermined) even though no central is created.
        await Mock.simulateAuthorization(.notDetermined)
        let manager = await Mock.makeManager()

        #expect(await Mock.waitForState("Not Authorized", on: manager))

        var iterator = manager.state.makeAsyncIterator()
        let replayed = await iterator.next()
        #expect(replayed?.description == "Not Authorized")
    }

    @Test func streamSubscriptionAfterShutdownCompletesImmediately() async throws {
        // A stack torn down via shutdown() is terminal. Every stream factory registers its
        // continuation on the actor; without a guard, a stream created after shutdown() would
        // insert a live-but-orphaned continuation that never finishes, hanging the consumer's
        // `for await` forever. Each registrar must instead finish the continuation immediately,
        // symmetric with how shutdown() finishes already-registered subscribers.
        let manager = await Mock.makeManager()
        await manager.bluetooth.shutdown()

        var stateIterator = manager.state.makeAsyncIterator()
        #expect(await stateIterator.next() == nil)

        var discoveryIterator = manager.peripheralDiscoveries.makeAsyncIterator()
        #expect(await discoveryIterator.next() == nil)

        var peripheralsIterator = manager.discoveredPeripherals.makeAsyncIterator()
        #expect(await peripheralsIterator.next() == nil)

        var connectionIterator = manager.connectionStateChanges.makeAsyncIterator()
        #expect(await connectionIterator.next() == nil)
    }

    // MARK: - Scanning

    @Test func startAndStopScanningTransitionsState() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning(services: nil)
        #expect(await Mock.waitForState("Scanning", on: manager))

        await manager.stopScanning()
        #expect(await Mock.waitForState("Ready", on: manager))
    }

    @Test func startScanningFailsWhenPoweredOff() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await Mock.simulatePowerOff()
        #expect(await Mock.waitForState("Powered Off", on: manager))

        await #expect(throws: PeripheralError.bluetoothPoweredOff) {
            try await manager.startScanning()
        }

        // No scan started despite the call.
        #expect(await manager.bluetooth.testIsScanning() == false)

        // Restore power so later tests start from a known-good state.
        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)
    }

    @Test func startScanningFailsWhenUnsupported() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await Mock.simulateInitialState(.unsupported)
        #expect(await Mock.waitForState("Unsupported", on: manager))

        await #expect(throws: PeripheralError.bluetoothUnsupported) {
            try await manager.startScanning()
        }

        #expect(await manager.bluetooth.testIsScanning() == false)

        // Restore power so later tests start from a known-good state.
        await Mock.simulateInitialState(.poweredOn)
        #expect(await Mock.waitForState("Ready", on: manager))
    }

    @Test func startScanningAwaitsTransientState() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let scanTask = Task { try await manager.startScanning() }

        // Wait until the scan waiter is parked on the transient state.
        _ = await pollUntil(timeout: 2.0) { await manager.bluetooth.testPendingScanWaiterCount() == 1 }

        await Mock.simulatePowerOn()
        _ = try await scanTask.value

        // The radio reaching `.poweredOn` resolved the waiter and started the scan.
        #expect(await Mock.waitForState("Scanning", on: manager))
        #expect(await manager.bluetooth.testPendingScanWaiterCount() == 0)
    }

    @Test func transientStateResolvingToPoweredOffFailsWaiter() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let scanTask = Task { try await manager.startScanning() }
        _ = await pollUntil(timeout: 2.0) { await manager.bluetooth.testPendingScanWaiterCount() == 1 }

        await Mock.simulatePowerOff()
        await #expect(throws: PeripheralError.bluetoothPoweredOff) {
            try await scanTask.value
        }

        #expect(await manager.bluetooth.testPendingScanWaiterCount() == 0)
        #expect(await manager.bluetooth.testIsScanning() == false)

        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)
    }

    @Test func stopScanningCompletesParkedScanWaiterSuccessfully() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let scanTask = Task { try await manager.startScanning() }
        _ = await pollUntil(timeout: 2.0) { await manager.bluetooth.testPendingScanWaiterCount() == 1 }

        // stopScanning() while parked resolves the waiter successfully; no scan starts.
        await manager.stopScanning()
        _ = try await scanTask.value

        #expect(await manager.bluetooth.testPendingScanWaiterCount() == 0)
        #expect(await manager.bluetooth.testIsScanning() == false)

        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)
    }

    @Test func supersededScanWaiterCompletesWithoutScanning() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let first = Task { try await manager.startScanning(services: [CBUUID(string: "180D")]) }
        _ = await pollUntil(timeout: 2.0) { await manager.bluetooth.testPendingScanWaiterCount() == 1 }

        // A second startScanning supersedes the first.
        let second = Task { try await manager.startScanning(services: nil) }

        // The earlier waiter completes successfully without scanning.
        _ = try await first.value

        // The newer request now owns the single-slot scan waiter.
        _ = await pollUntil(timeout: 2.0) { await manager.bluetooth.testPendingScanWaiterCount() == 1 }

        await Mock.simulatePowerOn()
        _ = try await second.value

        #expect(await Mock.waitForState("Scanning", on: manager))
        #expect(await manager.bluetooth.testPendingScanWaiterCount() == 0)
    }

    @Test func supersededScanWaiterDoesNotStealNewerRequest() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let scanUUID = CBUUID(string: "180D")

        // First waiter parks with a NIL filter while the radio is transient.
        let first = Task { try await manager.startScanning(services: nil) }
        _ = await pollUntil(timeout: 2.0) { await manager.bluetooth.testPendingScanWaiterCount() == 1 }

        // A second waiter with a NON-nil filter supersedes the first. The first must complete
        // successfully WITHOUT scanning, and the second must keep ownership of the pending scan.
        let second = Task { try await manager.startScanning(services: [scanUUID]) }

        _ = try await first.value // superseded — success, no scan, no error

        #expect(await manager.bluetooth.testPendingScanWaiterCount() == 1)

        await Mock.simulatePowerOn()
        _ = try await second.value

        #expect(await Mock.waitForState("Scanning", on: manager))
        #expect(await manager.bluetooth.testPendingScanWaiterCount() == 0)
        // The scan that actually started must use the SECOND caller's filter, not the first's nil.
        #expect(await manager.bluetooth.testLastScanServices() == [scanUUID])

        await manager.stopScanning()
    }

    @Test func cancelScanWaiterIgnoresNonMatchingWaiterID() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let scanUUID = CBUUID(string: "180D")

        // A scan task parks with a NON-nil filter while the radio is transient.
        let scanTask = Task { try await manager.startScanning(services: [scanUUID]) }
        _ = await pollUntil(timeout: 2.0) { await manager.bluetooth.testPendingScanWaiterCount() == 1 }

        // Call cancelScanWaiter with a foreign, non-matching id — this must NOT
        // cancel the parked waiter. Against the pre-fix global cancel, this would
        // have resumed the waiter with a CancellationError.
        await manager.bluetooth.cancelScanWaiter(UUID())

        #expect(await manager.bluetooth.testPendingScanWaiterCount() == 1)

        // Power on: the waiter resolves and starts scanning with its filter.
        await Mock.simulatePowerOn()
        _ = try await scanTask.value  // Must NOT throw

        #expect(await Mock.waitForState("Scanning", on: manager))
        #expect(await manager.bluetooth.testPendingScanWaiterCount() == 0)
        #expect(await manager.bluetooth.testLastScanServices() == [scanUUID])

        await manager.stopScanning()
    }

    @Test func startScanningCancellationUnblocksWaiter() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let scanTask = Task { try await manager.startScanning() }
        _ = await pollUntil(timeout: 2.0) { await manager.bluetooth.testPendingScanWaiterCount() == 1 }

        // Cancelling the awaiting task unblocks the parked waiter with a `CancellationError`
        // and leaves no continuation behind.
        scanTask.cancel()
        // Bound the wait so a regression (waiter failing to unblock) fails explicitly instead of
        // wedging the whole test run; a matching cancel surfaces `CancellationError` here.
        do {
            try await withTimeout(nanoseconds: 4_000_000_000) {
                _ = try await scanTask.value
            }
            Issue.record("startScanning must throw CancellationError when cancelled, but returned normally")
        } catch is CancellationError {
            // Expected: the cancelled waiter surfaces a `CancellationError` through the task value.
        } catch {
            throw error
        }

        #expect(await manager.bluetooth.testPendingScanWaiterCount() == 0)
        #expect(await manager.bluetooth.testIsScanning() == false)

        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)
    }

    // MARK: - Discovery

    @Test func scanningDeliversDiscoveryEventsAndPeripherals() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        // `peripheralDiscoveries` does not replay, so subscribe before scanning starts.
        let discoveries = manager.peripheralDiscoveries

        try await manager.startScanning()

        let discovered = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        #expect(discovered?.id == Mock.testPeripheralID)
        // Preserve at least one assertion against snapshot fields — the snapshot the stream emitted.
        #expect(discovered?.advertisement?.localName == Mock.testPeripheralID)
        #expect(discovered?.cbIdentifier != nil)

        // The mock's connection-lifecycle peripheral advertises concurrently on the same shared
        // central, so filter for this test's peripheral rather than racing on whichever arrives first.
        let event = await firstEvent(
            from: discoveries,
            matching: { $0.advertisement.localName == Mock.testPeripheralID },
            withinNanoseconds: 3_000_000_000
        )
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

        try await manager.startScanning()
        _ = await Mock.waitForDiscovered(
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

        try await manager.startScanning()
        _ = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        await manager.stopScanning()

        // Powering off then on drives the `centralManagerDidUpdateState` path, which re-resolves
        // the live references for already-discovered peripherals on power-on.
        await Mock.simulatePowerOff()
        #expect(await Mock.waitForState("Powered Off", on: manager))

        await Mock.simulatePowerOn()
        #expect(await Mock.waitForState("Ready", on: manager))
    }

    @Test func discoveredPeripheralSugarReturnsInternedHandle() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let snapshot = try #require(snap)
        await manager.stopScanning()

        // The `.peripheral` sugar returns the very same instance `peripheral(id:)` would.
        let fromSugar = snapshot.peripheral
        let fromManager = manager.peripheral(id: snapshot.id)
        #expect(fromSugar === fromManager)
        #expect(fromSugar.id == Mock.testPeripheralID)
    }

    @Test func knownIdHandleReceivesMetadataOnDiscovery() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        // Create the handle first — before any discovery.
        let handle = manager.peripheral(id: Mock.testPeripheralID)
        #expect(handle.rssi == nil)
        #expect(handle.lastSeen == nil)
        #expect(handle.advertisement == nil)

        try await manager.startScanning()
        _ = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        await manager.stopScanning()

        // The same instance now carries metadata from discovery.
        #expect(handle.rssi != nil)
        #expect(handle.lastSeen != nil)
        #expect(handle.advertisement != nil)
        #expect(handle.advertisement?.localName == Mock.testPeripheralID)
    }

    @Test func discoveredPeripheralsStreamElementType() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        _ = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        await manager.stopScanning()

        // The replayed list element type is [DiscoveredPeripheral].
        var iterator = manager.discoveredPeripherals.makeAsyncIterator()
        let replayed: [DiscoveredPeripheral]? = await iterator.next()
        #expect(replayed?.contains(where: { $0.id == Mock.testPeripheralID }) == true)
    }

    @Test func handleMetadataAppliedBeforeBroadcast() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let handle = manager.peripheral(id: Mock.testPeripheralID)
        let stream = manager.discoveredPeripherals

        try await manager.startScanning()

        // On the first element containing the test id, immediately assert the handle
        // carries metadata — no polling, just a direct assertion after the element arrives.
        var found = false
        for await list in stream {
            if list.contains(where: { $0.id == Mock.testPeripheralID }) {
                #expect(handle.rssi != nil)
                found = true
                break
            }
        }
        #expect(found)

        await manager.stopScanning()
    }

    // MARK: - Connection

    @Test func connectToDiscoveredPeripheralSucceeds() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let discovered = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )

        // Stop scanning before any potential throw so leaked scan state can't affect later tests.
        await manager.stopScanning()

        let handle = try #require(discovered).peripheral
        // The live `CBPeripheral` is registered under this snapshot's id, so connect must not throw.
        try await handle.connect()
    }

    @Test func connectFailsWhenPoweredOff() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let discovered = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        await manager.stopScanning()
        let handle = try #require(discovered).peripheral

        await Mock.simulatePowerOff()
        _ = await Mock.waitForState("Powered Off", on: manager)

        await #expect(throws: PeripheralError.bluetoothPoweredOff) {
            try await handle.connect()
        }

        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)
    }

    @Test func connectAwaitsTransientState() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let discovered = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        await manager.stopScanning()
        let handle = try #require(discovered).peripheral

        // Transition to a transient state. `.unknown` deliberately avoids `.resetting`, which would
        // trigger peripheral invalidation (a later step); here the live reference must survive so
        // connect can proceed once the radio returns.
        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let connectTask = Task { try await handle.connect() }
        _ = await pollUntil(timeout: 2.0) {
            await manager.bluetooth.testPendingPoweredOnWaiterCount() == 1
        }

        await Mock.simulatePowerOn()
        try await connectTask.value

        // The parked radio wait was resolved; no continuation is left behind.
        #expect(await manager.bluetooth.testPendingPoweredOnWaiterCount() == 0)
    }

    @Test func connectTransientResolvingToPoweredOffThrows() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let discovered = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        await manager.stopScanning()
        let handle = try #require(discovered).peripheral

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let connectTask = Task { try await handle.connect() }
        _ = await pollUntil(timeout: 2.0) {
            await manager.bluetooth.testPendingPoweredOnWaiterCount() == 1
        }

        // The transient resolves to a terminal `.poweredOff`, failing the waiter with a typed error.
        await Mock.simulatePowerOff()
        await #expect(throws: PeripheralError.bluetoothPoweredOff) {
            try await connectTask.value
        }

        #expect(await manager.bluetooth.testPendingPoweredOnWaiterCount() == 0)

        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)
    }

    @Test func connectToUnknownPeripheralThrows() async throws {
        let manager = await Mock.makeManager()
        // ensureReady brings the central online so `.notFound` is deterministic.
        await Mock.ensureReady(manager)
        let handle = manager.peripheral(id: "never-discovered")

        do {
            try await handle.connect()
            Issue.record("Expected connect() to throw for an unknown peripheral")
        } catch let error as PeripheralError {
            #expect(error == .notFound)
        }
    }

    @Test func handleConnectDisconnectLifecycle() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let subscriberBaseline = await manager.bluetooth.testConnectionStateSubscriberCount()
        var changes = manager.connectionStateChanges.makeAsyncIterator()
        #expect(await Mock.waitForConnectionSubscription(on: manager, above: subscriberBaseline))

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()

        let connecting = await changes.next()
        #expect(connecting?.peripheralId == handle.id)
        #expect(connecting?.state == .connecting)
        #expect(handle.connectionState == .connecting)

        let connected = await changes.next()
        #expect(connected?.peripheralId == handle.id)
        #expect(connected?.state == .connected)
        #expect(handle.connectionState == .connected)

        try await handle.disconnect()

        let disconnecting = await changes.next()
        #expect(disconnecting?.state == .disconnecting)
        #expect(handle.connectionState == .disconnecting)

        let disconnected = await changes.next()
        #expect(disconnected?.state == .disconnected(reason: nil))
        #expect(handle.connectionState == .disconnected(reason: nil))
    }

    // MARK: - Logging

    @Test func loggingEnabledExercisesLogPaths() async throws {
        let manager = await Mock.makeManager(loggingEnabled: true)
        #expect(manager.loggingService.enabled == true)

        // Drive a scan cycle so the enabled logger evaluates its message autoclosures.
        await Mock.ensureReady(manager)
        try await manager.startScanning()
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

        let subscriberBaseline = await manager.bluetooth.testConnectionStateSubscriberCount()
        var changes = manager.connectionStateChanges.makeAsyncIterator()
        #expect(await Mock.waitForConnectionSubscription(on: manager, above: subscriberBaseline))

        // Discover the connectable test peripheral.
        try await manager.startScanning()
        let discovered = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(discovered).peripheral
        await manager.stopScanning()

        try await handle.connect()

        let connecting = await changes.next()
        #expect(connecting?.peripheralId == handle.id)
        #expect(connecting?.state == .connecting)

        let connected = await changes.next()
        #expect(connected?.peripheralId == handle.id)
        #expect(connected?.state == .connected)
    }

    @Test func connectionStateChangesEmitsDisconnectSequence() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let subscriberBaseline = await manager.bluetooth.testConnectionStateSubscriberCount()
        var changes = manager.connectionStateChanges.makeAsyncIterator()
        #expect(await Mock.waitForConnectionSubscription(on: manager, above: subscriberBaseline))

        try await manager.startScanning()
        let discovered = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(discovered).peripheral
        await manager.stopScanning()

        try await handle.connect()

        // Drain .connecting and .connected.
        _ = await changes.next()
        _ = await changes.next()

        try await handle.disconnect()

        let disconnecting = await changes.next()
        #expect(disconnecting?.peripheralId == handle.id)
        #expect(disconnecting?.state == .disconnecting)

        let disconnected = await changes.next()
        #expect(disconnected?.peripheralId == handle.id)
        #expect(disconnected?.state == .disconnected(reason: nil))
    }

    @Test func connectionStateChangesEmitsConnectFailureSequence() async throws {
        // Pre-condition: no stale connection state from a preceding lifecycle test.
        await Mock.simulateDisconnection()
        try? await Task.sleep(nanoseconds: 100_000_000)
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let subscriberBaseline = await manager.bluetooth.testConnectionStateSubscriberCount()
        var changes = manager.connectionStateChanges.makeAsyncIterator()
        #expect(await Mock.waitForConnectionSubscription(on: manager, above: subscriberBaseline))

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        // Force a clean disconnection on the spec to reset any lingering
        // `virtualConnections` / `isConnected` state left by a preceding test.
        await Mock.simulateDisconnection()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Configure failure only after discovery — a failed connectionResult can
        // interfere with mock advertising while the previous stack tears down.
        Mock.connectionTestDelegate.connectionResult = .failure(CBMError(.connectionTimeout))

        try await handle.connect()

        let connecting = await changes.next()
        let failed = await changes.next()

        #expect(connecting?.peripheralId == handle.id)
        #expect(connecting?.state == .connecting)
        #expect(failed?.peripheralId == handle.id)
        #expect(failed?.state == .failed(reason: .connectionTimeout))
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

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()

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
    private static let testReconnectPolicy = ReconnectPolicy(
        maxAttempts: 3,
        initialDelay: 0.001,
        maxDelay: 0.005,
        jitter: 0
    )

    @Test func systemReconnectOnUnexpectedDrop() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager(reconnectPolicy: Self.testReconnectPolicy)
        await Mock.ensureReady(manager)
        await manager.bluetooth.setReconnectPolicy(Self.testReconnectPolicy)

        let subscriberBaseline = await manager.bluetooth.testConnectionStateSubscriberCount()
        var changes = manager.connectionStateChanges.makeAsyncIterator()
        #expect(await Mock.waitForConnectionSubscription(on: manager, above: subscriberBaseline))

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()

        // Drain .connecting and .connected.
        let c1 = await changes.next()
        #expect(c1?.state == .connecting)
        let c2 = await changes.next()
        #expect(c2?.state == .connected)

        // Simulate an unexpected disconnect with the OS auto-reconnect option active.
        await Mock.simulateDisconnection()

        // Tier 0: OS sends isReconnecting=true → library emits .system with nil metadata.
        let c3 = await changes.next()
        guard case .reconnecting(let source, let attempt, let nextRetryAt) = c3?.state else {
            Issue.record("Expected .reconnecting, got \(String(describing: c3?.state))")
            return
        }
        #expect(source == .system)
        #expect(attempt == nil)
        #expect(nextRetryAt == nil)

        // No library ladder should have been armed — give the mock a beat to surface any
        // further events; a library reconnect would land in connectionStates.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let states = await manager.currentConnectionStates
        let libraryActive = states.values.contains { state in
            if case .reconnecting(.library, _, _) = state { return true }
            return false
        }
        #expect(!libraryActive, "Expected no .library reconnect state, got \(states)")

        // Cleanup: explicit disconnect to cancel any pending reconnect state.
        try? await handle.disconnect()
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func reconnectGivesUpAfterMaxAttempts() async throws {
        let giveUpPolicy = ReconnectPolicy(
            maxAttempts: 2,
            initialDelay: 0.001,
            maxDelay: 0.005,
            jitter: 0
        )

        Mock.connectionTestDelegate.connectionResult = .failure(CBMError(.connectionTimeout))
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager(reconnectPolicy: giveUpPolicy)
        await Mock.ensureReady(manager)
        await manager.bluetooth.setReconnectPolicy(giveUpPolicy)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        // Force a clean disconnection to reset any lingering mock state.
        await Mock.simulateDisconnection()
        try? await Task.sleep(nanoseconds: 100_000_000)

        try await handle.connect()

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
        try? await handle.disconnect()
        var cleanup = ReconnectPolicy()
        cleanup.maxAttempts = 0
        await manager.bluetooth.setReconnectPolicy(cleanup)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func explicitDisconnectDoesNotReconnect() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager(reconnectPolicy: Self.testReconnectPolicy)
        await Mock.ensureReady(manager)
        await manager.bluetooth.setReconnectPolicy(Self.testReconnectPolicy)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()

        // Drain .connecting and .connected.
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)

        // Explicit disconnect.
        try await handle.disconnect()

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
        await manager.bluetooth.setReconnectPolicy(cleanup)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func transientConnectFailureArmsReconnect() async throws {
        Mock.connectionTestDelegate.connectionResult = .failure(CBMError(.connectionTimeout))
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager(reconnectPolicy: Self.testReconnectPolicy)
        await Mock.ensureReady(manager)
        await manager.bluetooth.setReconnectPolicy(Self.testReconnectPolicy)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        // Force a clean disconnection to reset any lingering mock state.
        await Mock.simulateDisconnection()
        try? await Task.sleep(nanoseconds: 100_000_000)

        try await handle.connect()

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
        try? await handle.disconnect()
        var cleanup = ReconnectPolicy()
        cleanup.maxAttempts = 0
        await manager.bluetooth.setReconnectPolicy(cleanup)
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
        await manager.bluetooth.setReconnectPolicy(Self.testReconnectPolicy)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        // Connect with autoReconnect: false — the OS option is NOT passed, and the
        // library ladder is NOT armed.
        try await handle.connect(autoReconnect: false)

        // Drain .connecting and .connected.
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)

        // Inject an unexpected drop via the test hook (mock would emit isReconnecting: false anyway
        // since the OS option wasn't passed, but we use the hook for explicitness).
        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: false)

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
        try? await handle.disconnect()
        var cleanup = ReconnectPolicy()
        cleanup.maxAttempts = 0
        await manager.bluetooth.setReconnectPolicy(cleanup)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func osGiveUpHandsOffToTier1() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager(reconnectPolicy: Self.testReconnectPolicy)
        await Mock.ensureReady(manager)
        await manager.bluetooth.setReconnectPolicy(Self.testReconnectPolicy)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        // Connect with autoReconnect: true (default). The library ladder is armed
        // and the OS option is passed. We inject an OS give-up (isReconnecting: false)
        // via the test hook to simulate the OS giving up on its own reconnect.
        try await handle.connect()

        // Drain .connecting and .connected.
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)

        // Inject OS give-up: isReconnecting: false unexpected disconnect.
        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: false)

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
        try? await handle.disconnect()
        var cleanup = ReconnectPolicy()
        cleanup.maxAttempts = 0
        await manager.bluetooth.setReconnectPolicy(cleanup)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func explicitDisconnectCancelsPendingLibraryRetry() async throws {
        // Long enough that we can issue an explicit disconnect while the ladder is mid-sleep,
        // but short enough to keep suite time down (disconnect runs immediately after .reconnecting).
        let slowPolicy = ReconnectPolicy(
            maxAttempts: 3,
            initialDelay: 0.5,
            maxDelay: 0.5,
            jitter: 0
        )

        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager(reconnectPolicy: slowPolicy)
        await Mock.ensureReady(manager)
        await manager.bluetooth.setReconnectPolicy(slowPolicy)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()

        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)

        // Arm the library ladder, then cancel it mid-sleep with an explicit disconnect.
        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: false)

        let disconnected = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        guard case .disconnected = disconnected?.state else {
            Issue.record("Expected .disconnected, got \(String(describing: disconnected?.state))")
            return
        }

        let reconnecting = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        guard case .reconnecting(.library, let attempt, _) = reconnecting?.state else {
            Issue.record("Expected .reconnecting(.library), got \(String(describing: reconnecting?.state))")
            return
        }
        #expect(attempt == 1)

        try await handle.disconnect()

        let events = await drainConnectionStateChanges(from: changes, withinNanoseconds: 1_000_000_000)
        let states = events.map(\.state)

        #expect(states.contains(.disconnecting))
        #expect(states.contains(.disconnected(reason: nil)))

        let hasConnecting = states.contains(.connecting)
        let hasLibraryRetry = states.contains {
            if case .reconnecting(.library, _, _) = $0 { return true }
            return false
        }
        #expect(!hasConnecting, "Expected no reconnect .connecting after explicit cancel, got \(states)")
        #expect(!hasLibraryRetry, "Expected no further library retries after explicit cancel, got \(states)")

        await manager.bluetooth.setReconnectPolicy(ReconnectPolicy(maxAttempts: 0))
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func explicitDisconnectReportsCleanReasonDespiteUnderlyingError() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager(reconnectPolicy: ReconnectPolicy(maxAttempts: 0))
        await Mock.ensureReady(manager)
        await manager.bluetooth.setReconnectPolicy(ReconnectPolicy(maxAttempts: 0))

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .connecting
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .connected

        // Simulate an explicit disconnect that CoreBluetooth reports WITH a benign underlying error.
        // The contract is that an app-initiated disconnect reports `reason: nil` regardless.
        await manager.bluetooth.testSeedIntentionalDisconnect(handle.id)
        await manager.bluetooth.testInjectDisconnect(
            for: handle.id,
            isReconnecting: false,
            error: NSError(domain: "test.explicit", code: 1)
        )

        let disconnected = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        #expect(
            disconnected?.state == .disconnected(reason: nil),
            "Explicit disconnect must report a clean nil reason even when CoreBluetooth supplies an error, got \(String(describing: disconnected?.state))"
        )

        await manager.bluetooth.setReconnectPolicy(ReconnectPolicy(maxAttempts: 0))
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func nonFiniteReconnectPolicyDoesNotTrapScheduler() async throws {
        // `ReconnectPolicy` is public and unvalidated: a caller could pass non-finite delay/jitter.
        // Scheduling a reconnect with these must not trap the UInt64 nanosecond conversion.
        let hostilePolicy = ReconnectPolicy(
            maxAttempts: 2,
            initialDelay: .infinity,
            maxDelay: .nan,
            jitter: .nan
        )

        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager(reconnectPolicy: hostilePolicy)
        await Mock.ensureReady(manager)
        await manager.bluetooth.setReconnectPolicy(hostilePolicy)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .connecting
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .connected

        // Unexpected drop arms the library ladder; scheduling must survive the non-finite delay.
        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: false)

        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .disconnected
        let reconnecting = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        guard case .reconnecting(.library, let attempt, _) = reconnecting?.state else {
            Issue.record("Expected .reconnecting(.library) without trapping, got \(String(describing: reconnecting?.state))")
            return
        }
        #expect(attempt == 1)

        try await handle.disconnect()
        await manager.bluetooth.setReconnectPolicy(ReconnectPolicy(maxAttempts: 0))
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func successfulLibraryReconnectResetsAttemptCounter() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())

        let manager = await Mock.makeManager(reconnectPolicy: Self.testReconnectPolicy)
        await Mock.ensureReady(manager)
        await manager.bluetooth.setReconnectPolicy(Self.testReconnectPolicy)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()

        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)

        // First unexpected drop → ladder attempt 1, then successful reconnect.
        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: false)

        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .disconnected
        let firstLadder = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        guard case .reconnecting(.library, let firstAttempt, _) = firstLadder?.state else {
            Issue.record("Expected first .reconnecting(.library), got \(String(describing: firstLadder?.state))")
            return
        }
        #expect(firstAttempt == 1)

        let reconnectConnecting = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        #expect(reconnectConnecting?.state == .connecting)

        let reconnectConnected = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        #expect(reconnectConnected?.state == .connected)

        // Second unexpected drop must start a fresh ladder at attempt 1, not continue at 2.
        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: false)

        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .disconnected
        let secondLadder = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000)
        guard case .reconnecting(.library, let secondAttempt, _) = secondLadder?.state else {
            Issue.record("Expected second .reconnecting(.library), got \(String(describing: secondLadder?.state))")
            return
        }
        #expect(secondAttempt == 1)

        try? await handle.disconnect()
        await manager.bluetooth.setReconnectPolicy(ReconnectPolicy(maxAttempts: 0))
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func invalidateClearsIntentionalDisconnectIntent() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let id = "intentional-seed"
        await manager.bluetooth.testSeedIntentionalDisconnect(id)
        #expect(await manager.bluetooth.testContainsIntentionalDisconnect(id))

        await manager.bluetooth.testInvalidatePeripherals()
        #expect(!(await manager.bluetooth.testContainsIntentionalDisconnect(id)))
    }

    @Test func giveUpThenUnexpectedDropRearmsFreshLadder() async throws {
        let giveUpPolicy = ReconnectPolicy(
            maxAttempts: 1,
            initialDelay: 0.001,
            maxDelay: 0.005,
            jitter: 0
        )

        Mock.connectionTestDelegate.connectionResult = .failure(CBMError(.connectionTimeout))
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager(reconnectPolicy: giveUpPolicy)
        await Mock.ensureReady(manager)
        await manager.bluetooth.setReconnectPolicy(giveUpPolicy)

        var changes = manager.connectionStateChanges.makeAsyncIterator()
        // Force an actor hop so registration completes before we connect.
        _ = await manager.currentConnectionStates

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        await Mock.simulateDisconnection()
        try? await Task.sleep(nanoseconds: 100_000_000)

        try await handle.connect()

        // Exhaust the single-attempt ladder:
        // connecting → failed → reconnecting(1) → connecting → failed (give-up).
        let s0 = await changes.next()
        #expect(s0?.state == .connecting)

        let s1 = await changes.next()
        guard case .failed = s1?.state else {
            Issue.record("Expected .failed at index 1, got \(String(describing: s1?.state))")
            return
        }

        let s2 = await changes.next()
        guard case .reconnecting(.library, let a1, _) = s2?.state else {
            Issue.record("Expected .reconnecting(.library, 1), got \(String(describing: s2?.state))")
            return
        }
        #expect(a1 == 1)

        let s3 = await changes.next()
        #expect(s3?.state == .connecting)

        let s4 = await changes.next()
        guard case .failed = s4?.state else {
            Issue.record("Expected terminal .failed after give-up, got \(String(describing: s4?.state))")
            return
        }

        // Intent survives give-up: a later unexpected drop must arm a fresh ladder at attempt 1.
        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: false)

        let s5 = await changes.next()
        guard case .disconnected = s5?.state else {
            Issue.record("Expected .disconnected after post-give-up drop, got \(String(describing: s5?.state))")
            return
        }

        let s6 = await changes.next()
        guard case .reconnecting(.library, let a2, _) = s6?.state else {
            Issue.record("Expected fresh .reconnecting(.library, attempt: 1), got \(String(describing: s6?.state))")
            return
        }
        #expect(a2 == 1)

        try? await handle.disconnect()
        await manager.bluetooth.setReconnectPolicy(ReconnectPolicy(maxAttempts: 0))
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - State Restoration

    @Test func reliaBLEConfigRestoreIdentifierDefaultsToNil() {
        let config = ReliaBLEConfig()
        #expect(config.restoreIdentifier == nil)

        var custom = ReliaBLEConfig()
        custom.restoreIdentifier = "com.example.ble-central"
        #expect(custom.restoreIdentifier == "com.example.ble-central")
    }

    @Test func ensureInitializedWithoutRestoreIdentifierDoesNotCreateCentralWhenUnauthorized() async throws {
        // Default makeManager pins .notDetermined before construction. A restoreIdentifier of nil
        // must preserve the lazy contract: no central until authorize / allowedAlways.
        await Mock.simulateAuthorization(.notDetermined)

        let manager = await Mock.makeManager(restoreIdentifier: nil)
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(!(await manager.bluetooth.hasCentralManager))
        // Config default remains nil on the value type regardless of actor lifetime.
        #expect(ReliaBLEConfig().restoreIdentifier == nil)
    }

    @Test func ensureInitializedWithRestoreIdentifierCreatesCentralWhenAuthorized() async throws {
        let restoreId = "com.five3apps.relia-ble.tests.restore"

        // When authorized, a restoreIdentifier does not relax the auth gate — it only adds the
        // restore-id option to the existing creation path.
        await Mock.simulateAuthorization(.allowedAlways)
        await Mock.simulatePowerOn()

        let manager = await Mock.makeManager(restoreIdentifier: restoreId)
        #expect(await manager.bluetooth.testRestoreIdentifier() == restoreId)

        let optionKeys = await manager.bluetooth.testCentralCreationOptionKeys()
        #expect(optionKeys.contains(CBMCentralManagerOptionRestoreIdentifierKey))

        await Mock.ensureReady(manager)
        #expect(await manager.bluetooth.hasCentralManager)
        // Restore-id option and restoring peer shim are installed together (never disagree).
        #expect(await manager.bluetooth.testDelegateIsRestoringShim())
        #expect(!(await manager.bluetooth.testDelegateIsNonRestoringShim()))

        let noRestore = await Mock.makeManager(restoreIdentifier: nil)
        #expect(await noRestore.bluetooth.testCentralCreationOptionKeys().isEmpty)
        await Mock.ensureReady(noRestore)
        #expect(await noRestore.bluetooth.hasCentralManager)
        #expect(await noRestore.bluetooth.testDelegateIsNonRestoringShim())
        #expect(!(await noRestore.bluetooth.testDelegateIsRestoringShim()))
    }

    @Test @MainActor func willRestoreRepopulatesMapsSeedsConnectionStateAndBroadcasts() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer {
            Mock.connectionTestDelegate.connectionResult = .success(())
            Mock.clearStateRestoration()
        }

        let restoreId = "com.five3apps.relia-ble.tests.restore-broadcasts"
        let manager1 = await Mock.makeManager(restoreIdentifier: restoreId)
        await Mock.ensureReady(manager1)
        await manager1.bluetooth.testClearPersistedReconnectIntent()

        try await manager1.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager1,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager1.stopScanning()

        try await handle.connect()
        _ = await pollUntil(timeout: 3.0) {
            await manager1.currentConnectionStates[handle.id] == .connected
        }
        #expect(await manager1.bluetooth.testPersistedManualConnectHolds()[handle.id] == true)

        // Cold relaunch: shut down stack 1. Central deinit may zero virtualConnections, so
        // re-mark the spec connected before install — persisted intent survives in UserDefaults.
        await Mock.tearDown(manager1, resetMockConnections: false)
        Mock.connectionTestSpec.simulateConnection()

        let scanUUID = CBMUUID(string: "180D")
        Mock.installStateRestoration(
            restoreIdentifier: restoreId,
            peripherals: [Mock.connectionTestSpec],
            scanServices: [scanUUID]
        )

        CBMCentralManagerMock.simulateAuthorization(.notDetermined)
        let manager2 = await Mock.makeManager(restoreIdentifier: restoreId)
        let baseConn = await manager2.bluetooth.testConnectionStateSubscriberCount()
        let basePeriph = await manager2.bluetooth.testPeripheralsSubscriberCount()
        var peripherals = manager2.discoveredPeripherals.makeAsyncIterator()
        var connectionChanges = manager2.connectionStateChanges.makeAsyncIterator()
        let subscriptionsReady = await pollUntil(timeout: 3.0) {
            let connReady = await manager2.bluetooth.testConnectionStateSubscriberCount() > baseConn
            let periphReady = await manager2.bluetooth.testPeripheralsSubscriberCount() > basePeriph
            return connReady && periphReady
        }
        #expect(subscriptionsReady)

        CBMCentralManagerMock.simulateAuthorization(.allowedAlways)
        CBMCentralManagerMock.simulatePowerOn()
        try await manager2.authorizeBluetooth()

        let connectionSeeded = await pollUntil(timeout: 3.0) {
            let state = await manager2.currentConnectionStates[Mock.connectionTestPeripheralID]
            return state == .connected || state == .connecting
        }
        #expect(connectionSeeded)
        // Mock may restore as .connecting when virtualConnections was cleared by central deinit;
        // simulateConnection before install prefers .connected. Either way maps rehydrate.
        #expect(await manager2.bluetooth.testContainsCBPeripheral(Mock.connectionTestPeripheralID))
        #expect(await manager2.bluetooth.testIsReconnectEnabled(Mock.connectionTestPeripheralID))

        let restoredList = await manager2.bluetooth.discoveredPeripherals
        #expect(restoredList.contains(where: { $0.id == Mock.connectionTestPeripheralID }))

        // Restored peripherals are kept off the advertisement feed; discoveredPeripherals replays.
        let peripheralsEvent = await peripherals.next()
        #expect(peripheralsEvent?.contains(where: { $0.id == Mock.connectionTestPeripheralID }) == true)

        let connectionEvent = await connectionChanges.next()
        #expect(connectionEvent?.peripheralId == Mock.connectionTestPeripheralID)
        #expect(
            connectionEvent?.state == .connected
                || connectionEvent?.state == .connecting
        )

        let scanSettled = await pollUntil(timeout: 3.0) {
            let scanning = await manager2.bluetooth.testIsScanning()
            let pending = await manager2.bluetooth.testPendingRestoredScanServices()
            return scanning && pending == nil
        }
        #expect(scanSettled)

        await manager2.bluetooth.testClearPersistedReconnectIntent()
        await Mock.tearDown(manager2)
    }

    @Test @MainActor func willRestoreSeedingReconnectOnlyForConnectedOrConnecting() async throws {
        // D-restore case 1: a restored connected/connecting peripheral whose manual-connect hold
        // (autoReconnect: true, reconnectDesired = true) was persisted rehydrates that hold — which
        // supplies demand, re-arms reconnect intent (so the link comes back armed), and suppresses
        // idle. Disconnected-peripheral seeding is a direct-handler unit test (item 4) — iOS never
        // restores disconnected peripherals, and the mock always restores specs as
        // connected/connecting based on virtualConnections.
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer {
            Mock.connectionTestDelegate.connectionResult = .success(())
            Mock.clearStateRestoration()
        }

        let restoreId = "com.five3apps.relia-ble.tests.restore-seeding"
        let manager1 = await Mock.makeManager(restoreIdentifier: restoreId)
        await Mock.ensureReady(manager1)
        await manager1.bluetooth.testClearPersistedReconnectIntent()

        try await manager1.startScanning()
        let connectionPeripheral = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager1,
            withinNanoseconds: 3_000_000_000
        )
        let connected = try #require(connectionPeripheral).peripheral
        await manager1.stopScanning()

        try await connected.connect()
        _ = await pollUntil(timeout: 3.0) {
            await manager1.currentConnectionStates[connected.id] == .connected
        }
        // connect() with the default autoReconnect: true persisted a hold { id: true }.
        #expect(await manager1.bluetooth.testPersistedManualConnectHolds()[connected.id] == true)

        await Mock.tearDown(manager1, resetMockConnections: false)
        Mock.connectionTestSpec.simulateConnection()

        Mock.installStateRestoration(
            restoreIdentifier: restoreId,
            peripherals: [Mock.connectionTestSpec],
            scanServices: nil
        )

        let manager2 = try await Mock.makeRestoredManager(restoreIdentifier: restoreId)

        #expect(await pollUntil(timeout: 3.0) {
            await manager2.currentConnectionStates[Mock.connectionTestPeripheralID] == .connected
        })
        // The rehydrated hold re-armed reconnect intent — the link is genuinely able to be
        // re-linked, not merely a residual OS connection. And because the hold suppresses idle,
        // the restored link stays up (case 1).
        #expect(await manager2.bluetooth.testIsReconnectEnabled(Mock.connectionTestPeripheralID))
        #expect(await manager2.bluetooth.testHasManualConnectHold(for: Mock.connectionTestPeripheralID))

        await manager2.bluetooth.testClearPersistedReconnectIntent()
        await Mock.tearDown(manager2)
    }

    @Test @MainActor func willRestoreDoesNotRearmReconnectWithoutPersistedIntent() async throws {
        // D-restore case 2 (no persisted hold): a restored link the app never explicitly requested
        // must NOT come back armed. Reconnect intent is demand-derived (from a rehydrated hold),
        // so with no persisted hold there is no demand and no re-arming; the link is seeded and an
        // idle timer starts.
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer {
            Mock.connectionTestDelegate.connectionResult = .success(())
            Mock.clearStateRestoration()
        }

        let restoreId = "com.five3apps.relia-ble.tests.restore-no-intent"
        let manager1 = await Mock.makeManager(restoreIdentifier: restoreId)
        await Mock.ensureReady(manager1)
        await manager1.bluetooth.testClearPersistedReconnectIntent()

        try await manager1.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager1,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager1.stopScanning()

        try await handle.connect()
        _ = await pollUntil(timeout: 3.0) {
            await manager1.currentConnectionStates[handle.id] == .connected
        }
        // Wipe the durable hold before relaunch: the OS will still restore the residual connection,
        // but there is no persisted intent — exactly the "restored without an explicit ask" case.
        await manager1.bluetooth.testClearPersistedReconnectIntent()
        #expect(await manager1.bluetooth.testPersistedManualConnectHolds().isEmpty)

        await Mock.tearDown(manager1, resetMockConnections: false)
        Mock.connectionTestSpec.simulateConnection()

        Mock.installStateRestoration(
            restoreIdentifier: restoreId,
            peripherals: [Mock.connectionTestSpec],
            scanServices: nil
        )
        let manager2 = try await Mock.makeRestoredManager(restoreIdentifier: restoreId)

        #expect(await pollUntil(timeout: 3.0) {
            await manager2.currentConnectionStates[Mock.connectionTestPeripheralID] == .connected
        })
        // No hold was persisted, so nothing re-arms the link.
        #expect(!(await manager2.bluetooth.testIsReconnectEnabled(Mock.connectionTestPeripheralID)))
        #expect(!(await manager2.bluetooth.testHasManualConnectHold(for: Mock.connectionTestPeripheralID)))

        await manager2.bluetooth.testClearPersistedReconnectIntent()
        await Mock.tearDown(manager2)
    }

    @Test func willRestoreIgnoresEmptyScanServiceFilter() async throws {
        // Direct-handler unit test: CoreBluetoothMock treats a non-nil (even empty) scan-services
        // array as `isScanning = true` at restore-init, so the faithful fixture cannot express
        // "empty filter ignored" without fighting the mock. Production still ignores empty filters.
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await manager.bluetooth.testHandleWillRestoreState(scanServices: [])

        #expect(!(await manager.bluetooth.testIsScanning()))
        #expect(await manager.bluetooth.testPendingRestoredScanServices() == nil)
    }

    @Test @MainActor func invalidatePreservesHoldsProjectsReconnectingAndKeepsDeferredScan() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer {
            Mock.connectionTestDelegate.connectionResult = .success(())
            Mock.clearStateRestoration()
        }

        let restoreId = "com.five3apps.relia-ble.tests.restore-invalidate"
        let manager1 = await Mock.makeManager(restoreIdentifier: restoreId)
        await Mock.ensureReady(manager1)
        await manager1.bluetooth.testClearPersistedReconnectIntent()

        try await manager1.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager1,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager1.stopScanning()

        try await handle.connect()
        _ = await pollUntil(timeout: 3.0) {
            await manager1.currentConnectionStates[handle.id] == .connected
        }

        await Mock.tearDown(manager1, resetMockConnections: false)
        Mock.connectionTestSpec.simulateConnection()

        Mock.installStateRestoration(
            restoreIdentifier: restoreId,
            peripherals: [Mock.connectionTestSpec],
            scanServices: nil
        )
        let manager2 = try await Mock.makeRestoredManager(restoreIdentifier: restoreId)

        #expect(await pollUntil(timeout: 3.0) {
            await manager2.bluetooth.testIsReconnectEnabled(Mock.connectionTestPeripheralID)
        })

        // Direct-handler: stash a pending restored scan, then invalidate (faithful second restore
        // while powered off is awkward because mock forces isScanning at restore-init).
        let scanUUID = CBUUID(string: "180D")
        CBMCentralManagerMock.simulatePowerOff()
        #expect(await Mock.waitForState("Powered Off", on: manager2))
        await manager2.bluetooth.testHandleWillRestoreState(scanServices: [scanUUID])
        #expect(await manager2.bluetooth.testPendingRestoredScanServices() == [scanUUID])

        await manager2.bluetooth.testInvalidatePeripherals()
        // D-1 event 13: the deferred restored scan is **preserved** across the invalidate.
        #expect(await manager2.bluetooth.testPendingRestoredScanServices() == [scanUUID])
        // Demand survives a radio outage: the rehydrated hold still wants reconnect, so the id stays
        // armed and is projected into `AwaitingRadio` rather than cleared to nil.
        #expect(await manager2.bluetooth.testIsReconnectEnabled(Mock.connectionTestPeripheralID))
        if case .reconnecting(.library, nil, nil) = await manager2.currentConnectionStates[Mock.connectionTestPeripheralID] {
            // Expected AwaitingRadio projection.
        } else {
            Issue.record("Expected reconnecting(.library, nil, nil), got \(String(describing: await manager2.currentConnectionStates[Mock.connectionTestPeripheralID]))")
        }
        // invalidate must **never** write to disk; the persisted hold is untouched.
        #expect(await manager2.bluetooth.testPersistedManualConnectHolds()[Mock.connectionTestPeripheralID] == true)

        CBMCentralManagerMock.simulatePowerOn()
        await manager2.bluetooth.testClearPersistedReconnectIntent()
        await Mock.tearDown(manager2)
    }

    @Test func invalidateHandleIsNotStaleConnectedAndKeepsMetadata() async throws {
        // The two halves of a radio reset pull in opposite directions, and the handle must honor both:
        // last-known metadata survives (it is still the best thing known about the device), while a stale
        // `.connected` must NOT survive — a handle stuck reporting `.connected` after the library tore the
        // connection down is not stale, it is false. A wanted reconnect id is honestly re-projected to
        // `.reconnecting(.library, nil, nil)` (AwaitingRadio) rather than left claiming connected.
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()
        #expect(await pollUntil(timeout: 3.0) { handle.connectionState == .connected })

        let priorName = handle.name
        let priorRSSI = try #require(handle.rssi)

        await manager.bluetooth.testInvalidatePeripherals()

        #expect(handle.connectionState != .connected)
        #expect(handle.connectionState == .reconnecting(source: .library, attempt: nil, nextRetryAt: nil))
        #expect(await manager.currentConnectionStates[handle.id] != .connected)
        #expect(handle.name == priorName)
        #expect(handle.rssi == priorRSSI)
    }

    @Test func invalidatePeripheralsEmitsTerminalConnectionStateChange() async throws {
        // Clearing tracked connection state is the one transition a subscriber cannot infer on its own: a cleared
        // peripheral produces no further events, so without an explicit emit a UI driven only by
        // `connectionStateChanges` renders `.connected` forever after a radio reset. The handle reverting to `nil`
        // is not enough — nothing tells the app to go re-read it.
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()
        #expect(await pollUntil(timeout: 3.0) { handle.connectionState == .connected })

        // Subscribe before invalidating — `connectionStateChanges` has no replay, so a stream created afterwards
        // would miss the very event under test, and creating one only *enqueues* registration.
        let subscriberBaseline = await manager.bluetooth.testConnectionStateSubscriberCount()
        let changes = manager.connectionStateChanges
        #expect(await Mock.waitForConnectionSubscription(on: manager, above: subscriberBaseline))

        let id = handle.id
        let collector = Task { () -> ConnectionStateChange? in
            for await change in changes
            where change.peripheralId == id && change.state == .disconnected(reason: .bluetoothUnavailable) {
                return change
            }
            return nil
        }

        await manager.bluetooth.testInvalidatePeripherals()

        // Bound the wait: a regression that drops the emit must fail this test, not hang the suite.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            collector.cancel()
        }
        let terminal = await collector.value
        watchdog.cancel()

        #expect(terminal?.state == .disconnected(reason: .bluetoothUnavailable))
        // The event describes the transition; the handle re-projects to AwaitingRadio because this
        // id still wants reconnect (a hold is held), so it is not `.connected` and not `nil`.
        #expect(handle.connectionState != .connected)
        #expect(handle.connectionState == .reconnecting(source: .library, attempt: nil, nextRetryAt: nil))
    }

    @Test func willRestoreDefersScanUntilPoweredOn() async throws {
        // Direct-handler unit test: CoreBluetoothMock sets `isScanning = true` synchronously
        // inside central init when scan services are restored, so a faithful cold-relaunch cannot
        // observe a deferred pending filter. Exercise our handler's powered-off deferral directly.
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await Mock.simulatePowerOff()
        #expect(await Mock.waitForState("Powered Off", on: manager))

        let scanUUID = CBUUID(string: "180D")
        await manager.bluetooth.testHandleWillRestoreState(scanServices: [scanUUID])

        #expect(await manager.bluetooth.testPendingRestoredScanServices() == [scanUUID])
        #expect(!(await manager.bluetooth.testIsScanning()))

        await Mock.simulatePowerOn()
        let becameScanning = await Mock.waitForState("Scanning", on: manager)
        if !becameScanning {
            #expect(await Mock.waitForState("Ready", on: manager))
        }

        let resumed = await pollUntil(timeout: 3.0) {
            let pending = await manager.bluetooth.testPendingRestoredScanServices()
            let scanning = await manager.bluetooth.testIsScanning()
            return pending == nil && scanning
        }
        #expect(resumed)
        #expect(await manager.bluetooth.testPendingRestoredScanServices() == nil)
        #expect(await manager.bluetooth.testIsScanning())

        await manager.stopScanning()
    }

    @Test func willRestoreDisconnectedPeripheralSeedsNothing() async throws {
        // Direct-handler: iOS never restores disconnected peripherals; this only exercises our
        // defensive `.disconnected` switch (no connectionStates / reconnectEnabled seeding).
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        #expect(await manager.currentConnectionStates[handle.id] == nil)
        #expect(!(await manager.bluetooth.testIsReconnectEnabled(handle.id)))

        await manager.bluetooth.testHandleWillRestoreState(peripheralIds: [handle.id])

        #expect(await manager.currentConnectionStates[handle.id] == nil)
        #expect(!(await manager.bluetooth.testIsReconnectEnabled(handle.id)))
        // Live reference remains registered from discovery.
        #expect(await manager.bluetooth.testContainsCBPeripheral(handle.id))
    }

    @Test func restorePathInternsSameHandle() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        // Pre-create the handle — before any discovery or restore.
        let handle = manager.peripheral(id: Mock.testPeripheralID)
        #expect(handle.cbIdentifier == nil)

        // First discover so live refs and prior metadata exist.
        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let discovered = try #require(snap)
        await manager.stopScanning()
        let priorRSSI = discovered.rssi
        let priorAd = discovered.advertisement
        #expect(handle.rssi != nil)

        // Drive restore via the test hook — this re-binds the live CBPeripheral.
        await manager.bluetooth.testHandleWillRestoreState(peripheralIds: [Mock.testPeripheralID])

        // The same handle instance received cbIdentifier metadata from restore.
        #expect(handle.cbIdentifier != nil)
        #expect(await manager.bluetooth.testContainsCBPeripheral(Mock.testPeripheralID))

        // Regression guard for the shared-helper merge rule: restoration carries no advertisement payload and no
        // RSSI, so it must KEEP the values the earlier discovery established rather than wiping them. `#require`
        // rather than `if let` — if discovery stopped producing these, the guard would silently pass and stop
        // protecting anything.
        let requiredRSSI = try #require(priorRSSI)
        let requiredAd = try #require(priorAd)
        #expect(handle.rssi == requiredRSSI)
        #expect(handle.advertisement == requiredAd)
    }

    // MARK: - Multi-Manager Isolation

    @Test func twoManagersWithDistinctRestoreIdsHaveIndependentState() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let restoreA = "com.five3apps.relia-ble.tests.iso-a"
        let restoreB = "com.five3apps.relia-ble.tests.iso-b"

        let managerA = await Mock.makeManager(restoreIdentifier: restoreA, tearDownPrevious: true)
        await Mock.ensureReady(managerA)

        // Second stack stays live alongside the first — validates instance isolation end-to-end.
        let managerB = await Mock.makeManager(restoreIdentifier: restoreB, tearDownPrevious: false)
        await Mock.ensureReady(managerB)

        #expect(await managerA.bluetooth.hasCentralManager)
        #expect(await managerB.bluetooth.hasCentralManager)
        #expect(await managerA.bluetooth.testRestoreIdentifier() == restoreA)
        #expect(await managerB.bluetooth.testRestoreIdentifier() == restoreB)

        // A discovers while B is idle — B's discovered list must stay empty.
        try await managerA.startScanning()
        let discoveredOnA = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: managerA,
            withinNanoseconds: 3_000_000_000
        )
        #expect(discoveredOnA != nil)
        #expect(await managerA.bluetooth.testContainsCBPeripheral(Mock.testPeripheralID))
        #expect(await managerB.bluetooth.discoveredPeripherals.isEmpty)
        #expect(!(await managerB.bluetooth.testContainsCBPeripheral(Mock.testPeripheralID)))
        await managerA.stopScanning()

        // B discovers independently into its own maps.
        try await managerB.startScanning()
        let discoveredOnB = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: managerB,
            withinNanoseconds: 3_000_000_000
        )
        #expect(discoveredOnB != nil)
        #expect(await managerB.bluetooth.testContainsCBPeripheral(Mock.testPeripheralID))
        await managerB.stopScanning()

        // Connect only on A; B must not observe connection state for that peripheral.
        try await managerA.startScanning()
        let connectableA = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: managerA,
            withinNanoseconds: 3_000_000_000
        )
        let peripheralA = try #require(connectableA).peripheral
        await managerA.stopScanning()

        try await peripheralA.connect()
        #expect(await pollUntil(timeout: 3.0) {
            await managerA.currentConnectionStates[peripheralA.id] == .connected
        })
        #expect(await managerB.currentConnectionStates[peripheralA.id] == nil)
        #expect(await managerB.bluetooth.testIsReconnectEnabled(peripheralA.id) == false)

        // Both stacks still alive after the cross-manager exercise.
        #expect(await managerA.bluetooth.hasCentralManager)
        #expect(await managerB.bluetooth.hasCentralManager)

        await Mock.tearDown(managerA)
        await Mock.tearDown(managerB)
    }

    @Test func authorizeCancellationDoesNotAffectOtherManager() async throws {
        await Mock.simulateAuthorization(.notDetermined)

        let managerA = await Mock.makeManager(tearDownPrevious: true)
        let managerB = await Mock.makeManager(tearDownPrevious: false)

        let taskA = Task { try await managerA.authorizeBluetooth() }
        let taskB = Task { try await managerB.authorizeBluetooth() }

        // Both should be suspended on the undetermined decision.
        try? await Task.sleep(nanoseconds: 150_000_000)
        taskA.cancel()
        let resultA = await taskA.result
        switch resultA {
        case .failure(let error):
            #expect(error is CancellationError)
        case .success:
            // Already resolved if mock auth flipped early — still must not break B.
            break
        }

        // Cancelling A must leave B's waiter intact — grant auth and bounce power so B's
        // central receives didUpdateState and resolvePendingAuthorization runs.
        await Mock.simulateAuthorization(.allowedAlways)
        await Mock.simulatePowerOff()
        await Mock.simulatePowerOn()

        try await taskB.value
        #expect(await managerB.bluetooth.hasCentralManager)

        await Mock.tearDown(managerA)
        await Mock.tearDown(managerB)
    }

    @Test func twoManagersIndependentHandleRegistries() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let managerA = await Mock.makeManager(tearDownPrevious: true)
        await Mock.ensureReady(managerA)

        let managerB = await Mock.makeManager(tearDownPrevious: false)
        await Mock.ensureReady(managerB)

        // Same id string → two distinct handle instances.
        let handleA = managerA.peripheral(id: Mock.testPeripheralID)
        let handleB = managerB.peripheral(id: Mock.testPeripheralID)
        #expect(handleA !== handleB)
        #expect(handleA == handleB)
        #expect(handleA.hashValue == handleB.hashValue)

        let set: Set<Peripheral> = [handleA, handleB]
        #expect(set.count == 1, "id-only equality means same-id handles from different managers count as one in a Set")

        // Discover only on A.
        try await managerA.startScanning()
        _ = await Mock.waitForDiscovered(
            id: Mock.testPeripheralID,
            on: managerA,
            withinNanoseconds: 3_000_000_000
        )
        await managerA.stopScanning()

        #expect(await managerA.bluetooth.testContainsCBPeripheral(Mock.testPeripheralID))
        #expect(!(await managerB.bluetooth.testContainsCBPeripheral(Mock.testPeripheralID)))

        // Only A's handle has live metadata.
        #expect(handleA.rssi != nil)
        #expect(handleB.rssi == nil)

        await Mock.tearDown(managerA)
        await Mock.tearDown(managerB)
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
        await manager.bluetooth.updateState()

        let broadcastA = await subscriberA.next()
        let broadcastB = await subscriberB.next()

        #expect(broadcastA != nil)
        #expect(broadcastB != nil)
    }

    @Test func handleOrphansWhenManagerDeallocates() async throws {
        // This test is the retain-graph leak detector: if anything reachable from the
        // actor holds the manager strongly, the manager won't deallocate and this fails.

        let orphanedHandle: Peripheral = await Task {
            let manager = await Mock.makeManager(tearDownPrevious: true)
            let handle = manager.peripheral(id: "orphaned-by-deinit")
            // Shut down the actor so every stream subscription ends — a live subscriber retains the actor by
            // design, and the actor is the thing that would drag the manager along if the retain graph were wrong.
            await manager.bluetooth.shutdown()
            // Drop the harness's own strong reference; otherwise `activeManager` alone keeps the manager alive and
            // this test would silently prove nothing.
            Mock.releaseActiveManager()

            return handle
        }.value

        // The manager has now fallen out of every scope that held it. If it deallocated, the handle's weak manager
        // reference is nil and `connect()` reports `.bluetoothUnavailable`. Anything else — notably `.notFound`,
        // which means the manager is somehow still alive and reachable — indicates something reachable from the
        // actor is retaining the manager strongly, which is the leak this test exists to catch.
        do {
            try await orphanedHandle.connect()
            Issue.record("Expected connect() on orphaned handle to throw")
        } catch let error as PeripheralError {
            #expect(error == .bluetoothUnavailable)
        }
    }

    // MARK: - Work-Driven Demand Substrate

    @Test func workLeaseAutoConnectsWithoutPriorConnect() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        // No manual connect() — the lease alone must create demand and drive an auto-connect.
        let token = try await handle.acquireWorkLease()

        #expect(await manager.bluetooth.testWorkCount(for: handle.id) == 1)
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })

        await handle.releaseWorkLease(token)
        #expect(await manager.bluetooth.testWorkCount(for: handle.id) == 0)
    }

    @Test func leaseOnNeverSeenIdThrowsNotFound() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)
        let handle = manager.peripheral(id: "never-seen-lease")

        await #expect(throws: PeripheralError.notFound) {
            _ = try await handle.acquireWorkLease()
        }
    }

    @Test func doubleReleaseIsNoOp() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        // Two leases held. A broken `Int` refcount would drop to zero on the double-release and tear
        // down a link that still has work — the Set<UUID> bookkeeping must keep it at 1.
        let tokenA = try await handle.acquireWorkLease()
        let tokenB = try await handle.acquireWorkLease()
        #expect(await manager.bluetooth.testWorkCount(for: handle.id) == 2)

        await handle.releaseWorkLease(tokenA)
        await handle.releaseWorkLease(tokenA)
        #expect(await manager.bluetooth.testWorkCount(for: handle.id) == 1)

        await handle.releaseWorkLease(tokenB)
        #expect(await manager.bluetooth.testWorkCount(for: handle.id) == 0)
    }

    @Test func connectPoweredOffSetsHoldAndRelinksOnPowerOn() async throws {
        // D-hold, completed for step 6: a `connect()` issued while powered off registers the hold
        // BEFORE the radio wait, throws `bluetoothPoweredOff`, and leaves durable demand — which the
        // radio-return sweep (D-1 event 12) turns into a relink once the radio returns.
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        await Mock.simulatePowerOff()
        _ = await Mock.waitForState("Powered Off", on: manager)

        await #expect(throws: PeripheralError.bluetoothPoweredOff) {
            try await handle.connect()
        }

        // The hold is registered BEFORE the radio wait, so a thrown connect still leaves durable demand.
        #expect(await manager.bluetooth.testHasManualConnectHold(for: handle.id))

        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)

        // Step 6: the radio-return sweep (D-1 event 12) re-links the held id without a second
        // connect() call. The sweep re-evaluates demanded ids from the hold (not just tracked-state
        // ids), so this hold — created after the earlier invalidate — is linked once the radio
        // returns.
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })
    }

    @Test func manualDisconnectDuringRadioOutageSucceeds() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()
        #expect(await manager.bluetooth.testHasManualConnectHold(for: handle.id))

        // A radio reset invalidates live references (clears cbPeripherals) but preserves the hold.
        await Mock.simulateInitialState(.resetting)
        _ = await Mock.waitForState("Resetting", on: manager)
        #expect(!(await manager.bluetooth.testContainsCBPeripheral(handle.id)))
        #expect(await manager.bluetooth.testHasManualConnectHold(for: handle.id))

        // Dropping the hold during a radio outage must succeed, not throw .notFound.
        try await handle.disconnect()
        #expect(!(await manager.bluetooth.testHasManualConnectHold(for: handle.id)))

        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)
    }

    @Test func manualDisconnectClearsHoldAndTearsDown() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .connecting
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .connected
        #expect(await manager.bluetooth.testHasManualConnectHold(for: handle.id))

        try await handle.disconnect()
        #expect(!(await manager.bluetooth.testHasManualConnectHold(for: handle.id)))

        let events = await drainConnectionStateChanges(from: changes, withinNanoseconds: 3_000_000_000)
        let states = events.map { $0.state }
        #expect(states.contains(.disconnecting))
        #expect(states.contains(.disconnected(reason: nil)))
        let hasReconnecting = states.contains {
            if case .reconnecting = $0 { return true }
            return false
        }
        #expect(!hasReconnecting)
    }

    // MARK: - Idle Disconnect (Grace Window & Teardown)

    @Test func idleDisconnectAfterLastLeaseReleased() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0.1)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        let token = try await handle.acquireWorkLease()
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })

        // Releasing the last lease drops demand and starts the idle grace window.
        await handle.releaseWorkLease(token)
        #expect(await manager.bluetooth.testWorkCount(for: handle.id) == 0)

        // The link tears down cleanly within the idle interval.
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .disconnected(reason: nil)
        })
    }

    @Test func manualConnectHoldSuppressesIdle() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0.1)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })

        // Quiet for 3x the interval — the manual-connect hold suppresses idle teardown.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await manager.currentConnectionStates[handle.id] == .connected)
    }

    @Test func disconnectWithActiveLeaseRelinks() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0.1)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()
        let token = try await handle.acquireWorkLease()
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })

        try await handle.disconnect()
        #expect(!(await manager.bluetooth.testHasManualConnectHold(for: handle.id)))
        #expect(await manager.bluetooth.testWorkCount(for: handle.id) == 1)

        // The link cancels once: exactly one .disconnecting.
        let events = await drainConnectionStateChanges(from: changes, withinNanoseconds: 3_000_000_000)
        let states = events.map { $0.state }
        #expect(states.filter { $0 == .disconnecting }.count == 1)
        #expect(states.contains(.disconnected(reason: nil)))
        // Step 6: the deferred half — work re-drives the link back to .connected. A Manual
        // disconnect() that races pending work must not strand the lease.
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })
        #expect(await manager.bluetooth.testWorkCount(for: handle.id) == 1)
        await handle.releaseWorkLease(token)
    }

    @Test func tier0BlipDuringGraceRearmsIdle() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0.3)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        let token = try await handle.acquireWorkLease()
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })

        // Release the lease (idle grace armed), then a Tier-0 reconnect lands during the grace window.
        await handle.releaseWorkLease(token)
        await manager.bluetooth.testInjectConnect(for: handle.id)

        // Event 8: the reconnect landing re-arms idle; the link is cancelled again.
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .disconnected(reason: nil)
        })
    }

    @Test func restoredLinkRetainedWhenWorkDeclared() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0.5)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        let token = try await handle.acquireWorkLease()
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })

        // Release (idle grace armed), then declare work again inside the grace window.
        await handle.releaseWorkLease(token)
        let token2 = try await handle.acquireWorkLease()

        // The link is retained — idle was cancelled, still connected.
        #expect(await manager.bluetooth.testWorkCount(for: handle.id) == 1)
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })

        await handle.releaseWorkLease(token2)
    }

    @Test func idleWhileLibraryReconnectingSettlesCleanly() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        var policy = ReconnectPolicy()
        policy.maxAttempts = 5
        policy.initialDelay = 1.0
        let manager = await Mock.makeManager(reconnectPolicy: policy)
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0.1)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        let token = try await handle.acquireWorkLease()
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })

        // Unexpected drop arms the Tier-1 ladder (lease held → wantsReconnect).
        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: false)
        #expect(await pollUntil(timeout: 3.0) {
            if case .reconnecting(.library, _, _) = await manager.currentConnectionStates[handle.id] {
                return true
            }
            return false
        })

        // Demand drops while the ladder sleeps → settle cleanly, no stuck .disconnecting.
        await handle.releaseWorkLease(token)
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .disconnected(reason: nil)
        })
        #expect(await manager.currentConnectionStates[handle.id] != .disconnecting)
    }

    // Defect 1: a manual disconnect issued while a connect is still pending (`.connecting`) must cancel
    // the pending CoreBluetooth connect — not just settle the library state — so the OS cannot complete
    // the link later (FR-1.2 / D-tier).
    @Test func manualDisconnectDuringConnectingCancelsPendingConnect() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .connecting

        try await handle.disconnect()

        // Settled synchronously to a clean disconnected, never a stuck .disconnecting.
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .disconnected(reason: nil)
        })
        #expect(await manager.currentConnectionStates[handle.id] != .disconnecting)

        // The pending connect must be suppressed: drain long enough for the mock to have completed the
        // connect if the cancel had not fired, and assert no later `.connected` ever lands.
        let later = await drainConnectionStateChanges(from: changes, withinNanoseconds: 2_000_000_000)
        let anyConnected = later.contains { $0.state == .connected }
        #expect(!anyConnected)
        #expect(await manager.currentConnectionStates[handle.id] == .disconnected(reason: nil))
    }

    // Defect 1b: manual disconnect while a cached Tier-0 / system reconnect is in limbo (.reconnecting(.system))
    // with a non-connecting live peripheral must cancel the OS's pending reconnect work (FR-1.2 / D-tier).
    // This pins the `cachedSystemReconnect(id:)` arm of the `applyManualDisconnect` predicate — the same
    // bug class as `fireIdle` had in bbff3d1.
    @Test func manualDisconnectDuringCachedSystemReconnectCancels() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        // White-box Tier-0-limbo setup: put ONLY the cached state into `.reconnecting(.system)` while
        // the live `CBPeripheral` stays `.disconnected` (never connected in this scenario).
        await manager.bluetooth.testSeedSystemReconnectState(for: handle.id)

        // Confirm the live peripheral is genuinely non-connecting AND non-connected when the manual
        // disconnect fires, so the cancel can only be explained by the cached path — not the `.connecting`
        // arm of the predicate. This cannot silently drift back onto the `.connecting` arm.
        let liveState = await manager.bluetooth.testCBPeripheralState(for: handle.id)
        #expect(liveState != .connecting,
                "Live peripheral must be non-connecting so only the cached path can drive the cancel")
        #expect(liveState != .connected)

        // Manual disconnect triggers `applyManualDisconnect`, which must clear the hold AND issue exactly
        // one cancel to stop the OS's pending reconnect work, driven solely by the CACHED
        // `.reconnecting(.system)` state.
        try await handle.disconnect()

        #expect(!(await manager.bluetooth.testHasManualConnectHold(for: handle.id)),
                "Manual disconnect must clear the manual-connect hold")
        #expect(await manager.currentConnectionStates[handle.id] == .disconnected(reason: nil))
        #expect(await manager.currentConnectionStates[handle.id] != .disconnecting)
        #expect(await manager.bluetooth.testCancelPeripheralConnectionCount(for: handle.id) == 1,
                "Manual disconnect must issue exactly one cancel for a CACHED Tier-0 reconnect with a non-connecting live peripheral")
        #expect(await manager.bluetooth.testContainsIntentionalDisconnect(handle.id) == false,
                "Manual disconnect of a non-connected cached Tier-0 limbo must not mark the disconnect intentional")
    }

    // Idle teardown while a Tier-0 / system reconnect is in flight must settle AND cancel, so the OS
    // cannot relink a link nobody wants (FR-1.2 / D-tier). This is the CACHED arm of that predicate.
    //
    // Seeded white-box rather than driven through a real mock disconnection on purpose: CoreBluetoothMock
    // always resolves a Tier-0 attempt one way or the other (relinking on success, or reporting
    // `didFailToConnect` on failure), so the window in which the cached state is `.reconnecting(.system)`
    // is timing-dependent and cannot be held open. An end-to-end version of this test raced the mock and
    // failed intermittently on slower CI machines in both directions. The real-radio behaviour is covered
    // as an on-device observation (see `docs/test-plans/`, Suite F3), and the live `.connecting` arm of the
    // same predicate is pinned by `idleTeardownDuringLiveConnectingCancels`.
    @Test func idleTeardownDuringCachedSystemReconnectCancels() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0.01)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        // White-box Tier-0-limbo setup: put ONLY the cached state into `.reconnecting(.system)` while
        // the live `CBPeripheral` stays `.disconnected` (never connected in this scenario).
        await manager.bluetooth.testSeedSystemReconnectState(for: handle.id)

        // A work lease creates demand, but `reevaluateLink` sees the cached `.reconnecting(.system)`
        // and lets it run without issuing a connect — so the live peripheral never becomes `.connecting`.
        let token = try await handle.acquireWorkLease()
        #expect(await manager.currentConnectionStates[handle.id]
                == .reconnecting(source: .system, attempt: nil, nextRetryAt: nil))

        // Confirm the live peripheral is genuinely non-connecting AND non-connected when idle fires, so
        // the cancel can only be explained by the cached path — not the `.connecting` arm of the
        // predicate. This cannot silently drift back onto the `.connecting` arm.
        let liveState = await manager.bluetooth.testCBPeripheralState(for: handle.id)
        #expect(liveState != .connecting,
                "Live peripheral must be non-connecting so only the cached path can drive the cancel")
        #expect(liveState != .connected)

        // Demand drops mid-Tier-0-limbo: idle teardown must settle AND issue exactly one cancel to stop
        // the OS's pending reconnect work, driven solely by the CACHED `.reconnecting(.system)` state.
        await handle.releaseWorkLease(token)
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .disconnected(reason: nil)
        })
        #expect(await manager.currentConnectionStates[handle.id] != .disconnecting)
        #expect(await manager.bluetooth.testCancelPeripheralConnectionCount(for: handle.id) == 1,
                "Idle teardown must issue exactly one cancel for a CACHED Tier-0 reconnect with a non-connecting live peripheral")
        #expect(await manager.bluetooth.testContainsIntentionalDisconnect(handle.id) == false,
                "Idle teardown of a non-connected cached Tier-0 limbo must not mark the disconnect intentional")
    }

    @Test func idleTeardownDuringLiveConnectingCancels() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0.01)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        // Acquire work issues a plain (work-driven, non-manual-hold) connect: the cached state becomes
        // `.connecting` while the live `CBPeripheral` also reports `.connecting`. Unlike the
        // system-reconnect tests, cached state is NOT `.reconnecting(.system)`, so only the live
        // `.connecting` arm of the teardown predicate can explain a cancel.
        let token = try await handle.acquireWorkLease()
        #expect(await manager.currentConnectionStates[handle.id] == .connecting)
        if case .reconnecting = await manager.currentConnectionStates[handle.id] {
            Issue.record("Cached state must be `.connecting` (not system reconnecting) so only the live arm drives the cancel")
        }
        // The mock hands out `.connecting` synchronously on `issueConnect`; it resolves to `.connected`
        // only after its ~45ms connection interval, which comfortably out-lasts our 10ms idle timer.
        #expect((await manager.bluetooth.testCBPeripheralState(for: handle.id)) == .connecting,
                "Scenario must leave the live peripheral `.connecting` so the live arm can drive the cancel")

        // Drop demand so idle teardown fires (10ms) before the pending connect resolves (~45ms).
        await handle.releaseWorkLease(token)
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .disconnected(reason: nil)
        })
        #expect(await manager.currentConnectionStates[handle.id] != .disconnecting)
        #expect(await manager.bluetooth.testCancelPeripheralConnectionCount(for: handle.id) == 1,
                "Idle teardown must issue exactly one cancel for a live `.connecting` peripheral")
        // The settle path never flags the disconnect intentional. If this assert fails, idle has drifted
        // onto the `.connected` branch (which DOES flag it) — meaning the live `.connecting` arm is not
        // actually the thing being pinned.
        #expect(await manager.bluetooth.testContainsIntentionalDisconnect(handle.id) == false)
    }

    @Test func zeroIdleIntervalTearsDownImmediately() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        let token = try await handle.acquireWorkLease()
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })

        // Interval 0 tears the link down as soon as demand hits zero (still asynchronously).
        await handle.releaseWorkLease(token)
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .disconnected(reason: nil)
        })
    }

    @Test func idleDoesNotFireWhenDemandReturnsBeforeExpiry() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0.5)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        let token = try await handle.acquireWorkLease()
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })

        // Release (idle armed), then re-acquire before expiry — the stale timer must not fire.
        await handle.releaseWorkLease(token)
        let token2 = try await handle.acquireWorkLease()

        // Wait past the original expiry; the generation guard keeps the link connected.
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(await manager.currentConnectionStates[handle.id] == .connected)

        await handle.releaseWorkLease(token2)
    }

    // Exploratory (#9): disconnect while the connect is still pending (.connecting).
    @Test func disconnectDuringConnectingSettlesCleanly() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0.1)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .connecting
        try await handle.disconnect()

        // The settling rule must not leave a stuck .disconnecting — settle to .disconnected(reason: nil).
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .disconnected(reason: nil)
        })
    }

    // MARK: - Reconnect Gating (#59), Radio-Drop Projection, and Durable Holds (step 6)

    @Test func tier1DoesNotArmWhenQuiet() async throws {
        // A `connect(autoReconnect: false)` hold yields `wantsReconnect == false` — an unexpected drop
        // must NOT arm the library ladder (#59).
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        var policy = ReconnectPolicy()
        policy.maxAttempts = 5
        policy.initialDelay = 0.01
        let manager = await Mock.makeManager(reconnectPolicy: policy)
        await Mock.ensureReady(manager)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect(autoReconnect: false)
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .connecting
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .connected

        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: false)
        let events = await drainConnectionStateChanges(from: changes, withinNanoseconds: 2_000_000_000)
        let hasLibrary = events.contains { if case .reconnecting(.library, _, _) = $0.state { return true }; return false }
        #expect(!hasLibrary)

        try? await handle.disconnect()
    }

    @Test func tier1ArmsWhileLeaseHeld() async throws {
        // A held work lease yields `wantsReconnect == true` — an unexpected drop arms the ladder (#59).
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        var policy = ReconnectPolicy()
        policy.maxAttempts = 5
        policy.initialDelay = 0.01
        let manager = await Mock.makeManager(reconnectPolicy: policy)
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        let token = try await handle.acquireWorkLease()
        #expect(await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .connected })

        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: false)

        #expect(await pollUntil(timeout: 3.0) {
            if case .reconnecting(.library, _, _) = await manager.currentConnectionStates[handle.id] { return true }
            return false
        })

        await handle.releaseWorkLease(token)
    }

    @Test func autoReconnectFalseHoldSuppressesBothTiers() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        var policy = ReconnectPolicy()
        policy.maxAttempts = 5
        let manager = await Mock.makeManager(reconnectPolicy: policy)
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0.1)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect(autoReconnect: false)
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .connecting
        _ = await firstConnectionStateChange(from: changes, withinNanoseconds: 5_000_000_000) // .connected

        // reconnectDesired false → no reconnect intent synced (no Tier-0 option / no Tier-1 intent).
        #expect(!(await manager.bluetooth.testIsReconnectEnabled(handle.id)))
        // The hold suppresses idle (quiet far past the interval).
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await manager.currentConnectionStates[handle.id] == .connected)
        // An unexpected drop still does not arm Tier-1.
        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: false)
        let events = await drainConnectionStateChanges(from: changes, withinNanoseconds: 2_000_000_000)
        let hasLibrary = events.contains { if case .reconnecting(.library, _, _) = $0.state { return true }; return false }
        #expect(!hasLibrary)

        try? await handle.disconnect()
    }

    @Test func demandSurvivesRadioCycleAndRelinks() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        let token = try await handle.acquireWorkLease()
        #expect(await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .connected })

        await Mock.simulatePowerOff()
        _ = await Mock.waitForState("Powered Off", on: manager)
        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)

        // Demand survived the radio cycle; the sweep re-links without re-acquiring.
        #expect(await manager.bluetooth.testWorkCount(for: handle.id) == 1)
        #expect(await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .connected })

        await handle.releaseWorkLease(token)
    }

    @Test func radioDropWithWantsReconnectShowsReconnecting() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let subscriberBaseline = await manager.bluetooth.testConnectionStateSubscriberCount()
        let changes = manager.connectionStateChanges
        #expect(await Mock.waitForConnectionSubscription(on: manager, above: subscriberBaseline))

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()
        _ = await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .connected }

        await Mock.simulatePowerOff()
        _ = await Mock.waitForState("Powered Off", on: manager)

        // The stream shows .disconnected(.bluetoothUnavailable) THEN .reconnecting(.library, nil, nil),
        // and the handle is not left nil.
        let events = await drainConnectionStateChanges(from: changes, withinNanoseconds: 2_000_000_000)
        let states = events.map { $0.state }
        let disconnectedIdx = states.firstIndex(of: .disconnected(reason: .bluetoothUnavailable))
        let reconnectingIdx = states.firstIndex { if case .reconnecting(.library, nil, nil) = $0 { return true }; return false }
        if let disconnectedIdx, let reconnectingIdx {
            #expect(reconnectingIdx > disconnectedIdx)
        } else {
            Issue.record("expected .disconnected then .reconnecting(.library, nil, nil)")
        }
        #expect(handle.connectionState != nil)

        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)
        try? await handle.disconnect()
    }

    // INVARIANT COVERAGE (not a regression test): a reconnect ladder step must not issue a connect
    // against a dead radio. This is an end-to-end behavioral check, but it does NOT pin the gate —
    // the synchronous flip on `simulatePowerOff` races the deferred delegate invalidation, which can
    // cancel the ladder before a sleeping step ever wakes, so `performReconnect`'s radio gate is not
    // strictly what prevents the connect here. The gate itself is pinned deterministically by
    // `reconnectLadderStepRefusesToIssueWhenRadioIsOff` (see that test).
    @Test func reconnectLadderDoesNotIssueAgainstDeadRadio() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        var policy = ReconnectPolicy()
        policy.maxAttempts = 5
        policy.initialDelay = 0.1
        policy.jitter = 0.0
        let manager = await Mock.makeManager(reconnectPolicy: policy)
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0.1)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        let token = try await handle.acquireWorkLease()
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })

        // Unexpected drop arms the Tier-1 ladder.
        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: false)
        #expect(await pollUntil(timeout: 3.0) {
            if case .reconnecting(.library, _, _) = await manager.currentConnectionStates[handle.id] {
                return true
            }
            return false
        })

        // Flip the radio off while the ladder is sleeping. The ladder's performReconnect reads
        // centralManager.state synchronously (now .poweredOff) and must refuse to issue a connect.
        await Mock.simulatePowerOff()
        _ = await Mock.waitForState("Powered Off", on: manager)

        // Allow any racing ladder step to run; then assert no `.connecting` was issued on the dead radio.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await manager.currentConnectionStates[handle.id] != .connecting)

        // Flush the events already observed (buffer includes the .connecting/.connected from lease
        // acquisition), then assert no additional `.connecting` was issued after the radio died.
        _ = await drainConnectionStateChanges(from: changes, withinNanoseconds: 400_000_000)
        let events = await drainConnectionStateChanges(from: changes, withinNanoseconds: 2_000_000_000)
        let issuedConnecting = events.contains { $0.state == .connecting }
        #expect(!issuedConnecting, "Ladder must not issue a connect against a dead radio")

        // Cleanup: restore the radio and tear down the lease.
        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)
        await handle.releaseWorkLease(token)
    }

    // WHITE-BOX regression test for the reconnect ladder's dead-radio gate. The end-to-end test
    // (`reconnectLadderDoesNotIssueAgainstDeadRadio`) cannot pin this gate because the delegate-driven
    // invalidation cancels a sleeping ladder before its step wakes — so we drive one ladder step
    // deterministically via the test-only `testInvokeLadderStep` hook while the radio is off, and
    // assert the gate refuses to issue a connect and instead surfaces `.failed(.bluetoothPoweredOff)`.
    // If the `.poweredOff` gate in `performReconnect` is removed, this fails.
    @Test func reconnectLadderStepRefusesToIssueWhenRadioIsOff() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        var policy = ReconnectPolicy()
        policy.maxAttempts = 5
        policy.initialDelay = 0.1
        policy.jitter = 0.0
        let manager = await Mock.makeManager(reconnectPolicy: policy)
        await Mock.ensureReady(manager)
        await manager.bluetooth.setIdleDisconnectInterval(0.1)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        let token = try await handle.acquireWorkLease()
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .connected
        })

        // Unexpected drop arms the Tier-1 ladder.
        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: false)
        #expect(await pollUntil(timeout: 3.0) {
            if case .reconnecting(.library, _, _) = await manager.currentConnectionStates[handle.id] {
                return true
            }
            return false
        })

        // Flip the radio off and let the delegate-driven invalidation settle deterministically, so the
        // ladder bookkeeping is stationary before we drive the step ourselves.
        await Mock.simulatePowerOff()
        _ = await Mock.waitForState("Powered Off", on: manager)

        // Drive one ladder step on a dead radio. The gate must refuse to issue a connect.
        await manager.bluetooth.testInvokeLadderStep(for: handle.id)

        // The gate deterministically settles the ladder to a terminal `.failed(.bluetoothPoweredOff)`
        // (via `failLadderRadio`) on this actor turn. If the `.poweredOff` gate were removed,
        // `performReconnect` would fall through and `issueConnect` would instead publish `.connecting`
        // — so the `.connecting` absence is the load-bearing regression check. Read the actor's
        // authoritative state rather than racing a time-bounded stream drain.
        let settledToPoweredOff = await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .failed(reason: .bluetoothPoweredOff)
        }
        #expect(settledToPoweredOff, "Ladder step on a dead radio must fail via .bluetoothPoweredOff, not connect")
        #expect(await manager.currentConnectionStates[handle.id] != .connecting,
                "Ladder step must not issue a connect against a dead radio")

        // Cleanup: restore the radio and tear down the lease.
        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)
        await handle.releaseWorkLease(token)
    }

    // Priority A (D-1 event 9 middle branch): a disconnect reporting `isReconnecting == true` while
    // `wantsReconnect(id)` is false must NOT trust Tier-0. The library publishes `.disconnected(reason: nil)`
    // immediately, suppresses the OS's pending reconnect by cancelling fire-and-forget, and does NOT insert
    // into `intentionalDisconnects`. The setup uses a manual hold with `autoReconnect: false` — the only
    // deterministic way to hold `.connected` while `wantsReconnect` is false without racing an idle timer.
    @Test func untrustedTier0ReconnectIsSuppressedWhenNothingWantsIt() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect(autoReconnect: false)
        #expect(await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .connected })
        // No live work and the hold is reconnectDesired:false, so NOTHING wants a link back.
        #expect(await manager.bluetooth.testWorkCount(for: handle.id) == 0)
        #expect(!(await manager.bluetooth.testIsReconnectEnabled(handle.id)))

        // A Tier-0 reconnect event lands while nothing wants the link back.
        await manager.bluetooth.testInjectDisconnect(for: handle.id, isReconnecting: true)

        // Untrusted Tier-0: publish `.disconnected(reason: nil)`, never `.reconnecting(.system)`.
        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .disconnected(reason: nil)
        })
        if case .reconnecting = await manager.currentConnectionStates[handle.id] {
            Issue.record("Must not publish any .reconnecting for an untrusted Tier-0 event")
        }
        // And the connection-state stream carries no `.reconnecting(.system)` either.
        let later = await drainConnectionStateChanges(from: changes, withinNanoseconds: 800_000_000)
        let sysReconnect = later.contains { if case .reconnecting(.system, _, _) = $0.state { return true }; return false }
        #expect(!sysReconnect, "Untrusted Tier-0 must not publish .reconnecting(.system)")
        #expect(later.contains { $0.state == .disconnected(reason: nil) })

        // Exactly one fire-and-forget suppression cancel; never marked intentional.
        #expect(await manager.bluetooth.testCancelPeripheralConnectionCount(for: handle.id) == 1,
                "Untrusted Tier-0 must issue exactly one suppression cancel")
        #expect(await manager.bluetooth.testContainsIntentionalDisconnect(handle.id) == false,
                "Untrusted Tier-0 suppression must not mark the disconnect intentional")

        try? await handle.disconnect()
    }

    // Ladder gate: a step on a shut-down / no-central stack must fail to `.bluetoothUnavailable` rather
    // than issue against a torn-down stack (the `guard !isShutdown, let centralManager` in `performReconnect`).
    @Test func reconnectLadderStepAfterShutdownFailsUnavailable() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        await manager.bluetooth.shutdown()
        await manager.bluetooth.testInvokeLadderStep(for: handle.id)

        // The ladder must settle to a terminal `.failed(.bluetoothUnavailable)`, never issue a connect.
        #expect(await manager.currentConnectionStates[handle.id] == .failed(reason: .bluetoothUnavailable))
        #expect(await manager.currentConnectionStates[handle.id] != .connecting)
    }

    /// White-box ladder radio-gate coverage shared by `.unsupported` / `.unauthorized`.
    /// Drives one ladder step via ``BluetoothActor/testInvokeLadderStep(for:)`` against a given radio
    /// state and asserts the step neither issues a connect nor publishes `.connecting`.
    @MainActor private func assertLadderRadioGate(
        mockState: CBMManagerState,
        stateDescription: String,
        expected: PeripheralError
    ) async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        await Mock.simulateInitialState(mockState)
        _ = await Mock.waitForState(stateDescription, on: manager)

        await manager.bluetooth.testInvokeLadderStep(for: handle.id)

        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[handle.id] == .failed(reason: expected)
        }, "Ladder step on \(stateDescription) must fail via \(expected), not connect")
        #expect(await manager.currentConnectionStates[handle.id] != .connecting)

        // Restore the baseline so the next test starts from a known-good radio.
        await Mock.simulateInitialState(.poweredOn)
        _ = await Mock.waitForState("Ready", on: manager)
    }

    @Test func reconnectLadderStepRefusesToIssueWhenUnsupported() async throws {
        try await assertLadderRadioGate(mockState: .unsupported, stateDescription: "Unsupported", expected: .bluetoothUnsupported)
    }

    @Test func reconnectLadderStepRefusesToIssueWhenUnauthorized() async throws {
        try await assertLadderRadioGate(mockState: .unauthorized, stateDescription: "Unauthorized", expected: .bluetoothUnavailable)
    }

    // Ladder gate: a transient `.unknown` radio is not a failure — the step returns in place, leaving the
    // cached `.reconnecting(.library)` state intact for the radio-return sweep to re-drive later.
    @Test func reconnectLadderStepDefersWhileRadioTransient() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        await manager.bluetooth.testInvokeLadderStep(for: handle.id)

        // The step defers (no failure, no connect): the ladder stays `.reconnecting(.library)`.
        let state = await manager.currentConnectionStates[handle.id]
        let isLibrary = { if case .reconnecting(.library, _, _) = state { return true }; return false }()
        #expect(isLibrary, "Ladder step on a transient radio must defer, leaving .reconnecting(.library)")
        #expect(await manager.currentConnectionStates[handle.id] != .connecting)

        await Mock.simulateInitialState(.poweredOn)
        _ = await Mock.waitForState("Ready", on: manager)
    }

    // reevaluateLink transient-radio arm (D-radio): a work-lease acquisition that calls reevaluateLink
    // directly (no radio wait) while the radio is `.unknown` must defer — return a token without issuing
    // a connect — rather than throw or connect against a transient radio.
    @Test func acquireWorkLeaseDefersWhileRadioTransient() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        // The actor's acquireWorkLease calls reevaluateLink directly; on a transient radio it must
        // return a token (deferring the connect), not throw and not publish `.connecting`.
        let token = try await manager.bluetooth.acquireWorkLease(id: handle.id)
        #expect(await manager.currentConnectionStates[handle.id] != .connecting)
        #expect(await manager.bluetooth.testWorkCount(for: handle.id) == 1)

        await manager.bluetooth.releaseWorkLease(token)

        await Mock.simulateInitialState(.poweredOn)
        _ = await Mock.waitForState("Ready", on: manager)
    }

    // Ladder gate: a `.reconnecting(.library)` step for an id with no live `CBPeripheral` must fail to
    // `.notFound` (D-never — no scan, demand retained) rather than issue a connect.
    @Test func reconnectLadderStepWithMissingPeripheralFailsNotFound() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        // A ghost id never discovered has no live `CBPeripheral` while the radio is powered on.
        let ghostId = Mock.connectionTestPeripheralID + ".ghost"
        await manager.bluetooth.testInvokeLadderStep(for: ghostId)

        #expect(await pollUntil(timeout: 3.0) {
            await manager.currentConnectionStates[ghostId] == .failed(reason: .notFound)
        }, "Ladder step with no live peripheral must fail via .notFound")
        #expect(await manager.currentConnectionStates[ghostId] != .connecting)
    }

    // Radio regression surfaced through `connect()`: with the radio `.unsupported`, the connect waits for
    // a usable radio and fails fast with `.bluetoothUnsupported` rather than hanging or no-op'ing (D-radio).
    @Test func connectFailsWhenUnsupported() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)
        let handle = manager.peripheral(id: Mock.connectionTestPeripheralID)

        await Mock.simulateInitialState(.unsupported)
        _ = await Mock.waitForState("Unsupported", on: manager)

        await #expect(throws: PeripheralError.bluetoothUnsupported) {
            try await handle.connect()
        }

        await Mock.simulateInitialState(.poweredOn)
        _ = await Mock.waitForState("Ready", on: manager)
        try? await handle.disconnect()
    }

    // Radio regression surfaced through `connect()`: `.unauthorized` fails fast with `.bluetoothUnavailable`.
    @Test func connectFailsWhenUnauthorized() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)
        let handle = manager.peripheral(id: Mock.connectionTestPeripheralID)

        await Mock.simulateInitialState(.unauthorized)
        _ = await Mock.waitForState("Unauthorized", on: manager)

        await #expect(throws: PeripheralError.bluetoothUnavailable) {
            try await handle.connect()
        }

        await Mock.simulateInitialState(.poweredOn)
        _ = await Mock.waitForState("Ready", on: manager)
        try? await handle.disconnect()
    }

    // A `.unknown`-parked connect waiter that resolves to `.unsupported` must fail with `.bluetoothUnsupported`
    // (resolvePoweredOnWaiters fails terminal-state waiters — the transient-vs-terminal analogue of the
    // existing `connectTransientResolvingToPoweredOffThrows`).
    @Test func connectTransientResolvingToUnsupportedThrows() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let connectTask = Task { try await handle.connect() }
        _ = await pollUntil(timeout: 2.0) {
            await manager.bluetooth.testPendingPoweredOnWaiterCount() == 1
        }

        await Mock.simulateInitialState(.unsupported)
        await #expect(throws: PeripheralError.bluetoothUnsupported) {
            try await connectTask.value
        }

        #expect(await manager.bluetooth.testPendingPoweredOnWaiterCount() == 0)

        await Mock.simulateInitialState(.poweredOn)
        _ = await Mock.waitForState("Ready", on: manager)
    }

    // A `.unknown`-parked connect waiter that resolves to `.unauthorized` must fail with `.bluetoothUnavailable`.
    @Test func connectTransientResolvingToUnauthorizedThrows() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let connectTask = Task { try await handle.connect() }
        _ = await pollUntil(timeout: 2.0) {
            await manager.bluetooth.testPendingPoweredOnWaiterCount() == 1
        }

        await Mock.simulateInitialState(.unauthorized)
        await #expect(throws: PeripheralError.bluetoothUnavailable) {
            try await connectTask.value
        }

        #expect(await manager.bluetooth.testPendingPoweredOnWaiterCount() == 0)

        await Mock.simulateInitialState(.poweredOn)
        _ = await Mock.waitForState("Ready", on: manager)
    }

    // Cancelling a `connect()` parked on a transient radio fires the handle's `onCancel`, which cancels
    // the parked powered-on continuation (the `Peripheral.connect` cancellation/orphan path).
    @Test func connectCancellationWhileParkedOnTransientRadio() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let connectTask = Task { try await handle.connect() }
        _ = await pollUntil(timeout: 2.0) {
            await manager.bluetooth.testPendingPoweredOnWaiterCount() == 1
        }

        connectTask.cancel()
        do {
            try await withTimeout(nanoseconds: 4_000_000_000) { _ = try await connectTask.value }
            Issue.record("connect() must throw CancellationError when cancelled while parked")
        } catch is CancellationError {
            // expected
        } catch {
            throw error
        }

        #expect(await manager.bluetooth.testPendingPoweredOnWaiterCount() == 0)

        await Mock.simulateInitialState(.poweredOn)
        _ = await Mock.waitForState("Ready", on: manager)
    }

    // Cancelling an `acquireWorkLease()` parked on a transient radio fires the handle's `onCancel`, which
    // cancels the parked powered-on continuation (the `Peripheral.acquireWorkLease` cancellation/orphan path).
    @Test func acquireWorkLeaseCancellationWhileParkedOnTransientRadio() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(
            id: Mock.connectionTestPeripheralID,
            on: manager,
            withinNanoseconds: 3_000_000_000
        )
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let leaseTask = Task { try await handle.acquireWorkLease() }
        _ = await pollUntil(timeout: 2.0) {
            await manager.bluetooth.testPendingPoweredOnWaiterCount() == 1
        }

        leaseTask.cancel()
        do {
            try await withTimeout(nanoseconds: 4_000_000_000) { _ = try await leaseTask.value }
            Issue.record("acquireWorkLease() must throw CancellationError when cancelled while parked")
        } catch is CancellationError {
            // expected
        } catch {
            throw error
        }

        #expect(await manager.bluetooth.testPendingPoweredOnWaiterCount() == 0)

        await Mock.simulateInitialState(.poweredOn)
        _ = await Mock.waitForState("Ready", on: manager)
    }

    // shutdown() must fail a parked scan waiter with `.bluetoothUnavailable` (its `scanWaiter` resume
    // path), so a scan parked on a transient radio does not hang forever if the stack is torn down.
    @Test func shutdownFailsParkedScanWaiter() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await Mock.simulateInitialState(.unknown)
        _ = await Mock.waitForState("Unknown", on: manager)

        let scanTask = Task { try await manager.startScanning() }
        _ = await pollUntil(timeout: 2.0) { await manager.bluetooth.testPendingScanWaiterCount() == 1 }

        await manager.bluetooth.shutdown()

        await #expect(throws: PeripheralError.bluetoothUnavailable) {
            try await scanTask.value
        }
        #expect(await manager.bluetooth.testPendingScanWaiterCount() == 0)

        await Mock.simulateInitialState(.poweredOn)
    }

    // startScanning() with an `.unauthorized` radio fails fast with `.bluetoothUnavailable` (D-radio).
    @Test func startScanningFailsWhenUnauthorized() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await Mock.simulateInitialState(.unauthorized)
        _ = await Mock.waitForState("Unauthorized", on: manager)

        await #expect(throws: PeripheralError.bluetoothUnavailable) {
            try await manager.startScanning()
        }
        #expect(await manager.bluetooth.testIsScanning() == false)

        await Mock.simulateInitialState(.poweredOn)
        _ = await Mock.waitForState("Ready", on: manager)
    }

    // startScanning() with a torn-down stack fails fast with `.bluetoothUnavailable` (the
    // `guard !isShutdown` in `startScanning`), so a scan cannot outlive its manager.
    @Test func startScanningAfterShutdownThrows() async throws {
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        await manager.bluetooth.shutdown()

        await #expect(throws: PeripheralError.bluetoothUnavailable) {
            try await manager.startScanning()
        }

        await Mock.simulateInitialState(.poweredOn)
    }

    @Test func radioDropWithoutWantsReconnectShowsNoReconnecting() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let changes = manager.connectionStateChanges

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect(autoReconnect: false)
        _ = await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .connected }

        await Mock.simulatePowerOff()
        _ = await Mock.waitForState("Powered Off", on: manager)

        let events = await drainConnectionStateChanges(from: changes, withinNanoseconds: 2_000_000_000)
        let hasLibrary = events.contains { if case .reconnecting(.library, _, _) = $0.state { return true }; return false }
        #expect(!hasLibrary)
        #expect(events.contains { $0.state == .disconnected(reason: .bluetoothUnavailable) })

        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)
        try? await handle.disconnect()
    }

    @Test func noReconnectHoldIsNotResurrectedByRadioCycle() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect(autoReconnect: false)
        _ = await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .connected }

        await Mock.simulatePowerOff()
        _ = await Mock.waitForState("Powered Off", on: manager)
        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)

        // wantsReconnect false → reason .radioReturned does not satisfy the issue gate.
        #expect(await manager.currentConnectionStates[handle.id] != .connected)
        #expect(!(await manager.bluetooth.testIsReconnectEnabled(handle.id)))
        try? await handle.disconnect()
    }

    @Test func strandedLeaseSurfacesFailure() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        let token = try await handle.acquireWorkLease()
        #expect(await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .connected })

        // Invalidate (clears live refs, retains demand), then make the device non-retrievable, then
        // drive the radio-return sweep: the strand surfaces as .failed(.notFound).
        await manager.bluetooth.testInvalidatePeripherals()
        await manager.bluetooth.testClearDiscoveredPeripherals()
        await manager.bluetooth.testSimulateRadioReturn()

        #expect(await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .failed(reason: .notFound) })
        // Demand is retained — no scan, no retry loop. The lease is still held.
        #expect(await manager.bluetooth.testWorkCount(for: handle.id) == 1)

        await handle.releaseWorkLease(token)
    }

    @Test func discoveryRelinksDemandedPeripheral() async throws {
        // D-1 event 15 (polish): an id stranded at .failed(.notFound) with demand relinks when an
        // app-driven scan rediscovers it.
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        let token = try await handle.acquireWorkLease()
        #expect(await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .connected })

        await manager.bluetooth.testInvalidatePeripherals()
        await manager.bluetooth.testClearDiscoveredPeripherals()
        await manager.bluetooth.testSimulateRadioReturn()
        #expect(await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .failed(reason: .notFound) })

        // Force the (still virtually-connected) spec to advertise again so an app-driven scan can
        // rediscover it — event 15 then relinks the demanded, stranded id.
        await Mock.simulateDisconnection()
        try await manager.startScanning()
        let rediscovered = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager, withinNanoseconds: 3_000_000_000)
        #expect(rediscovered != nil)
        await manager.stopScanning()

        #expect(await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .connected })

        await handle.releaseWorkLease(token)
    }

    @Test func shutdownLeavesPersistedHoldsIntact() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let restoreId = "com.five3apps.relia-ble.tests.shutdown-holds"
        let manager = await Mock.makeManager(restoreIdentifier: restoreId)
        await Mock.ensureReady(manager)
        await manager.bluetooth.testClearPersistedReconnectIntent()

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()
        _ = await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .connected }
        #expect(await manager.bluetooth.testPersistedManualConnectHolds()[handle.id] == true)

        // Shutdown must NOT write an empty flush.
        await Mock.tearDown(manager)
        #expect(await manager.bluetooth.testPersistedManualConnectHolds()[handle.id] == true)
        await manager.bluetooth.testClearPersistedReconnectIntent()
    }

    @Test func invalidateDoesNotWipePersistedHolds() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()) }

        let restoreId = "com.five3apps.relia-ble.tests.invalidate-holds"
        let manager = await Mock.makeManager(restoreIdentifier: restoreId)
        await Mock.ensureReady(manager)
        await manager.bluetooth.testClearPersistedReconnectIntent()

        try await manager.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager.stopScanning()

        try await handle.connect()
        _ = await pollUntil(timeout: 3.0) { await manager.currentConnectionStates[handle.id] == .connected }
        #expect(await manager.bluetooth.testPersistedManualConnectHolds()[handle.id] == true)

        await manager.bluetooth.testInvalidatePeripherals()

        #expect(await manager.bluetooth.testPersistedManualConnectHolds()[handle.id] == true)
        await manager.bluetooth.testClearPersistedReconnectIntent()
        await Mock.tearDown(manager)
    }

    @Test func deferredRestoredScanSurvivesPowerCycle() async throws {
        // D-1 event 13: invalidate preserves the deferred restored scan.
        let manager = await Mock.makeManager()
        await Mock.ensureReady(manager)

        let scanUUID = CBUUID(string: "180D")
        await Mock.simulatePowerOff()
        _ = await Mock.waitForState("Powered Off", on: manager)
        await manager.bluetooth.testHandleWillRestoreState(scanServices: [scanUUID])
        #expect(await manager.bluetooth.testPendingRestoredScanServices() == [scanUUID])

        // A power-cycle invalidate must not drop the deferred scan.
        await manager.bluetooth.testInvalidatePeripherals()
        #expect(await manager.bluetooth.testPendingRestoredScanServices() == [scanUUID])

        await Mock.simulatePowerOn()
        _ = await Mock.waitForState("Ready", on: manager)
        let resumed = await pollUntil(timeout: 3.0) { await manager.bluetooth.testPendingRestoredScanServices() == nil }
        #expect(resumed)
        await manager.stopScanning()
    }

    @Test @MainActor func restoredLinkWithoutHoldIdlesOut() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()); Mock.clearStateRestoration() }

        let restoreId = "com.five3apps.relia-ble.tests.restore-idle-out"
        let manager1 = await Mock.makeManager(restoreIdentifier: restoreId)
        await Mock.ensureReady(manager1)
        await manager1.bluetooth.testClearPersistedReconnectIntent()

        try await manager1.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager1, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager1.stopScanning()
        try await handle.connect()
        _ = await pollUntil(timeout: 3.0) { await manager1.currentConnectionStates[handle.id] == .connected }

        // Wipe the hold so the restored link has no explicit ask.
        await manager1.bluetooth.testClearPersistedReconnectIntent()
        await Mock.tearDown(manager1, resetMockConnections: false)
        Mock.connectionTestSpec.simulateConnection()
        Mock.installStateRestoration(restoreIdentifier: restoreId, peripherals: [Mock.connectionTestSpec], scanServices: nil)

        let manager2 = try await Mock.makeRestoredManager(restoreIdentifier: restoreId, idleDisconnectInterval: 0.3)
        #expect(await pollUntil(timeout: 3.0) {
            await manager2.currentConnectionStates[Mock.connectionTestPeripheralID] == .connected
        })
        // No rehydrated hold → the restored link idles out (D-restore case 2).
        #expect(await pollUntil(timeout: 3.0) {
            await manager2.currentConnectionStates[Mock.connectionTestPeripheralID] == .disconnected(reason: nil)
        })

        await manager2.bluetooth.testClearPersistedReconnectIntent()
        await Mock.tearDown(manager2)
    }

    @Test @MainActor func restoredManualHoldSurvivesRelaunch() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()); Mock.clearStateRestoration() }

        let restoreId = "com.five3apps.relia-ble.tests.restore-manual-hold"
        let manager1 = await Mock.makeManager(restoreIdentifier: restoreId)
        await Mock.ensureReady(manager1)
        await manager1.bluetooth.testClearPersistedReconnectIntent()

        try await manager1.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager1, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager1.stopScanning()
        try await handle.connect()
        _ = await pollUntil(timeout: 3.0) { await manager1.currentConnectionStates[handle.id] == .connected }
        #expect(await manager1.bluetooth.testPersistedManualConnectHolds()[handle.id] == true)

        await Mock.tearDown(manager1, resetMockConnections: false)
        Mock.connectionTestSpec.simulateConnection()
        Mock.installStateRestoration(restoreIdentifier: restoreId, peripherals: [Mock.connectionTestSpec], scanServices: nil)

        // Short idle interval: a rehydrated hold must suppress idle, so the link stays up.
        let manager2 = try await Mock.makeRestoredManager(restoreIdentifier: restoreId, idleDisconnectInterval: 0.2)
        #expect(await pollUntil(timeout: 3.0) {
            await manager2.currentConnectionStates[Mock.connectionTestPeripheralID] == .connected
        })
        #expect(await manager2.bluetooth.testHasManualConnectHold(for: Mock.connectionTestPeripheralID))
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(await manager2.currentConnectionStates[Mock.connectionTestPeripheralID] == .connected)

        await manager2.bluetooth.testClearPersistedReconnectIntent()
        await Mock.tearDown(manager2)
    }

    @Test @MainActor func restoredHoldWithAutoReconnectFalseSuppressesIdleButNotTier1() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()); Mock.clearStateRestoration() }

        let restoreId = "com.five3apps.relia-ble.tests.restore-hold-false"
        let manager1 = await Mock.makeManager(restoreIdentifier: restoreId)
        await Mock.ensureReady(manager1)
        await manager1.bluetooth.testClearPersistedReconnectIntent()

        try await manager1.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager1, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager1.stopScanning()
        try await handle.connect(autoReconnect: false)
        _ = await pollUntil(timeout: 3.0) { await manager1.currentConnectionStates[handle.id] == .connected }
        #expect(await manager1.bluetooth.testPersistedManualConnectHolds()[handle.id] == false)

        await Mock.tearDown(manager1, resetMockConnections: false)
        Mock.connectionTestSpec.simulateConnection()
        Mock.installStateRestoration(restoreIdentifier: restoreId, peripherals: [Mock.connectionTestSpec], scanServices: nil)

        // Case 4: reconnectDesired:false rehydrates — idle suppressed (no teardown) but nothing armed.
        let manager2 = try await Mock.makeRestoredManager(restoreIdentifier: restoreId, idleDisconnectInterval: 0.2)
        #expect(await pollUntil(timeout: 3.0) {
            await manager2.currentConnectionStates[Mock.connectionTestPeripheralID] == .connected
        })
        #expect(!(await manager2.bluetooth.testIsReconnectEnabled(Mock.connectionTestPeripheralID)))
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(await manager2.currentConnectionStates[Mock.connectionTestPeripheralID] == .connected)

        await manager2.bluetooth.testClearPersistedReconnectIntent()
        await Mock.tearDown(manager2)
    }

    @Test @MainActor func workLeasesDoNotSurviveRelaunch() async throws {
        Mock.connectionTestDelegate.connectionResult = .success(())
        defer { Mock.connectionTestDelegate.connectionResult = .success(()); Mock.clearStateRestoration() }

        let restoreId = "com.five3apps.relia-ble.tests.work-not-restored"
        let manager1 = await Mock.makeManager(restoreIdentifier: restoreId)
        await Mock.ensureReady(manager1)
        await manager1.bluetooth.testClearPersistedReconnectIntent()

        try await manager1.startScanning()
        let snap = await Mock.waitForDiscovered(id: Mock.connectionTestPeripheralID, on: manager1, withinNanoseconds: 3_000_000_000)
        let handle = try #require(snap).peripheral
        await manager1.stopScanning()
        let token = try await handle.acquireWorkLease()
        _ = await pollUntil(timeout: 3.0) { await manager1.currentConnectionStates[handle.id] == .connected }
        // Work leases are never persisted.
        #expect(await manager1.bluetooth.testPersistedManualConnectHolds().isEmpty)

        await Mock.tearDown(manager1, resetMockConnections: false)
        Mock.connectionTestSpec.simulateConnection()
        Mock.installStateRestoration(restoreIdentifier: restoreId, peripherals: [Mock.connectionTestSpec], scanServices: nil)

        // Case 3: leases are never rehydrated — the restored residual link has no demand and idles out.
        let manager2 = try await Mock.makeRestoredManager(restoreIdentifier: restoreId, idleDisconnectInterval: 0.3)
        #expect(await pollUntil(timeout: 3.0) {
            await manager2.currentConnectionStates[Mock.connectionTestPeripheralID] == .connected
        })
        #expect(!(await manager2.bluetooth.testHasManualConnectHold(for: Mock.connectionTestPeripheralID)))
        #expect(!(await manager2.bluetooth.testIsReconnectEnabled(Mock.connectionTestPeripheralID)))
        #expect(await pollUntil(timeout: 3.0) {
            await manager2.currentConnectionStates[Mock.connectionTestPeripheralID] == .disconnected(reason: nil)
        })

        _ = token
        await manager2.bluetooth.testClearPersistedReconnectIntent()
        await Mock.tearDown(manager2)
    }
}

// MARK: - Logging Test Support

/// A configurable ``CBMPeripheralSpecDelegate`` used by the connection-lifecycle tests.
///
/// The connection result returned from ``peripheralDidReceiveConnectionRequest(_:)`` is set on the
/// instance before a test runs. The delegate is registered once in ``SimulationConfig/ensureConfigured()``
/// and shared across all connection tests via ``Mock/connectionTestDelegate``.
final class ConnectionTestDelegate: @unchecked Sendable {

    /// The connection outcome the mock's main-thread delegate callback returns for an incoming
    /// connection request.
    ///
    /// Written from async test bodies (setting `.failure(...)` before a test and resetting to
    /// `.success(())` in `defer` blocks) while read on the main thread by the mock's timer-driven
    /// `peripheralDidReceiveConnectionRequest` callback. Access is guarded by `lock` so the two
    /// threads never race on the underlying stored value.
    var connectionResult: Result<Void, Error> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedConnectionResult
        }
        set {
            lock.lock()
            storedConnectionResult = newValue
            lock.unlock()
        }
    }

    private let lock = NSLock()
    private var storedConnectionResult: Result<Void, Error> = .success(())
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

/// Helpers for driving the Nordic `CBMCentralManagerMock` simulation against a per-manager
/// ``BluetoothActor`` stack.
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

    /// Active stack tracked for serialized-suite teardown. Cleared by ``tearDown(_:)``.
    nonisolated(unsafe) private static var activeManager: ReliaBLEManager?

    /// Deterministically tears down a manager stack via ``BluetoothActor/shutdown()`` (volatile
    /// state only — persisted reconnect intent is preserved).
    ///
    /// - Parameter resetMockConnections: When `true` (default), disconnects mock peripherals so
    ///   they advertise again for the next test. Pass `false` for cold-relaunch so
    ///   `CBMPeripheralSpec.virtualConnections` stays set and `simulateStateRestoration` can
    ///   restore peripherals as `.connected`.
    /// Drops the suite's strong reference to the active stack **without** shutting it down.
    ///
    /// ``makeManager(loggingEnabled:reconnectPolicy:restoreIdentifier:tearDownPrevious:)`` parks every manager it
    /// creates in ``activeManager`` for serialized-suite teardown. That reference is a harness artifact, and it is
    /// enough on its own to keep a manager alive — which would defeat any test that needs one to actually
    /// deallocate. Call this to hand sole ownership back to the caller.
    static func releaseActiveManager() {
        activeManager = nil
    }

    @MainActor static func tearDown(_ manager: ReliaBLEManager, resetMockConnections: Bool = true) async {
        if resetMockConnections {
            connectionTestSpec.simulateDisconnection()
        }
        await manager.bluetooth.shutdown()
        if activeManager === manager {
            activeManager = nil
        }
    }

    /// Installs a process-global `simulateStateRestoration` fixture built only from
    /// ``CBMPeripheralSpec``s and scan-service UUIDs (no live `CBPeripheral` / actor state).
    ///
    /// **Always** pair with `defer { Mock.clearStateRestoration() }`.
    @MainActor static func installStateRestoration(
        restoreIdentifier: String,
        peripherals: [CBMPeripheralSpec] = [],
        scanServices: [CBMUUID]? = nil
    ) {
        CBMCentralManagerMock.simulateStateRestoration = { id in
            guard id == restoreIdentifier else { return nil }
            var dict: [String: Any] = [:]
            if !peripherals.isEmpty {
                dict[CBMCentralManagerRestoredStatePeripheralsKey] = peripherals
            }
            if let scanServices {
                dict[CBMCentralManagerRestoredStateScanServicesKey] = scanServices
            }
            return dict
        }
    }

    @MainActor static func clearStateRestoration() {
        CBMCentralManagerMock.simulateStateRestoration = nil
    }

    // MARK: - Main-Actor Simulation Wrappers
    //
    // CoreBluetoothMock's simulation API is not thread-safe and must be driven from the main
    // thread, where its advertisement `NSTimer` fires. Routing every `simulate*` call through these
    // `@MainActor` wrappers serializes the test-driven mutations (made from async test bodies on a
    // background concurrency executor) against the mock's own main-thread timers, eliminating the
    // SIGSEGV-causing data race on the mock's global mutable state. Tests call these with `await`.

    @MainActor static func simulateAuthorization(_ authorization: CBMManagerAuthorization) {
        CBMCentralManagerMock.simulateAuthorization(authorization)
    }

    @MainActor static func simulateInitialState(_ state: CBMManagerState) {
        CBMCentralManagerMock.simulateInitialState(state)
    }

    @MainActor static func simulatePeripherals(_ peripherals: [CBMPeripheralSpec]) {
        CBMCentralManagerMock.simulatePeripherals(peripherals)
    }

    @MainActor static func simulatePowerOn() {
        CBMCentralManagerMock.simulatePowerOn()
    }

    @MainActor static func simulatePowerOff() {
        CBMCentralManagerMock.simulatePowerOff()
    }

    @MainActor static func simulateConnection() {
        connectionTestSpec.simulateConnection()
    }

    @MainActor static func simulateDisconnection() {
        connectionTestSpec.simulateDisconnection()
    }

    /// Builds manager 2 for a cold relaunch: restores under `restoreIdentifier` when the central
    /// is created. Caller must have already torn down stack 1 (typically with
    /// `resetMockConnections: false`) and installed the restoration fixture.
    ///
    /// Leaves authorization undetermined until after stream subscribers are registered, then
    /// authorizes so `willRestoreState` fires during central init. Poll for settled actor state
    /// after return — restore side effects are applied asynchronously relative to authorize.
    @MainActor static func makeRestoredManager(
        restoreIdentifier: String,
        loggingEnabled: Bool = false,
        reconnectPolicy: ReconnectPolicy? = nil,
        idleDisconnectInterval: TimeInterval? = nil
    ) async throws -> ReliaBLEManager {
        CBMCentralManagerMock.simulateAuthorization(.notDetermined)
        let manager = await makeManager(
            loggingEnabled: loggingEnabled,
            reconnectPolicy: reconnectPolicy,
            restoreIdentifier: restoreIdentifier,
            idleDisconnectInterval: idleDisconnectInterval,
            tearDownPrevious: true
        )
        CBMCentralManagerMock.simulateAuthorization(.allowedAlways)
        CBMCentralManagerMock.simulatePowerOn()
        try await manager.authorizeBluetooth()
        _ = await pollUntil(timeout: 3.0) {
            let powered = await manager.bluetooth.isCentralPoweredOn
            let hasCentral = await manager.bluetooth.hasCentralManager
            return powered || hasCentral
        }
        return manager
    }

    /// Builds a `ReliaBLEManager` after ensuring the one-time mock configuration has run.
    ///
    /// Every test routes manager creation through here so the simulated peripheral set is registered and authorization
    /// is pinned to `.notDetermined` **before** any central can be created — including by the maintainer's
    /// authorization tests, whose `.notDetermined` `authorize()` path itself creates a central. Use
    /// ``ensureReady(_:)`` afterwards to bring the manager's central online.
    ///
    /// **Serialized-suite policy:** tears down any previous active stack via ``tearDown(_:)`` so
    /// tests stay single-stack by default. Callers that need two simultaneous managers should not
    /// use this auto-teardown path alone — tear down explicitly and manage mock power carefully.
    /// - Parameter tearDownPrevious: When `true` (default), tears down the suite's previous
    ///   active stack first. Pass `false` only for multi-stack scenarios that keep two managers
    ///   alive (and call ``tearDown(_:)`` on each when done).
    @MainActor static func makeManager(
        loggingEnabled: Bool = false,
        reconnectPolicy: ReconnectPolicy? = nil,
        restoreIdentifier: String? = nil,
        idleDisconnectInterval: TimeInterval? = nil,
        tearDownPrevious: Bool = true
    ) async -> ReliaBLEManager {
        SimulationConfig.shared.ensureConfigured()

        if tearDownPrevious, let previous = activeManager {
            await tearDown(previous)
        }

        var config = ReliaBLEConfig()
        config.loggingEnabled = loggingEnabled
        config.restoreIdentifier = restoreIdentifier
        if let idleDisconnectInterval {
            config.idleDisconnectInterval = idleDisconnectInterval
        }
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
        let manager = ReliaBLEManager(config: config)
        activeManager = manager
        return manager
    }

    /// Brings the manager's central online: authorized, powered on, and reporting `.ready`.
    ///
    /// Resets authorization to `.allowedAlways` (undoing any `.denied`/`.restricted`/`.notDetermined` left by an
    /// earlier test), ensures power is on, triggers central creation if needed, clears any leaked scan, then waits for
    /// the powered-on state. With `.allowedAlways`, `authorizeBluetooth()` sets up the central and returns without
    /// suspending.
    @MainActor static func ensureReady(_ manager: ReliaBLEManager) async {
        CBMCentralManagerMock.simulateAuthorization(.allowedAlways)
        // Drop any lingering mock connection so the connectable spec advertises again, then
        // bounce power so advertising resumes cleanly for a fresh central.
        connectionTestSpec.simulateDisconnection()
        CBMCentralManagerMock.simulatePowerOff()
        CBMCentralManagerMock.simulatePowerOn()

        // Creates the central on first call (peripherals are already registered); a no-op once it exists.
        try? await manager.authorizeBluetooth()

        _ = await pollUntil(timeout: 3.0) {
            await manager.bluetooth.isCentralPoweredOn
        }

        // Clear any scan left on and recompute broadcast state now that authorization and power
        // are settled. `stopScanning()` re-runs `updateState()`, so this also resolves to `.ready`
        // when powered on and authorized.
        await manager.stopScanning()
        await manager.bluetooth.updateState()
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

    /// Waits until a `connectionStateChanges` subscription created after `baseline` is visible to the actor.
    ///
    /// The stream factory is `nonisolated` and dispatches `register(...)` as an unstructured `Task`, so awaiting
    /// any *other* actor method does not order the two jobs — it only proves that unrelated method ran. Because
    /// this feed never replays, a test that triggers its transition before the subscription lands misses the event
    /// outright. The failure mode is a silent timeout that only appears under load, so prefer this over any
    /// incidental "force an actor hop" call.
    static func waitForConnectionSubscription(
        on manager: ReliaBLEManager,
        above baseline: Int,
        timeout: Double = 3.0
    ) async -> Bool {
        await pollUntil(timeout: timeout) {
            await manager.bluetooth.testConnectionStateSubscriberCount() > baseline
        }
    }

    /// Waits for `discoveredPeripherals` to contain a peripheral with the given `id`.
    static func waitForDiscovered(
        id: String,
        on manager: ReliaBLEManager,
        withinNanoseconds nanoseconds: UInt64
    ) async -> DiscoveredPeripheral? {
        await withTaskGroup(of: DiscoveredPeripheral?.self) { group in
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
/// `await Mock.simulateInitialState(_:)` and `simulatePeripherals(_:)` must run once, before any central
/// is created. Keying this off "a central exists yet" is wrong — tests that never create a central (or that create one
/// lazily via `authorize()`) would let these run repeatedly. This actor provides a correct one-shot guard.
actor SimulationConfig {
    static let shared = SimulationConfig()
    nonisolated(unsafe) private var configured = false

    @MainActor func ensureConfigured() {
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

// MARK: - Timeout Helper

/// Sentinel thrown by ``withTimeout(nanoseconds:_:)`` when an operation does not complete in time.
struct TimedOut: Error {}

/// Executes `operation` but fails with ``TimedOut`` if it does not complete within `nanoseconds`.
///
/// Prevents an await that *should* return (or throw) from hanging the whole test run when the
/// underlying behavior regresses — the racing sleep converts a wedge into an explicit, bounded failure.
func withTimeout<T: Sendable>(
    nanoseconds: UInt64,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw TimedOut()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
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

/// Returns the first event matching `predicate` from `stream`, or `nil` if none arrives within
/// `nanoseconds`.
///
/// The mock registers multiple simulated peripherals that all advertise concurrently, so a
/// subscriber's *first* event is a race between them, not necessarily the one a test cares about.
/// Filtering by predicate makes the wait deterministic regardless of advertising order.
func firstEvent(
    from stream: AsyncStream<PeripheralDiscoveryEvent>,
    matching predicate: @escaping @Sendable (PeripheralDiscoveryEvent) -> Bool,
    withinNanoseconds nanoseconds: UInt64
) async -> PeripheralDiscoveryEvent? {
    await withTaskGroup(of: PeripheralDiscoveryEvent?.self) { group in
        group.addTask {
            for await event in stream where predicate(event) {
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
