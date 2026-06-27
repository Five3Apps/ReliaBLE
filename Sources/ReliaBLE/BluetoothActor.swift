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
/// All mutable BLE state—`CBCentralManager`, per-subscriber `AsyncStream` continuations, and
/// discovered peripherals—are owned exclusively by this actor. Two `ReliaBLEManager` instances
/// share the same isolation domain; this is acceptable because CoreBluetooth already
/// enforces a single central manager per process.
///
/// Delegate callbacks arrive on CoreBluetooth's internal queue and are hopped into this
/// actor's isolation via `Task { @BluetoothActor in … }` inside the nonisolated
/// ``BluetoothDelegateShim``.
@globalActor
actor BluetoothActor {
    /// The process-lifetime shared instance.
    static let shared = BluetoothActor()

    // MARK: - Actor-Isolated State

    private let centralManagerQueue = DispatchQueue(label: "com.five3apps.relia-ble.bluetoothmanager", qos: .userInitiated)

    var centralManager: CBCentralManager?
    private var delegateShim: BluetoothDelegateShim?
    
    /// The current Bluetooth state.
    var currentBluetoothState: BluetoothState = .unknown

    var log: LoggingService?

    /// Value snapshots of all discovered peripherals, keyed implicitly by ``Peripheral/id``.
    var discoveredPeripherals: [Peripheral] = []

    /// Live `CBPeripheral` references keyed by ``Peripheral/id``.
    ///
    /// This mutable, non-`Sendable` reference map never escapes the actor. ``Peripheral`` snapshots carry only an
    /// `id`; operations that need the live peripheral look it up here.
    private var cbPeripherals: [String: CBPeripheral] = [:]

    // MARK: - AsyncStream Broadcaster State
    //
    // One continuation per active subscriber, keyed by a per-subscription UUID. Mutated only on
    // the actor's serial executor: the stream factories register on a `@BluetoothActor` hop, the
    // broadcast sites iterate to `yield`, and each `onTermination` handler prunes its own entry.

    private var stateContinuations: [UUID: AsyncStream<BluetoothState>.Continuation] = [:]
    private var discoveryContinuations: [UUID: AsyncStream<PeripheralDiscoveryEvent>.Continuation] = [:]
    private var peripheralsContinuations: [UUID: AsyncStream<[Peripheral]>.Continuation] = [:]

    // MARK: - Initialization

    private init() {}

    // MARK: - Event Streams

    /// Returns a fresh `AsyncStream` of Bluetooth state changes for a single subscriber.
    ///
    /// Each call mints an independent stream; multiple subscribers are supported by design. The
    /// current state is replayed as the first element (`.bufferingNewest(1)`, latest-wins), so a
    /// new subscriber always observes the current state without waiting for the next broadcast.
    nonisolated func stateStream() -> AsyncStream<BluetoothState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await BluetoothActor.shared.register(stateContinuation: continuation) }
        }
    }

    /// Returns a fresh `AsyncStream` of peripheral discovery events for a single subscriber.
    ///
    /// Unlike ``stateStream()`` and ``discoveredPeripheralsStream()`` this feed does **not** replay
    /// a value on subscription; a subscriber only receives advertisements observed after it
    /// registers. An advertisement that arrives in the narrow window between stream creation and
    /// continuation registration is missed — accepted for a lightweight advertisements feed.
    nonisolated func peripheralDiscoveriesStream() -> AsyncStream<PeripheralDiscoveryEvent> {
        AsyncStream { continuation in
            Task { await BluetoothActor.shared.register(discoveryContinuation: continuation) }
        }
    }

    /// Returns a fresh `AsyncStream` of the current discovered-peripherals list for a single
    /// subscriber.
    ///
    /// The current list is replayed as the first element (`.bufferingNewest(1)`, latest-wins), so
    /// a new subscriber immediately observes the peripherals already discovered.
    nonisolated func discoveredPeripheralsStream() -> AsyncStream<[Peripheral]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await BluetoothActor.shared.register(peripheralsContinuation: continuation) }
        }
    }

    // MARK: - Continuation Registration
    //
    // Registration runs as a single, indivisible actor job: the replay-yield, dictionary insert,
    // and `onTermination` assignment cannot interleave with a broadcast. The only residual gap is
    // the window between `AsyncStream` creation and this job starting — an event emitted then is
    // missed by a *new* (replay-less) `peripheralDiscoveries` subscriber. Accepted and documented.

    private func register(stateContinuation continuation: AsyncStream<BluetoothState>.Continuation) {
        let id = UUID()
        continuation.yield(currentBluetoothState)
        stateContinuations[id] = continuation
        continuation.onTermination = { _ in
            Task { await BluetoothActor.shared.removeStateContinuation(id) }
        }
    }

    private func register(discoveryContinuation continuation: AsyncStream<PeripheralDiscoveryEvent>.Continuation) {
        let id = UUID()
        discoveryContinuations[id] = continuation
        continuation.onTermination = { _ in
            Task { await BluetoothActor.shared.removeDiscoveryContinuation(id) }
        }
    }

    private func register(peripheralsContinuation continuation: AsyncStream<[Peripheral]>.Continuation) {
        let id = UUID()
        continuation.yield(discoveredPeripherals)
        peripheralsContinuations[id] = continuation
        continuation.onTermination = { _ in
            Task { await BluetoothActor.shared.removePeripheralsContinuation(id) }
        }
    }

    private func removeStateContinuation(_ id: UUID) { stateContinuations[id] = nil }
    private func removeDiscoveryContinuation(_ id: UUID) { discoveryContinuations[id] = nil }
    private func removePeripheralsContinuation(_ id: UUID) { peripheralsContinuations[id] = nil }

    /// Yields a value to every registered continuation in `continuations`.
    ///
    /// Yielding to an already-finished continuation is a harmless no-op, so this never prunes —
    /// dead continuations remove themselves via their `onTermination` handler.
    private func broadcast<Element: Sendable>(
        _ value: Element,
        to continuations: [UUID: AsyncStream<Element>.Continuation]
    ) {
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    // MARK: - Configuration

    func configure(log: LoggingService) {
        self.log = log
    }

    /// Configures the actor with a logger, conditionally sets up the central manager if
    /// Bluetooth is already authorized, then broadcasts the initial state. Called once from
    /// `ReliaBLEManager.init` via a fire-and-forget `Task`.
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
        // Update the actor-isolated snapshot first; it backs the async `currentState` accessor and
        // is replayed to each new `stateStream()` subscriber during registration.
        currentBluetoothState = state
        broadcast(state, to: stateContinuations)
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
        broadcast(
            PeripheralDiscoveryEvent(cbPeripheral: cbPeripheral, advertisement: advertisement, rssi: rssi),
            to: discoveryContinuations
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
        broadcast(discoveredPeripherals, to: peripheralsContinuations)
    }

    private func invalidatePeripherals() {
        // The value snapshots hold no CoreBluetooth reference to clear; drop the live registry instead.
        cbPeripherals.removeAll()
        broadcast(discoveredPeripherals, to: peripheralsContinuations)
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
        broadcast(discoveredPeripherals, to: peripheralsContinuations)
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
