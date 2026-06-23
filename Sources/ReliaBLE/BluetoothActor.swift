//
//  BluetoothActor.swift
//  ReliaBLE
//
//  Created by Justin Bergen on 6/8/26.
//
//  Copyright (c) 2026 Five3 Apps, LLC <justin@five3apps.com>
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

import Combine
import CoreBluetooth
import Foundation

// MARK: - Sendable Bridging Helper

/// Carries one discovery callback's raw CoreBluetooth payload across the nonisolated
/// delegate-queue → ``BluetoothActor`` hop.
///
/// The `CBPeripheral` and `[String: Any]` advertisement dictionary delivered by the delegate are non-`Sendable`.
/// They are treated as immutable payload and are only accessed inside ``BluetoothActor`` after the hop, where they are
/// immediately converted into `Sendable` value snapshots (``Peripheral`` / ``AdvertisementData``). The raw payload is
/// never stored outside the actor.
///
/// This is a single-purpose `@unchecked Sendable` boundary rather than a general-purpose wrapper, so the unchecked
/// assertion stays scoped to exactly this transfer.
private struct DiscoveryPayload: @unchecked Sendable {
    let peripheral: CBPeripheral
    let advertisementData: [String: Any]
    let rssi: Int
}

// MARK: - BluetoothActor

/// Process-wide global actor that serializes all CoreBluetooth interactions.
///
/// All mutable BLE state—`CBCentralManager`, Combine subjects, and discovered
/// peripherals—are owned exclusively by this actor. Two `ReliaBLEManager` instances
/// share the same isolation domain; this is acceptable because CoreBluetooth already
/// enforces a single central manager per process.
///
/// Delegate callbacks arrive on CoreBluetooth's internal queue and are hopped into this
/// actor's isolation via `Task { @BluetoothActor in … }` inside the nonisolated
/// ``BluetoothDelegateShim``.
@globalActor
public actor BluetoothActor {

    /// The process-lifetime shared instance.
    public static let shared = BluetoothActor()

    // MARK: - Actor-Isolated State

    private let centralManagerQueue = DispatchQueue(label: "com.five3apps.relia-ble.bluetoothmanager", qos: .userInitiated)

    var centralManager: CBCentralManager?
    private var delegateShim: BluetoothDelegateShim?

    var log: LoggingService?

    /// Value snapshots of all discovered peripherals, keyed implicitly by ``Peripheral/id``.
    var discoveredPeripherals: [Peripheral] = []

    /// Live `CBPeripheral` references keyed by ``Peripheral/id``.
    ///
    /// This mutable, non-`Sendable` reference map never escapes the actor. ``Peripheral`` snapshots carry only an
    /// `id`; operations that need the live peripheral look it up here.
    private var cbPeripherals: [String: CBPeripheral] = [:]

    // Combine subjects — written only from actor-isolated context.
    let stateSubject = CurrentValueSubject<BluetoothState, Never>(.unknown)
    let discoverySubject = PassthroughSubject<PeripheralDiscoveryEvent, Never>()
    let discoveredPeripheralsSubject = PassthroughSubject<[Peripheral], Never>()

    // MARK: - nonisolated(unsafe) Bridging Properties
    //
    // Publishers are extracted once in `init` and never reassigned — safe for concurrent reads.
    // `currentBluetoothState` is written only by the serial actor executor via
    // `broadcastState(_:)` — safe for concurrent reads (value semantics, no partial writes).
    //
    // TODO: All removed in Step 3 when AnyPublisher is replaced by AsyncStream.

    /// Publisher for the real-time Bluetooth state. **TODO: removed in Step 3.**
    nonisolated(unsafe) let statePublisher: AnyPublisher<BluetoothState, Never>

    /// Publisher for peripheral discovery events. **TODO: removed in Step 3.**
    nonisolated(unsafe) let discoveryPublisher: AnyPublisher<PeripheralDiscoveryEvent, Never>

    /// Publisher for the current list of discovered peripherals. **TODO: removed in Step 3.**
    nonisolated(unsafe) let discoveredPeripheralsPublisher: AnyPublisher<[Peripheral], Never>

    /// Synchronous snapshot of the current Bluetooth state.
    ///
    /// Written only from `broadcastState(_:)` on the actor's serial executor.
    /// **TODO: removed in Step 3.**
    nonisolated(unsafe) var currentBluetoothState: BluetoothState = .unknown

    // MARK: - Initialization

    private init() {
        statePublisher = stateSubject.eraseToAnyPublisher()
        discoveryPublisher = discoverySubject.eraseToAnyPublisher()
        discoveredPeripheralsPublisher = discoveredPeripheralsSubject.eraseToAnyPublisher()
    }

    // MARK: - Configuration

    func configure(log: LoggingService) {
        self.log = log
    }

    /// Configures the actor with a logger, conditionally sets up the central manager if
    /// Bluetooth is already authorized, then broadcasts the initial state. Called once from
    /// `BluetoothManager.init` via a fire-and-forget `Task`.
    func initialize(log: LoggingService) {
        configure(log: log)
        if CBCentralManager.authorization == .allowedAlways {
            setupCentralManager()
        }
        updateState()
    }

    // MARK: - Central Manager Setup

    func setupCentralManager() {
        guard centralManager == nil else { return }

        log?.info("Initializing CBCentralManager")

        let shim = BluetoothDelegateShim()
        delegateShim = shim
        // Use CBCentralManagerFactory for consistency between normal and test targets.
        // `forceMock: true` is load-bearing for the ReliaBLEMock test target — do not remove.
        centralManager = CBCentralManagerFactory.instance(delegate: shim, queue: centralManagerQueue, options: nil, forceMock: true)
    }

    // MARK: - Authorization

    func authorize() throws {
        log?.info("Authorizing bluetooth")

        switch CBCentralManager.authorization {
        case .notDetermined:
            setupCentralManager()
        case .denied:
            throw AuthorizationError.denied
        case .restricted:
            throw AuthorizationError.restricted
        case .allowedAlways:
            setupCentralManager()
        @unknown default:
            throw AuthorizationError.unknown
        }
    }

    // MARK: - Scanning

    func startScanning(services: sending [CBUUID]? = nil) {
        guard let centralManager else {
            log?.warn(tags: [.category(.scanning)], "Attempted to start scan without a central manager")
            return
        }

        guard centralManager.state == .poweredOn else {
            log?.warn(tags: [.category(.scanning)], "Attempted to start scan while central manager is not ready (poweredOn)")
            return
        }

        centralManager.scanForPeripherals(withServices: services, options: nil)

        if centralManager.isScanning {
            log?.info(tags: [.category(.scanning)], "Scanning started with services: \(services ?? [])")
            updateState()
        } else {
            log?.warn(tags: [.category(.scanning)], "Failed to start scanning")
        }
    }

    func stopScanning() {
        guard let centralManager else {
            log?.warn(tags: [.category(.scanning)], "Attempted to stop scan without a central manager")
            return
        }

        centralManager.stopScan()

        if !centralManager.isScanning {
            log?.info(tags: [.category(.scanning)], "Scanning stopped")
            updateState()
        } else {
            log?.warn(tags: [.category(.scanning)], "Failed to stop scanning")
        }
    }

    // MARK: - State Management

    func updateState() {
        switch CBCentralManager.authorization {
        case .notDetermined:
            broadcastState(.unauthorized(.notDetermined))
            return
        case .denied:
            broadcastState(.unauthorized(.denied))
            return
        case .restricted:
            broadcastState(.unauthorized(.restricted))
            return
        default:
            break
        }

        // Check scanning before centralManager state — scanning implies poweredOn.
        if centralManager?.isScanning == true {
            broadcastState(.scanning)
            return
        }

        switch centralManager?.state {
        case .poweredOn:
            broadcastState(.ready)
        case .poweredOff:
            broadcastState(.poweredOff)
        case .resetting:
            broadcastState(.resetting)
        case .unsupported:
            broadcastState(.unsupported)
        default:
            broadcastState(.unknown)
        }
    }

    private func broadcastState(_ state: BluetoothState) {
        stateSubject.send(state)
        // nonisolated(unsafe) write — safe: written only from the actor's serial executor.
        // TODO: removed in Step 3
        currentBluetoothState = state
    }

    // MARK: - Delegate Entry Points (called by BluetoothDelegateShim)

    func handleCentralManagerStateUpdate() {
        guard let centralManager else { return }

        log?.debug("centralManagerDidUpdateState: \(centralManager.state.rawValue)")

        switch centralManager.state {
        case .poweredOn:
            refreshPeripherals()
        case .poweredOff, .unknown:
            // These states do not invalidate peripherals.
            break
        case .resetting, .unsupported, .unauthorized:
            invalidatePeripherals()
        @unknown default:
            log?.error("Unknown CBCentralManager state encountered: \(centralManager.state.rawValue)")
            assertionFailure("Unknown CBCentralManager state encountered: \(centralManager.state.rawValue)")
        }

        updateState()
    }

    func handlePeripheralDiscovered(
        _ cbPeripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: Int
    ) {
        // Extract the untyped advertisement dictionary into a typed, Sendable snapshot exactly once. The raw
        // `[String: Any]` does not leave this actor; the same `AdvertisementData` feeds both the discovery event
        // and the stored `Peripheral` snapshot.
        let advertisement = AdvertisementData(rawAdvertisementData: advertisementData)

        // Emit lightweight discovery feed.
        // TODO: Implement verbose log level
        discoverySubject.send(
            PeripheralDiscoveryEvent(cbPeripheral: cbPeripheral, advertisement: advertisement, rssi: rssi)
        )

        // TODO: FR-8.5: Unique Identifier from Manufacturing Data — connect to id once implemented
        let identifier = cbPeripheral.name
            ?? advertisement.localName
            ?? cbPeripheral.identifier.uuidString

        let cbIdentifier = cbPeripheral.identifier
        let name = cbPeripheral.name ?? advertisement.localName
        let now = Date()

        // Resolve the id to store under. Prefer an existing entry matching the app-facing `identifier`; otherwise
        // fall back to an existing entry for the same `CBPeripheral` (whose resolved `id` may differ if the name has
        // since changed), preserving that entry's original `id`. Otherwise this is a brand-new peripheral.
        let resolvedId: String
        if let idx = discoveredPeripherals.firstIndex(where: { $0.id == identifier }) {
            resolvedId = identifier
            discoveredPeripherals[idx] = Peripheral(
                id: resolvedId,
                cbIdentifier: cbIdentifier,
                name: name,
                rssi: rssi,
                lastSeen: now,
                advertisement: advertisement
            )
        } else if let idx = discoveredPeripherals.firstIndex(where: { $0.cbIdentifier == cbIdentifier }) {
            resolvedId = discoveredPeripherals[idx].id
            discoveredPeripherals[idx] = Peripheral(
                id: resolvedId,
                cbIdentifier: cbIdentifier,
                name: name,
                rssi: rssi,
                lastSeen: now,
                advertisement: advertisement
            )
        } else {
            resolvedId = identifier
            let new = Peripheral(
                id: resolvedId,
                cbIdentifier: cbIdentifier,
                name: name,
                rssi: rssi,
                lastSeen: now,
                advertisement: advertisement
            )
            log?.debug(tags: [.category(.scanning), .peripheral(new.id)], "Adding newly discovered peripheral")
            discoveredPeripherals.append(new)
        }

        // Stash the live reference under the resolved id. Never escapes the actor.
        cbPeripherals[resolvedId] = cbPeripheral
        discoveredPeripheralsSubject.send(discoveredPeripherals)
    }

    private func invalidatePeripherals() {
        // The value snapshots hold no CoreBluetooth reference to clear; drop the live registry instead.
        cbPeripherals.removeAll()
        discoveredPeripheralsSubject.send(discoveredPeripherals)
        log?.debug("Invalidated all peripheral references")
    }

    private func refreshPeripherals() {
        guard let centralManager else { return }

        let identifiers = discoveredPeripherals.compactMap { $0.cbIdentifier }
        guard !identifiers.isEmpty else {
            log?.debug("No peripheral identifiers to refresh")
            return
        }

        let retrieved = centralManager.retrievePeripherals(withIdentifiers: identifiers)
        for cbPeripheral in retrieved {
            if let p = discoveredPeripherals.first(where: { $0.cbIdentifier == cbPeripheral.identifier }) {
                cbPeripherals[p.id] = cbPeripheral
            }
        }
        discoveredPeripheralsSubject.send(discoveredPeripherals)
        log?.debug("Refreshed \(retrieved.count) peripherals from CBCentralManager")
    }

    // MARK: - Connection

    /// Initiates a connection to the live peripheral backing the given snapshot `id`.
    ///
    /// - Parameter id: The ``Peripheral/id`` of a previously discovered peripheral.
    /// - Throws: ``PeripheralError/notFound`` if no live `CBPeripheral` is registered for `id` (a stale snapshot).
    ///
    /// - Note: This currently only fires the connection request. The full connection lifecycle
    ///   (didConnect/didDisconnect handling and a connection-state surface) is deferred to a later release.
    func connect(id: String) throws {
        guard let cbPeripheral = cbPeripherals[id] else {
            throw PeripheralError.notFound
        }

        guard let centralManager else {
            // Mirrors the start/stopScanning convention: no central manager means there is nothing to act on.
            // In practice unreachable — the registry is only populated while a central manager exists.
            log?.warn(tags: [.peripheral(id)], "Attempted to connect without a central manager")
            return
        }

        centralManager.connect(cbPeripheral, options: nil)
    }
}

// MARK: - BluetoothDelegateShim

/// Bridges `CBCentralManagerDelegate` callbacks—which arrive on CoreBluetooth's internal
/// queue—into ``BluetoothActor``-isolated handlers via unstructured `Task` hops.
///
/// The shim holds no mutable state. All meaningful work happens inside ``BluetoothActor``.
/// No weak/unowned reference is needed because ``BluetoothActor/shared`` is a
/// process-lifetime singleton.
final class BluetoothDelegateShim: NSObject, CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @BluetoothActor in await BluetoothActor.shared.handleCentralManagerStateUpdate() }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Ferry the non-Sendable CBPeripheral and advertisement dictionary across the actor isolation hop in a
        // single-purpose payload. They are extracted into Sendable types (Peripheral / AdvertisementData) inside
        // the actor.
        let payload = DiscoveryPayload(peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI.intValue)
        Task { @BluetoothActor in
            await BluetoothActor.shared.handlePeripheralDiscovered(
                payload.peripheral,
                advertisementData: payload.advertisementData,
                rssi: payload.rssi
            )
        }
    }
}
