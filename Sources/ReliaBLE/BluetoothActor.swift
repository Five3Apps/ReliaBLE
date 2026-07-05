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

private struct ConnectionPayload: @unchecked Sendable {
    let peripheral: CBPeripheral
    let error: Error?
}

/// A single CoreBluetooth delegate callback, carried in delivery order across the nonisolated
/// delegate-queue → ``BluetoothActor`` hop.
///
/// CoreBluetooth invokes delegate methods serially on its dispatch queue. ``BluetoothDelegateShim``
/// yields one of these per callback into a single `AsyncStream`, and ``BluetoothActor`` drains them
/// with a single consumer so the original callback ordering is preserved — independent per-callback
/// `Task`s could be reordered before reaching the actor.
private enum DelegateEvent: Sendable {
    case stateUpdate
    case discovered(DiscoveryPayload)
    case connected(ConnectionPayload)
    case disconnected(ConnectionPayload)
    case connectFailed(ConnectionPayload)
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

    /// Drains delegate callbacks in order. Lives for the process lifetime of the singleton actor.
    private var delegateEventTask: Task<Void, Never>?

    /// Tracks one-time actor setup so ``ensureInitialized(log:)`` is idempotent across the many
    /// `ReliaBLEManager` façades that may share this process-wide actor.
    private var isInitialized = false

    /// Continuations for in-flight ``authorize()`` calls awaiting an authorization decision, keyed by a
    /// per-call id so a cancelled call can resume just its own continuation. All pending continuations are
    /// resumed together once `CBCentralManager.authorization` resolves away from `.notDetermined`.
    private var authorizationContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]

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

    /// Per-peripheral connection states, keyed by ``Peripheral/id``.
    var connectionStates: [String: ConnectionState] = [:]

    private var connectionStateChangesContinuations: [UUID: AsyncStream<ConnectionStateChange>.Continuation] = [:]

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

    /// Upper bound on the number of discovery events buffered for a single subscriber.
    ///
    /// A `PeripheralDiscoveryEvent` is small: a `UUID`, an optional name, an `Int` RSSI, and a typed
    /// ``AdvertisementData`` snapshot whose backing advertisement payload is capped by the BLE spec at a few hundred
    /// bytes — comfortably under ~1 KB per event including Swift/Foundation overhead. Bounding the buffer at 10,000
    /// events caps a stalled or abandoned subscriber at roughly ~10 MB rather than letting it grow without limit,
    /// while staying far above any realistic in-flight backlog.
    static let discoveryBufferLimit = 10_000

    /// Returns a fresh `AsyncStream` of peripheral discovery events for a single subscriber.
    ///
    /// Unlike ``stateStream()`` and ``discoveredPeripheralsStream()`` this feed does **not** replay
    /// a value on subscription; a subscriber only receives advertisements observed after it
    /// registers. An advertisement that arrives in the narrow window between stream creation and
    /// continuation registration is missed — accepted for a lightweight advertisements feed.
    ///
    /// The buffer is bounded with `.bufferingNewest(`` discoveryBufferLimit ``)`: a slow or abandoned subscriber
    /// drops the oldest pending advertisements rather than growing memory without bound.
    nonisolated func peripheralDiscoveriesStream() -> AsyncStream<PeripheralDiscoveryEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(BluetoothActor.discoveryBufferLimit)) { continuation in
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

    /// Returns a fresh `AsyncStream` of connection-state changes for a single subscriber.
    ///
    /// Each call mints an independent stream. This feed does **not** replay a value on
    /// subscription — a subscriber only receives state changes that occur after it registers,
    /// mirroring ``peripheralDiscoveriesStream()``.
    nonisolated func connectionStateChangesStream() -> AsyncStream<ConnectionStateChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(BluetoothActor.discoveryBufferLimit)) { continuation in
            Task { await BluetoothActor.shared.register(connectionStateChangeContinuation: continuation) }
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

    private func register(connectionStateChangeContinuation continuation: AsyncStream<ConnectionStateChange>.Continuation) {
        let id = UUID()
        connectionStateChangesContinuations[id] = continuation
        continuation.onTermination = { _ in
            Task { await BluetoothActor.shared.removeConnectionStateChangeContinuation(id) }
        }
    }

    private func removeConnectionStateChangeContinuation(_ id: UUID) { connectionStateChangesContinuations[id] = nil }

    /// A one-shot snapshot of the current per-peripheral connection states.
    ///
    /// Read this to seed a view on appearance without waiting for the next
    /// ``connectionStateChangesStream()`` event.
    var currentConnectionStates: [String: ConnectionState] {
        connectionStates
    }

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

    /// Performs idempotent actor setup, funneled through by every public ``ReliaBLEManager`` entry point
    /// before it acts — so an operation invoked immediately after `init` (whose setup runs in a
    /// fire-and-forget `Task`) cannot race ahead of setup and silently no-op.
    ///
    /// The logger is configured exactly once. On *every* call this also creates the central manager if
    /// Bluetooth is currently authorized (`.allowedAlways`) and one does not already exist — so an
    /// operation issued after authorization is granted out-of-band (via Settings, app lifecycle, or
    /// another owner) still finds a live manager instead of being permanently gated by the first call's
    /// authorization status.
    ///
    /// Creating the central manager remains gated on existing `.allowedAlways` authorization, preserving
    /// the lazy-permission contract: the iOS prompt only appears when the integrating app calls
    /// ``ReliaBLEManager/authorizeBluetooth()``. The initial state is broadcast on first setup and
    /// whenever the manager is created, but not on every redundant call.
    func ensureInitialized(log: LoggingService) {
        let firstInitialization = !isInitialized
        if firstInitialization {
            isInitialized = true
            configure(log: log)
        }

        var createdManager = false
        if centralManager == nil, CBCentralManager.authorization == .allowedAlways {
            setupCentralManager()
            createdManager = true
        }

        if firstInitialization || createdManager {
            updateState()
        }
    }

    // MARK: - Central Manager Setup

    func setupCentralManager() {
        guard centralManager == nil else { return }

        log?.info("Initializing CBCentralManager")

        // A single `AsyncStream` carries delegate callbacks in CoreBluetooth's delivery order; the lone
        // consumer task below drains them so ordering is preserved end-to-end. The buffer is intentionally
        // unbounded: state-change callbacks must never be dropped (unlike the public advertisements feed),
        // and `process(_:)` is lightweight, so the actor keeps pace with CoreBluetooth's serial callback
        // rate in practice.
        let (events, continuation) = AsyncStream.makeStream(
            of: DelegateEvent.self,
            bufferingPolicy: .unbounded
        )
        let shim = BluetoothDelegateShim(eventContinuation: continuation)
        delegateShim = shim
        // Use CBCentralManagerFactory for consistency between normal and test targets.
        // `forceMock: true` is load-bearing for the ReliaBLEMock test target — do not remove.
        centralManager = CBCentralManagerFactory.instance(delegate: shim, queue: centralManagerQueue, options: nil, forceMock: true)

        delegateEventTask = Task { [weak self] in
            for await event in events {
                await self?.process(event)
            }
        }
    }

    /// Drains a single delegate event on the actor, preserving CoreBluetooth's callback order.
    private func process(_ event: DelegateEvent) {
        switch event {
        case .stateUpdate:
            handleCentralManagerStateUpdate()
        case .discovered(let payload):
            handlePeripheralDiscovered(
                payload.peripheral,
                advertisementData: payload.advertisementData,
                rssi: payload.rssi
            )
        case .connected(let payload):
            handleDidConnect(payload)
        case .disconnected(let payload):
            handleDidDisconnect(payload)
        case .connectFailed(let payload):
            handleDidFailToConnect(payload)
        }
    }

    // MARK: - Authorization

    /// Performs the authorization decision for a single ``ReliaBLEManager/authorizeBluetooth()`` call.
    ///
    /// For undetermined authorization this creates the central manager (triggering the iOS prompt) and
    /// suspends until the decision arrives via `centralManagerDidUpdateState`, so a successful return
    /// means Bluetooth is authorized. The caller-supplied `id` lets ``ReliaBLEManager`` cancel this
    /// specific wait via ``cancelAuthorizationContinuation(_:)``.
    ///
    /// The `withTaskCancellationHandler` that wires cancellation lives in the nonisolated
    /// ``ReliaBLEManager`` façade, not here, to keep this actor-isolated method free of a construct the
    /// region-based isolation checker cannot yet analyze.
    func authorize(id: UUID) async throws {
        log?.info("Authorizing bluetooth")

        switch CBCentralManager.authorization {
        case .notDetermined:
            setupCentralManager()
            try await suspendForAuthorizationDecision(id: id)
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

    /// Suspends until the pending authorization decision resolves (or the calling task is cancelled),
    /// storing the continuation under `id`. Kept as its own actor-isolated method so the surrounding
    /// `withTaskCancellationHandler` operation closure stays simple for the region-isolation checker.
    private func suspendForAuthorizationDecision(id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The task may already be cancelled by the time this job runs on the actor.
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            authorizationContinuations[id] = continuation
        }
    }

    /// Resumes a single pending authorization continuation with a `CancellationError`, if still pending.
    /// Invoked from ``ReliaBLEManager``'s cancellation handler.
    func cancelAuthorizationContinuation(_ id: UUID) {
        authorizationContinuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Resolves any ``authorize()`` calls suspended on an authorization decision.
    ///
    /// Called after every `centralManagerDidUpdateState`, since CoreBluetooth surfaces an
    /// authorization change as a state update. While the decision is still pending
    /// (`.notDetermined`) the continuations remain suspended.
    private func resolvePendingAuthorization() {
        guard !authorizationContinuations.isEmpty else { return }

        let result: Result<Void, Error>
        switch CBCentralManager.authorization {
        case .notDetermined:
            return // Still awaiting the user's decision.
        case .allowedAlways:
            result = .success(())
        case .denied:
            result = .failure(AuthorizationError.denied)
        case .restricted:
            result = .failure(AuthorizationError.restricted)
        @unknown default:
            result = .failure(AuthorizationError.unknown)
        }

        let pending = authorizationContinuations
        authorizationContinuations.removeAll()
        for continuation in pending.values {
            continuation.resume(with: result)
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
        resolvePendingAuthorization()
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

        // Derive the app-facing `id` from the advertised name, falling back to the local name and
        // finally the CoreBluetooth identifier string.
        //
        // TODO: FR-8.5 — Unique Identifier from Manufacturing Data.
        // KNOWN LIMITATION: advertised names are not unique. Two distinct physical devices that
        // advertise the same name resolve to the same `identifier` here, so they collapse into a
        // single `discoveredPeripherals` entry and a single `cbPeripherals` slot — the later
        // discovery overwrites the earlier device's live `CBPeripheral`, so `connect(id:)` may target
        // whichever was seen last. FR-8.5 will replace this with a stable identity derived from
        // manufacturing data; until then the dedup key is best-effort. The `cbIdentifier` fallback
        // below only rescues a *single* device whose advertised name changes, not the same-name
        // collision between *different* devices.
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
        connectionStates.removeAll()
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

    /// Resolves a ``Peripheral/id`` from the live `CBPeripheral` reference using reverse object-identity lookup.
    ///
    /// Derives nothing — it reads back the key that ``handlePeripheralDiscovered(_:advertisementData:rssi:)``
    /// already assigned, so ``handlePeripheralDiscovered(_:advertisementData:rssi:)`` remains the library's single
    /// source of identity truth.
    // TODO: FR-8.5
    private func id(for cbPeripheral: CBPeripheral) -> String? {
        cbPeripherals.first { $0.value === cbPeripheral }?.key
    }

    private func handleDidConnect(_ payload: ConnectionPayload) {
        guard let id = id(for: payload.peripheral) else {
            log?.warn(tags: [.category(.connection)], "didConnect for unknown peripheral — dropped")
            return
        }
        connectionStates[id] = .connected
        log?.info(tags: [.peripheral(id), .category(.connection)], "Peripheral connected")
        broadcast(ConnectionStateChange(peripheralId: id, state: .connected), to: connectionStateChangesContinuations)
    }

    private func handleDidDisconnect(_ payload: ConnectionPayload) {
        guard let id = id(for: payload.peripheral) else {
            log?.warn(tags: [.category(.connection)], "didDisconnect for unknown peripheral — dropped")
            return
        }
        let mappedError: PeripheralError? = payload.error.flatMap { ($0 as? CBError).map { PeripheralError.fromCBError($0) } }
        let state: ConnectionState = .disconnected(reason: mappedError)
        connectionStates[id] = state
        if let error = mappedError {
            log?.warn(tags: [.peripheral(id), .category(.connection)], "Peripheral disconnected with error: \(error)")
        } else {
            log?.info(tags: [.peripheral(id), .category(.connection)], "Peripheral disconnected")
        }
        broadcast(ConnectionStateChange(peripheralId: id, state: state), to: connectionStateChangesContinuations)
    }

    private func handleDidFailToConnect(_ payload: ConnectionPayload) {
        guard let id = id(for: payload.peripheral) else {
            log?.warn(tags: [.category(.connection)], "didFailToConnect for unknown peripheral — dropped")
            return
        }
        let mappedError: PeripheralError? = payload.error.flatMap { ($0 as? CBError).map { PeripheralError.fromCBError($0) } }
        let state: ConnectionState = .failed(reason: mappedError)
        connectionStates[id] = state
        log?.warn(tags: [.peripheral(id), .category(.connection)], "Peripheral connection failed with error: \(mappedError ?? .unknown)")
        broadcast(ConnectionStateChange(peripheralId: id, state: state), to: connectionStateChangesContinuations)
    }

    /// Initiates a connection to the live peripheral backing the given snapshot `id`.
    ///
    /// Optimistically broadcasts `.connecting` before the CoreBluetooth call, then issues the
    /// connection request. The actual `.connected` or `.failed` callback arrives later via the
    /// delegate pipeline.
    ///
    /// - Parameter id: The ``Peripheral/id`` of a previously discovered peripheral.
    /// - Throws: ``PeripheralError/notFound`` if no live `CBPeripheral` is registered for `id` (a stale snapshot).
    /// - Throws: ``PeripheralError/bluetoothUnavailable`` if Bluetooth has not been set up.
    func connect(id: String) throws {
        guard let centralManager else {
            log?.warn(tags: [.peripheral(id)], "Attempted to connect without a central manager")
            throw PeripheralError.bluetoothUnavailable
        }

        guard let cbPeripheral = cbPeripherals[id] else {
            throw PeripheralError.notFound
        }

        connectionStates[id] = .connecting
        broadcast(ConnectionStateChange(peripheralId: id, state: .connecting), to: connectionStateChangesContinuations)
        centralManager.connect(cbPeripheral, options: nil)
    }

    /// Initiates a disconnection from the live peripheral backing the given snapshot `id`.
    ///
    /// Optimistically broadcasts `.disconnecting` before cancelling the connection. The actual
    /// `.disconnected` callback arrives later via the delegate pipeline.
    ///
    /// - Parameter id: The ``Peripheral/id`` of a previously connected peripheral.
    /// - Throws: ``PeripheralError/notFound`` if no live `CBPeripheral` is registered for `id`.
    /// - Throws: ``PeripheralError/bluetoothUnavailable`` if Bluetooth has not been set up.
    func disconnect(id: String) throws {
        guard let centralManager else {
            log?.warn(tags: [.peripheral(id)], "Attempted to disconnect without a central manager")
            throw PeripheralError.bluetoothUnavailable
        }

        guard let cbPeripheral = cbPeripherals[id] else {
            throw PeripheralError.notFound
        }

        connectionStates[id] = .disconnecting
        broadcast(ConnectionStateChange(peripheralId: id, state: .disconnecting), to: connectionStateChangesContinuations)
        centralManager.cancelPeripheralConnection(cbPeripheral)
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

    /// Sink for delegate callbacks, drained in order by ``BluetoothActor``'s consumer task.
    private let eventContinuation: AsyncStream<DelegateEvent>.Continuation

    fileprivate init(eventContinuation: AsyncStream<DelegateEvent>.Continuation) {
        self.eventContinuation = eventContinuation
        super.init()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Yielding is synchronous and thread-safe; ordering is preserved because CoreBluetooth
        // invokes delegate methods serially on its dispatch queue.
        eventContinuation.yield(.stateUpdate)
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
        eventContinuation.yield(.discovered(payload))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let payload = ConnectionPayload(peripheral: peripheral, error: nil)
        eventContinuation.yield(.connected(payload))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        let payload = ConnectionPayload(peripheral: peripheral, error: error)
        eventContinuation.yield(.disconnected(payload))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let payload = ConnectionPayload(peripheral: peripheral, error: error)
        eventContinuation.yield(.connectFailed(payload))
    }
}
