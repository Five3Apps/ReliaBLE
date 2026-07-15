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
    let isReconnecting: Bool
    let error: Error?
}

/// Carries the restoration dictionary from `centralManager(_:willRestoreState:)` across the
/// nonisolated delegate-queue → ``BluetoothActor`` hop.
///
/// The dictionary and nested `CBPeripheral` / `CBUUID` values are non-`Sendable`. They are treated
/// as immutable payload and only accessed inside ``BluetoothActor`` after the hop, where they are
/// immediately converted into `Sendable` snapshots and actor-owned live references.
private struct RestorationPayload: @unchecked Sendable {
    let state: [String: Any]
}

/// Holds a restored scan-options dictionary so it can live in actor-isolated state without
/// tripping region-based isolation on non-`Sendable` `[String: Any]`.
private struct RestoredScanOptions: @unchecked Sendable {
    let options: [String: Any]?
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
    case willRestore(RestorationPayload)
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

    private var reconnectPolicy: ReconnectPolicy = ReconnectPolicy()
    /// Stable CoreBluetooth restore identifier; `nil` disables state restoration.
    private var restoreIdentifier: String?
    /// Scan filter restored via `willRestoreState` when the central was not yet powered on.
    private var pendingRestoredScanServices: [CBUUID]?
    private var pendingRestoredScanOptions: RestoredScanOptions?
    private var reconnectEnabled: Set<String> = []
    private var intentionalDisconnects: Set<String> = []
    private var reconnectAttempts: [String: Int] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]

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
    ///
    /// When ``restoreIdentifier`` is non-`nil` and authorization is already `.allowedAlways`, the
    /// central is created with `CBCentralManagerOptionRestoreIdentifierKey` so CoreBluetooth can
    /// deliver `willRestoreState` as the first callback on relaunch. Authorization is never
    /// relaxed — if Bluetooth is not authorized there is nothing to restore.
    func ensureInitialized(
        log: LoggingService,
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy(),
        restoreIdentifier: String? = nil
    ) {
        let firstInitialization = !isInitialized
        if firstInitialization {
            isInitialized = true
            configure(log: log)
            self.reconnectPolicy = reconnectPolicy
            self.restoreIdentifier = restoreIdentifier
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
        var options: [String: Any]?
        if let restoreIdentifier {
            options = [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
        }
        centralManager = CBCentralManagerFactory.instance(
            delegate: shim,
            queue: centralManagerQueue,
            options: options,
            forceMock: true
        )

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
        case .willRestore(let payload):
            handleWillRestoreState(payload)
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

        if services == nil || services?.isEmpty == true {
            log?.warn(
                tags: [.category(.scanning)],
                "Scanning with an empty/nil service filter; background scanning requires a non-empty service UUID filter"
            )
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

    /// Rehydrates scan and connection state delivered by CoreBluetooth on app relaunch.
    ///
    /// Restored `CBPeripheral`s arrive with no peripheral delegate and must be re-associated into
    /// ``cbPeripherals`` immediately. Connection state is seeded from each peripheral's
    /// `CBPeripheral.state`; no synchronous reconnect is issued (standing connects are OS-held).
    /// If Bluetooth is later reported off/unauthorized, ``invalidatePeripherals()`` clears this
    /// state intentionally.
    private func handleWillRestoreState(_ payload: RestorationPayload) {
        let restoredPeripherals = payload.state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let restoredScanServices = payload.state[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID]
        let restoredScanOptions = payload.state[CBCentralManagerRestoredStateScanOptionsKey] as? [String: Any]

        log?.info(
            tags: [.category(.scanning)],
            "Restoring BLE state: \(restoredPeripherals.count) peripheral(s), scanServices=\(restoredScanServices ?? [])"
        )

        // Empty advertisement placeholder — restoration carries no advertisement payload.
        let emptyAdvertisement = AdvertisementData(rawAdvertisementData: [:])
        let now = Date()
        var didMutatePeripherals = false

        for cbPeripheral in restoredPeripherals {
            // Restored peripherals arrive with no delegate; re-associate into actor-owned maps
            // using the same identity rules as discovery. Peripheral-level GATT callbacks are not
            // yet used by the library, so no `CBPeripheralDelegate` is attached here.
            let identifier = cbPeripheral.name ?? cbPeripheral.identifier.uuidString
            let cbIdentifier = cbPeripheral.identifier
            let name = cbPeripheral.name

            let resolvedId: String
            if let idx = discoveredPeripherals.firstIndex(where: { $0.id == identifier }) {
                resolvedId = identifier
                discoveredPeripherals[idx] = Peripheral(
                    id: resolvedId,
                    cbIdentifier: cbIdentifier,
                    name: name,
                    rssi: discoveredPeripherals[idx].rssi,
                    lastSeen: now,
                    advertisement: discoveredPeripherals[idx].advertisement ?? emptyAdvertisement
                )
            } else if let idx = discoveredPeripherals.firstIndex(where: { $0.cbIdentifier == cbIdentifier }) {
                resolvedId = discoveredPeripherals[idx].id
                discoveredPeripherals[idx] = Peripheral(
                    id: resolvedId,
                    cbIdentifier: cbIdentifier,
                    name: name ?? discoveredPeripherals[idx].name,
                    rssi: discoveredPeripherals[idx].rssi,
                    lastSeen: now,
                    advertisement: discoveredPeripherals[idx].advertisement ?? emptyAdvertisement
                )
            } else {
                resolvedId = identifier
                discoveredPeripherals.append(
                    Peripheral(
                        id: resolvedId,
                        cbIdentifier: cbIdentifier,
                        name: name,
                        rssi: nil,
                        lastSeen: now,
                        advertisement: emptyAdvertisement
                    )
                )
            }

            cbPeripherals[resolvedId] = cbPeripheral
            didMutatePeripherals = true

            // Seed connection state after the live reference is registered. Do not reconnect here.
            let connectionState: ConnectionState?
            switch cbPeripheral.state {
            case .connected:
                connectionState = .connected
                reconnectEnabled.insert(resolvedId)
            case .connecting:
                connectionState = .connecting
                reconnectEnabled.insert(resolvedId)
            case .disconnecting:
                connectionState = .disconnecting
            case .disconnected:
                connectionState = nil
            @unknown default:
                connectionState = nil
            }

            if let connectionState {
                connectionStates[resolvedId] = connectionState
                broadcast(
                    ConnectionStateChange(peripheralId: resolvedId, state: connectionState),
                    to: connectionStateChangesContinuations
                )
            }

            // Surface each restored peripheral on the lightweight discovery feed so subscribers
            // that only listen to `peripheralDiscoveries` still learn about restored devices.
            broadcast(
                PeripheralDiscoveryEvent(cbPeripheral: cbPeripheral, advertisement: emptyAdvertisement, rssi: 0),
                to: discoveryContinuations
            )
        }

        if didMutatePeripherals {
            broadcast(discoveredPeripherals, to: peripheralsContinuations)
        }

        // Resume a scan that was active at termination. If the central is not yet powered on
        // (willRestoreState can precede the poweredOn state update), stash the filter and resume
        // from handleCentralManagerStateUpdate once powered on.
        if let restoredScanServices {
            resumeRestoredScan(
                services: restoredScanServices,
                options: RestoredScanOptions(options: restoredScanOptions)
            )
        }
    }

    /// Issues `scanForPeripherals` for a restored service filter, or defers until powered on.
    private func resumeRestoredScan(services: [CBUUID], options: RestoredScanOptions?) {
        guard let centralManager else {
            pendingRestoredScanServices = services
            pendingRestoredScanOptions = options
            return
        }

        guard centralManager.state == .poweredOn else {
            pendingRestoredScanServices = services
            pendingRestoredScanOptions = options
            log?.debug(tags: [.category(.scanning)], "Deferred restored scan until powered on")
            return
        }

        pendingRestoredScanServices = nil
        pendingRestoredScanOptions = nil
        centralManager.scanForPeripherals(withServices: services, options: options?.options)
        if centralManager.isScanning {
            log?.info(tags: [.category(.scanning)], "Restored scan resumed with services: \(services)")
            updateState()
        } else {
            log?.warn(tags: [.category(.scanning)], "Failed to resume restored scan")
        }
    }

    func handleCentralManagerStateUpdate() {
        guard let centralManager else { return }

        log?.debug("centralManagerDidUpdateState: \(centralManager.state.rawValue)")

        switch centralManager.state {
        case .poweredOn:
            refreshPeripherals()
            if let services = pendingRestoredScanServices {
                resumeRestoredScan(services: services, options: pendingRestoredScanOptions)
            }
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
        for task in reconnectTasks.values { task.cancel() }
        reconnectTasks.removeAll()
        reconnectAttempts.removeAll()
        reconnectEnabled.removeAll()
        intentionalDisconnects.removeAll()
        pendingRestoredScanServices = nil
        pendingRestoredScanOptions = nil
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
    /// Optimistically broadcasts `.connecting` before the CoreBluetooth call, then issues the
    /// connection request. The actual `.connected` or `.failed` callback arrives later via the
    /// delegate pipeline.
    ///
    /// - Parameter id: The ``Peripheral/id`` of a previously discovered peripheral.
    /// - Parameter autoReconnect: When `true`, the OS auto-reconnect option is passed and the
    ///   library ladder may arm on failure. When `false`, reconnection is suppressed entirely.
    /// - Throws: ``PeripheralError/notFound`` if no live `CBPeripheral` is registered for `id` (a stale snapshot).
    /// - Throws: ``PeripheralError/bluetoothUnavailable`` if Bluetooth has not been set up.
    func connect(id: String, autoReconnect: Bool = true) throws {
        guard let centralManager else {
            log?.warn(tags: [.peripheral(id)], "Attempted to connect without a central manager")
            throw PeripheralError.bluetoothUnavailable
        }
        
        guard let cbPeripheral = cbPeripherals[id] else {
            throw PeripheralError.notFound
        }
        
        if autoReconnect {
            reconnectEnabled.insert(id)
        } else {
            reconnectEnabled.remove(id)
        }
        intentionalDisconnects.remove(id)
        connectionStates[id] = .connecting
        broadcast(ConnectionStateChange(peripheralId: id, state: .connecting), to: connectionStateChangesContinuations)
        
        var options: [String: Any]?
        if #available(macOS 14.0, iOS 17.0, *) {
            options = autoReconnect ? [CBConnectPeripheralOptionEnableAutoReconnect: true] : nil
        }
        centralManager.connect(cbPeripheral, options: options)
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
        
        // Reset auto-reconnect since this was an explicit disconnect
        intentionalDisconnects.insert(id)
        reconnectEnabled.remove(id)
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
        reconnectAttempts[id] = nil
        
        connectionStates[id] = .disconnecting
        broadcast(ConnectionStateChange(peripheralId: id, state: .disconnecting), to: connectionStateChangesContinuations)
        centralManager.cancelPeripheralConnection(cbPeripheral)
    }

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
        
        clearReconnectState(for: id)
        
        connectionStates[id] = .connected
        log?.info(tags: [.peripheral(id), .category(.connection)], "Peripheral connected")
        broadcast(ConnectionStateChange(peripheralId: id, state: .connected), to: connectionStateChangesContinuations)
    }

    private func handleDidDisconnect(_ payload: ConnectionPayload) {
        guard let id = id(for: payload.peripheral) else {
            log?.warn(tags: [.category(.connection)], "didDisconnect for unknown peripheral — dropped")
            return
        }
        
        if intentionalDisconnects.remove(id) != nil {
            // Contract: `.disconnected(reason:)` carries `nil` for a clean, app-initiated disconnect.
            // CoreBluetooth can still deliver a benign cancellation-style error on-device for an
            // explicit `cancelPeripheralConnection`, so we intentionally ignore `payload.error` here
            // and always report a clean disconnect — otherwise the app/Demo would misclassify an
            // intentional disconnect as an error drop.
            let state: ConnectionState = .disconnected(reason: nil)
            connectionStates[id] = state
            log?.info(tags: [.peripheral(id), .category(.connection)], "Peripheral disconnected (explicit)")
            
            broadcast(ConnectionStateChange(peripheralId: id, state: state), to: connectionStateChangesContinuations)
            
            return
        }
        
        if payload.isReconnecting {
            // Defensively cancel any pending library ladder so Tier 0 (system) and Tier 1
            // (library) cannot overlap under odd callback ordering.
            reconnectTasks[id]?.cancel()
            reconnectTasks[id] = nil

            connectionStates[id] = .reconnecting(source: .system, attempt: nil, nextRetryAt: nil)
            log?.info(tags: [.peripheral(id), .category(.connection)], "System auto-reconnect in progress")
            
            broadcast(ConnectionStateChange(peripheralId: id, state: .reconnecting(source: .system, attempt: nil, nextRetryAt: nil)), to: connectionStateChangesContinuations)
            
            return
        }
        
        let mappedError: PeripheralError? = payload.error.map { ($0 as? CBError).map(PeripheralError.fromCBError) ?? .unknown }
        let state: ConnectionState = .disconnected(reason: mappedError)
        connectionStates[id] = state
        
        if let error = mappedError {
            log?.warn(tags: [.peripheral(id), .category(.connection)], "Peripheral disconnected with error: \(error)")
        } else {
            log?.info(tags: [.peripheral(id), .category(.connection)], "Peripheral disconnected")
        }
        
        broadcast(ConnectionStateChange(peripheralId: id, state: state), to: connectionStateChangesContinuations)
        armReconnect(id: id)
    }

    private func handleDidFailToConnect(_ payload: ConnectionPayload) {
        guard let id = id(for: payload.peripheral) else {
            log?.warn(tags: [.category(.connection)], "didFailToConnect for unknown peripheral — dropped")
            return
        }
        
        let mappedError: PeripheralError? = payload.error.map { ($0 as? CBError).map(PeripheralError.fromCBError) ?? .unknown }
        let state: ConnectionState = .failed(reason: mappedError)
        connectionStates[id] = state
        
        log?.warn(tags: [.peripheral(id), .category(.connection)], "Peripheral connection failed with error: \(mappedError ?? .unknown)")
        
        broadcast(ConnectionStateChange(peripheralId: id, state: state), to: connectionStateChangesContinuations)
        armReconnect(id: id)
    }

    // MARK: - Reconnection

    private func armReconnect(id: String) {
        guard reconnectEnabled.contains(id) else { return }

        let attempts = reconnectAttempts[id] ?? 0
        guard reconnectPolicy.maxAttempts > 0, attempts < reconnectPolicy.maxAttempts else {
            // Give-up clears in-flight ladder bookkeeping only. `reconnectEnabled` is deliberately
            // retained so reconnection intent survives until an explicit `disconnect` — a later
            // unexpected drop must start a fresh ladder from attempt 1.
            clearReconnectState(for: id)
            log?.info(tags: [.peripheral(id), .category(.connection)], "Reconnect attempts exhausted")
            
            return
        }

        reconnectAttempts[id] = attempts + 1
        scheduleReconnect(id: id, attempt: attempts + 1)
    }

    private func scheduleReconnect(id: String, attempt: Int) {
        reconnectTasks[id]?.cancel()

        // `ReconnectPolicy` is public and unvalidated; collapse any non-finite field (`nan`/`inf`)
        // to a safe value here. Beyond the UInt64 conversion below, a non-finite `jitter` would also
        // trap `Double.random(in: -jitter...jitter)` ("Range requires lowerBound <= upperBound").
        let initial = reconnectPolicy.initialDelay.isFinite ? max(0, reconnectPolicy.initialDelay) : 0
        let maxDelay = reconnectPolicy.maxDelay.isFinite ? max(initial, reconnectPolicy.maxDelay) : initial
        let jitter = reconnectPolicy.jitter.isFinite ? min(max(reconnectPolicy.jitter, 0), 1) : 0

        let baseDelay = min(initial * pow(2, Double(attempt - 1)), maxDelay)
        let jittered = baseDelay * (1 + Double.random(in: -jitter...jitter))
        // `ReconnectPolicy` is public and its fields are unvalidated, so a caller could supply
        // non-finite values (`nan`/`inf`). Collapse those to zero here so the `UInt64` nanosecond
        // conversion below cannot trap at runtime.
        let delaySeconds = jittered.isFinite ? max(0, jittered) : 0

        // Clamp the nanosecond conversion to `UInt64` range to avoid an overflow trap for very
        // large (but finite) configured delays.
        let nanosDouble = (delaySeconds * 1_000_000_000).rounded()
        let sleepNanos: UInt64 = nanosDouble >= Double(UInt64.max) ? .max : UInt64(nanosDouble)

        let nextRetryAt = Date().addingTimeInterval(delaySeconds)
        connectionStates[id] = .reconnecting(source: .library, attempt: attempt, nextRetryAt: nextRetryAt)
        broadcast(ConnectionStateChange(peripheralId: id, state: .reconnecting(source: .library, attempt: attempt, nextRetryAt: nextRetryAt)), to: connectionStateChangesContinuations)

        reconnectTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: sleepNanos)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard let self, !Task.isCancelled else {
                return
            }
            
            await self.performReconnect(id: id, attempt: attempt)
        }
    }

    private func performReconnect(id: String, attempt: Int) {
        guard !Task.isCancelled,
              reconnectAttempts[id] == attempt,
              case .reconnecting(_, let currentAttempt?, _) = connectionStates[id],
              currentAttempt == attempt
        else {
            return
        }
        
        do {
            try connect(id: id, autoReconnect: true)
        } catch {
            let reason = (error as? PeripheralError) ?? .unknown
            clearReconnectState(for: id)
            let state: ConnectionState = .failed(reason: reason)
            connectionStates[id] = state
            log?.warn(tags: [.peripheral(id), .category(.connection)], "Reconnect attempt failed: \(reason)")
            broadcast(ConnectionStateChange(peripheralId: id, state: state), to: connectionStateChangesContinuations)
        }
    }
    
    private func clearReconnectState(for id: String) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
        reconnectAttempts[id] = nil
        intentionalDisconnects.remove(id)
    }

    /// Test-only hook
    func setReconnectPolicy(_ policy: ReconnectPolicy) {
        reconnectPolicy = policy
    }

    /// Test-only hook: injects a disconnect event with the specified `isReconnecting` flag,
    /// routing through the same `handleDidDisconnect(_:)` path as a real delegate callback.
    ///
    /// Needed because CoreBluetoothMock hardcodes `isReconnecting: true` after any connect
    /// with `CBConnectPeripheralOptionEnableAutoReconnect`, making it impossible to simulate
    /// an OS give-up (`isReconnecting: false`) through the mock's public API. Tests that need
    /// `isReconnecting: false` (OS give-up → Tier-1 ladder, or unexpected drop without the
    /// OS option) inject via this hook instead.
    func testInjectDisconnect(for id: String, isReconnecting: Bool, error: Error? = nil) {
        guard let cbPeripheral = cbPeripherals[id] else { return }
        let payload = ConnectionPayload(peripheral: cbPeripheral, isReconnecting: isReconnecting, error: error)
        handleDidDisconnect(payload)
    }

    /// Test-only hook: runs the same peripheral invalidation as a Bluetooth reset/unauthorized path.
    func testInvalidatePeripherals() {
        invalidatePeripherals()
    }

    /// Test-only hook: whether `id` is currently marked as an intentional disconnect.
    func testContainsIntentionalDisconnect(_ id: String) -> Bool {
        intentionalDisconnects.contains(id)
    }

    /// Test-only hook: seeds intentional-disconnect intent without going through `disconnect(id:)`.
    func testSeedIntentionalDisconnect(_ id: String) {
        intentionalDisconnects.insert(id)
    }

    /// Test-only hook: drives restoration with a hand-built CoreBluetooth restore dictionary,
    /// routing through `process(.willRestore)` the same way ``BluetoothDelegateShim`` would.
    ///
    /// Needed because CoreBluetoothMock cannot synthesize `willRestoreState`.
    func testInvokeWillRestoreState(_ state: [String: Any]) {
        process(.willRestore(RestorationPayload(state: state)))
    }

    /// Test-only hook: builds a restoration dictionary from actor-owned live peripherals and
    /// drives ``testInvokeWillRestoreState(_:)``. Keeps non-`Sendable` `CBPeripheral` references
    /// inside the actor isolation boundary.
    func testInvokeWillRestoreState(
        peripheralIds: [String],
        scanServices: [CBUUID]? = nil,
        scanOptions: [String: Any]? = nil
    ) {
        var state: [String: Any] = [:]
        // Avoid compactMap/closure patterns the region-based isolation checker cannot analyze
        // for non-Sendable CBPeripheral values.
        var peripherals: [CBPeripheral] = []
        for id in peripheralIds {
            if let peripheral = cbPeripherals[id] {
                peripherals.append(peripheral)
            }
        }
        if !peripherals.isEmpty {
            state[CBCentralManagerRestoredStatePeripheralsKey] = peripherals
        }
        if let scanServices {
            state[CBCentralManagerRestoredStateScanServicesKey] = scanServices
        }
        if let scanOptions {
            state[CBCentralManagerRestoredStateScanOptionsKey] = scanOptions
        }
        testInvokeWillRestoreState(state)
    }

    /// Test-only hook: whether `id` is currently in ``reconnectEnabled``.
    func testIsReconnectEnabled(_ id: String) -> Bool {
        reconnectEnabled.contains(id)
    }

    /// Test-only hook: whether a live `CBPeripheral` is registered for `id`.
    func testContainsCBPeripheral(_ id: String) -> Bool {
        cbPeripherals[id] != nil
    }

    /// Test-only hook: whether the central is currently scanning.
    func testIsScanning() -> Bool {
        centralManager?.isScanning == true
    }

    /// Test-only hook: service filter stashed when a restored scan was deferred until powered on.
    func testPendingRestoredScanServices() -> [CBUUID]? {
        pendingRestoredScanServices
    }

    /// Test-only hook: restore identifier captured on first ``ensureInitialized`` call.
    func testRestoreIdentifier() -> String? {
        restoreIdentifier
    }

    /// Test-only hook: overwrites the stored restore identifier (process-lifetime actor may already
    /// have been initialized by an earlier test without one).
    func testSetRestoreIdentifier(_ id: String?) {
        restoreIdentifier = id
    }

    /// Test-only hook: clears discovery snapshots and connection intent so a subsequent restore can
    /// exercise the cold-relaunch (append-new) identity branch, while keeping live `CBPeripheral`
    /// references available for ``testInvokeWillRestoreState(peripheralIds:scanServices:scanOptions:)``.
    func testClearDiscoveredSnapshotsPreservingLiveReferences() {
        discoveredPeripherals.removeAll()
        connectionStates.removeAll()
        reconnectEnabled.removeAll()
        pendingRestoredScanServices = nil
        pendingRestoredScanOptions = nil
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
        let payload = ConnectionPayload(peripheral: peripheral, isReconnecting: false, error: nil)
        eventContinuation.yield(.connected(payload))
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let payload = ConnectionPayload(peripheral: peripheral, isReconnecting: false, error: error)
        eventContinuation.yield(.connectFailed(payload))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        let payload = ConnectionPayload(peripheral: peripheral, isReconnecting: isReconnecting, error: error)
        eventContinuation.yield(.disconnected(payload))
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // First callback on relaunch when a restore identifier was used. Ferry the non-Sendable
        // restoration dictionary across the actor hop; extraction happens inside the actor.
        eventContinuation.yield(.willRestore(RestorationPayload(state: dict)))
    }
}
