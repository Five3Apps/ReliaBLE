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
/// CoreBluetooth invokes delegate methods serially on its dispatch queue. The nonisolated delegate
/// shim (``BluetoothDelegateShim`` or ``RestoringBluetoothDelegateShim``) forwards each callback
/// through ``DelegateEventForwarder`` into a single `AsyncStream`, and ``BluetoothActor`` drains
/// them with a single consumer so the original callback ordering is preserved — independent
/// per-callback `Task`s could be reordered before reaching the actor.
private enum DelegateEvent: Sendable {
    case stateUpdate
    case discovered(DiscoveryPayload)
    case connected(ConnectionPayload)
    case disconnected(ConnectionPayload)
    case connectFailed(ConnectionPayload)
    case willRestore(RestorationPayload)
}

// MARK: - Teardown Boxes

/// Nonisolated box so the actor's nonisolated `deinit` may finish the delegate-event pipeline.
fileprivate final class EventPipeline: @unchecked Sendable {
    fileprivate let stream: AsyncStream<DelegateEvent>
    fileprivate let continuation: AsyncStream<DelegateEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(
            of: DelegateEvent.self,
            bufferingPolicy: .unbounded
        )
    }

    func finish() { continuation.finish() }
}

/// Thread-safe registry of unstructured task handles (reconnect ladder sleeps).
fileprivate final class TaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]

    func insert(_ id: String, _ task: Task<Void, Never>) {
        lock.lock()
        let previous = tasks[id]
        tasks[id] = task
        lock.unlock()
        previous?.cancel()
    }

    func cancel(_ id: String) {
        lock.lock()
        let task = tasks.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
    }

    func cancelAll() {
        lock.lock()
        let all = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        for task in all { task.cancel() }
    }
}

// MARK: - BluetoothActor

/// Actor that serializes all CoreBluetooth interactions for a single ``ReliaBLEManager`` stack.
///
/// All mutable BLE state—`CBCentralManager`, per-subscriber `AsyncStream` continuations, and
/// discovered peripherals—are owned exclusively by this actor. Each manager owns its own instance.
///
/// Delegate callbacks arrive on CoreBluetooth's internal queue and are yielded into
/// ``EventPipeline`` by the nonisolated shim via ``DelegateEventForwarder``.
actor BluetoothActor {

    // MARK: - Nonisolated Teardown

    /// Nonisolated box so `deinit` may finish the pipeline without touching actor-isolated state.
    private nonisolated let eventPipeline = EventPipeline()
    /// Nonisolated box so `deinit` may cancel reconnect tasks without touching actor-isolated state.
    private nonisolated let taskRegistry = TaskRegistry()

    // MARK: - Actor-Isolated State

    private let centralManagerQueue = DispatchQueue(label: "com.five3apps.relia-ble.bluetoothmanager", qos: .userInitiated)

    var centralManager: CBCentralManager?
    /// Retained for the central's weak delegate; concrete type is a non-restoring or restoring shim.
    private var delegateShim: (any CBCentralManagerDelegate)?

    /// Drains delegate callbacks in order from ``eventPipeline``.
    private var delegateEventTask: Task<Void, Never>?

    /// Once true, the actor is dead — ops no-op / throw and no second central can be created.
    private var isShutdown = false

    /// Tracks whether ``ensureCentralManager()`` has run at least once so the initial
    /// authorization-derived state is broadcast even when no central is created.
    private var hasEnsuredOnce = false

    /// Continuations for in-flight ``authorize()`` calls awaiting an authorization decision, keyed by a
    /// per-call id so a cancelled call can resume just its own continuation. All pending continuations are
    /// resumed together once `CBCentralManager.authorization` resolves away from `.notDetermined`.
    private var authorizationContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]

    /// Continuations for in-flight ``waitUntilPoweredOn()`` calls parked on a transient radio state
    /// (`.resetting` / `.unknown`), keyed by a per-call UUID so a cancelled call can resume just its own
    /// continuation. All pending continuations are resumed together from ``resolvePoweredOnWaiters()`` on
    /// the next central state update.
    private var poweredOnContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]

    /// Continuation for a parked ``startScanning()`` call awaiting a usable radio. There is at most one
    /// pending scan at a time, so a single slot suffices.
    private var scanWaiterContinuation: CheckedContinuation<Void, Error>?

    /// Service filter requested by the currently parked scan waiter, or `nil` if none is parked.
    private var scanWaiterServices: [CBUUID]?

    /// The restored-scan deferral (``pendingRestoredScanServices``) and this scan waiter are two
    /// distinct mechanisms kept deliberately separate rather than collapsed into one (plan D-2 open
    /// item): the restored-scan stash is driven by ``handleCentralManagerStateUpdate()``'s `.poweredOn`
    /// handling, whereas an app ``startScanning(services:)`` waiter is driven by
    /// ``resolvePoweredOnWaiters()``. They never both fire because every app scan clears
    /// ``pendingRestoredScanServices`` — the app-requested filter wins D-2 precedence. Collapsing
    /// them would couple the restore deferral to the app-visible await state for no benefit.

    /// The current Bluetooth state.
    var currentBluetoothState: BluetoothState = .unknown

    var log: LoggingService?

    /// Value snapshots of all discovered peripherals, keyed implicitly by ``DiscoveredPeripheral/id``.
    var discoveredPeripherals: [DiscoveredPeripheral] = []

    /// Live `CBPeripheral` references keyed by ``DiscoveredPeripheral/id``.
    ///
    /// This mutable, non-`Sendable` reference map never escapes the actor. Snapshots and handles carry only an
    /// `id`; operations that need the live peripheral look it up here.
    private var cbPeripherals: [String: CBPeripheral] = [:]

    // MARK: - AsyncStream Broadcaster State
    //
    // One continuation per active subscriber, keyed by a per-subscription UUID. Mutated only on
    // the actor's serial executor: the stream factories register via `Task { await self.register(...) }`,
    // the broadcast sites iterate to `yield`, and each `onTermination` handler prunes its own entry.
    // Registration / onTermination Tasks capture `self` strongly while the stream is live — deliberate
    // so a consumed stream keeps the stack alive (see design: stream-retains-actor).

    private var stateContinuations: [UUID: AsyncStream<BluetoothState>.Continuation] = [:]
    private var discoveryContinuations: [UUID: AsyncStream<PeripheralDiscoveryEvent>.Continuation] = [:]
    private var peripheralsContinuations: [UUID: AsyncStream<[DiscoveredPeripheral]>.Continuation] = [:]

    /// Per-peripheral connection states, keyed by ``Peripheral/id``.
    var connectionStates: [String: ConnectionState] = [:]

    private var connectionStateChangesContinuations: [UUID: AsyncStream<ConnectionStateChange>.Continuation] = [:]

    private var reconnectPolicy: ReconnectPolicy
    /// Stable CoreBluetooth restore identifier; `nil` disables state restoration.
    private var restoreIdentifier: String?
    /// Idle interval (seconds) before a per-peripheral link with no demand is torn down. `0` tears
    /// down as soon as demand reaches zero. Mutated by the test-only ``setIdleDisconnectInterval(_:)`` hook.
    private var idleDisconnectInterval: TimeInterval
    /// Scan filter restored via `willRestoreState` when the central was not yet powered on.
    private var pendingRestoredScanServices: [CBUUID]?
    private var pendingRestoredScanOptions: RestoredScanOptions?
    private var reconnectEnabled: Set<String> = []
    private var intentionalDisconnects: Set<String> = []
    private var reconnectAttempts: [String: Int] = [:]

    // MARK: - Initialization

    /// Bridge to the owning manager's handle registry.
    ///
    /// The actor resolves identity and owns live references; the registry owns ``Peripheral`` instances. Every
    /// call into this bridge happens on the actor's executor, before the corresponding broadcast — see the
    /// apply-before-broadcast invariant on ``resolveAndUpsertDiscovered(cbPeripheral:name:rssi:lastSeen:advertisement:)``.
    ///
    /// This reference must never lead back to the manager strongly; see ``PeripheralRegistryBridge``.
    private let registry: PeripheralRegistryBridge

    /// Creates an actor with configuration only — no `CBCentralManager` is created here.
    init(
        log: LoggingService,
        reconnectPolicy: ReconnectPolicy,
        restoreIdentifier: String?,
        idleDisconnectInterval: TimeInterval,
        registry: PeripheralRegistryBridge
    ) {
        self.log = log
        self.reconnectPolicy = reconnectPolicy
        self.restoreIdentifier = restoreIdentifier
        if !idleDisconnectInterval.isFinite || idleDisconnectInterval < 0 {
            self.idleDisconnectInterval = 5.0
        } else {
            self.idleDisconnectInterval = idleDisconnectInterval
        }
        self.registry = registry
    }

    deinit {
        eventPipeline.finish()
        taskRegistry.cancelAll()
    }

    /// Terminal teardown for tests/harness. Clears volatile state only — does **not** touch
    /// persisted reconnect-intent `UserDefaults`.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true

        eventPipeline.finish()
        taskRegistry.cancelAll()
        delegateEventTask?.cancel()
        delegateEventTask = nil

        for continuation in stateContinuations.values { continuation.finish() }
        for continuation in discoveryContinuations.values { continuation.finish() }
        for continuation in peripheralsContinuations.values { continuation.finish() }
        for continuation in connectionStateChangesContinuations.values { continuation.finish() }
        stateContinuations.removeAll()
        discoveryContinuations.removeAll()
        peripheralsContinuations.removeAll()
        connectionStateChangesContinuations.removeAll()

        let pendingAuth = authorizationContinuations
        authorizationContinuations.removeAll()
        for continuation in pendingAuth.values {
            continuation.resume(throwing: CancellationError())
        }

        let pendingPoweredOn = poweredOnContinuations
        poweredOnContinuations.removeAll()
        for continuation in pendingPoweredOn.values {
            continuation.resume(throwing: PeripheralError.bluetoothUnavailable)
        }

        if let continuation = scanWaiterContinuation {
            scanWaiterContinuation = nil
            scanWaiterServices = nil
            continuation.resume(throwing: PeripheralError.bluetoothUnavailable)
        }

        centralManager = nil
        delegateShim = nil
        cbPeripherals.removeAll()
        discoveredPeripherals.removeAll()
        clearConnectionStates()
        // Drop interned handles along with the stack they belong to. Handles the app still holds keep working,
        // orphaned, throwing `.bluetoothUnavailable`. A radio reset (`invalidatePeripherals`) deliberately does not
        // do this — a handle must survive one with its metadata intact.
        registry.removeAllHandles()
        reconnectEnabled.removeAll()
        intentionalDisconnects.removeAll()
        reconnectAttempts.removeAll()
        pendingRestoredScanServices = nil
        pendingRestoredScanOptions = nil
    }

    // MARK: - Event Streams

    /// Returns a fresh `AsyncStream` of Bluetooth state changes for a single subscriber.
    ///
    /// Each call mints an independent stream; multiple subscribers are supported by design. The
    /// current state is replayed as the first element (`.bufferingNewest(1)`, latest-wins), so a
    /// new subscriber always observes the current state without waiting for the next broadcast.
    nonisolated func stateStream() -> AsyncStream<BluetoothState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await self.register(stateContinuation: continuation) }
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
            Task { await self.register(discoveryContinuation: continuation) }
        }
    }

    /// Returns a fresh `AsyncStream` of the current discovered-peripherals list for a single
    /// subscriber.
    ///
    /// The current list is replayed as the first element (`.bufferingNewest(1)`, latest-wins), so
    /// a new subscriber immediately observes the peripherals already discovered.
    nonisolated func discoveredPeripheralsStream() -> AsyncStream<[DiscoveredPeripheral]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await self.register(peripheralsContinuation: continuation) }
        }
    }

    /// Returns a fresh `AsyncStream` of connection-state changes for a single subscriber.
    ///
    /// Each call mints an independent stream. This feed does **not** replay a value on
    /// subscription — a subscriber only receives state changes that occur after it registers,
    /// mirroring ``peripheralDiscoveriesStream()``.
    nonisolated func connectionStateChangesStream() -> AsyncStream<ConnectionStateChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(BluetoothActor.discoveryBufferLimit)) { continuation in
            Task { await self.register(connectionStateChangeContinuation: continuation) }
        }
    }

    // MARK: - Continuation Registration
    //
    // Registration runs as a single, indivisible actor job: the replay-yield, dictionary insert,
    // and `onTermination` assignment cannot interleave with a broadcast. The only residual gap is
    // the window between `AsyncStream` creation and this job starting — an event emitted then is
    // missed by a *new* (replay-less) `peripheralDiscoveries` subscriber. Accepted and documented.

    private func register(stateContinuation continuation: AsyncStream<BluetoothState>.Continuation) {
        guard !isShutdown else { continuation.finish(); return }
        let id = UUID()
        continuation.yield(currentBluetoothState)
        stateContinuations[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeStateContinuation(id) }
        }
    }

    private func register(discoveryContinuation continuation: AsyncStream<PeripheralDiscoveryEvent>.Continuation) {
        guard !isShutdown else { continuation.finish(); return }
        let id = UUID()
        discoveryContinuations[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeDiscoveryContinuation(id) }
        }
    }

    private func register(peripheralsContinuation continuation: AsyncStream<[DiscoveredPeripheral]>.Continuation) {
        guard !isShutdown else { continuation.finish(); return }
        let id = UUID()
        continuation.yield(discoveredPeripherals)
        peripheralsContinuations[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.removePeripheralsContinuation(id) }
        }
    }

    private func removeStateContinuation(_ id: UUID) { stateContinuations[id] = nil }
    private func removeDiscoveryContinuation(_ id: UUID) { discoveryContinuations[id] = nil }
    private func removePeripheralsContinuation(_ id: UUID) { peripheralsContinuations[id] = nil }

    private func register(connectionStateChangeContinuation continuation: AsyncStream<ConnectionStateChange>.Continuation) {
        guard !isShutdown else { continuation.finish(); return }
        let id = UUID()
        connectionStateChangesContinuations[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeConnectionStateChangeContinuation(id) }
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

    /// Creates the central manager if Bluetooth is currently authorized (`.allowedAlways`) and one
    /// does not already exist. Idempotent and actor-serialized.
    ///
    /// Creating the central remains gated on existing `.allowedAlways` authorization, preserving
    /// the lazy-permission contract: the iOS prompt only appears when the integrating app calls
    /// ``ReliaBLEManager/authorizeBluetooth()``. An operation issued after authorization is granted
    /// out-of-band still finds a live manager because every call retries creation.
    ///
    /// Stream and snapshot getters do **not** call this — only operational methods do.
    func ensureCentralManager() {
        guard !isShutdown else { return }

        let firstEnsure = !hasEnsuredOnce
        hasEnsuredOnce = true

        var createdManager = false

        if centralManager == nil, CBCentralManager.authorization == .allowedAlways {
            setupCentralManager()
            createdManager = true
        }

        if firstEnsure || createdManager {
            updateState()
        }
    }

    // MARK: - Central Manager Setup

    func setupCentralManager() {
        guard !isShutdown else { return }
        guard centralManager == nil else { return }

        log?.info("Initializing CBCentralManager")

        // Consumer-before-factory: start draining the (already-created) pipeline first so a
        // synchronous `willRestoreState` inside the factory call is not lost.
        //
        // Shim choice is gated by the same `restoreIdentifier != nil` condition that adds
        // `CBCentralManagerOptionRestoreIdentifierKey` below, so delegate and options never
        // disagree. Two peer types (not inheritance) are required for *both* stacks:
        //
        // - **Real CoreBluetooth (ObjC):** uses `responds(to:)` and logs API MISUSE when the
        //   delegate implements `willRestoreState` without a restore identifier. The non-restoring
        //   shim must not declare that method at all (same pattern Nordic uses in
        //   `CBMCentralManagerNative`).
        // - **CoreBluetoothMock (Swift):** `CBMCentralManagerMock` calls
        //   `delegate?.centralManager(_:willRestoreState:)` **unconditionally** via the Swift
        //   protocol (extension default is a no-op). Each peer class needs its own witness table
        //   so the restoring type's implementation is dispatched; a subclass of a base that omits
        //   the method would still hit the empty protocol-extension default.
        let forwarder = DelegateEventForwarder(eventContinuation: eventPipeline.continuation)
        let shim: any CBCentralManagerDelegate = if restoreIdentifier != nil {
            RestoringBluetoothDelegateShim(forwarder: forwarder)
        } else {
            BluetoothDelegateShim(forwarder: forwarder)
        }
        delegateShim = shim

        if delegateEventTask == nil {
            delegateEventTask = Task { [weak self] in
                guard let self else { return }
                for await event in self.eventPipeline.stream {
                    await self.process(event)
                }
            }
        }

        // Use CBCentralManagerFactory for consistency between normal and test targets.
        // `forceMock: true` is load-bearing for the ReliaBLEMock test target — do not remove.
        centralManager = CBCentralManagerFactory.instance(
            delegate: shim,
            queue: centralManagerQueue,
            options: centralManagerCreationOptions(),
            forceMock: true
        )
    }

    /// Builds the options dictionary passed to the central-manager factory.
    ///
    /// Factored out of ``setupCentralManager()`` so unit tests can assert the restore key is
    /// included without creating a central. When a restore identifier is configured and
    /// `CBMCentralManagerMock.simulateStateRestoration` is set, central init delivers
    /// `willRestoreState` faithfully (see the test harness cold-relaunch helpers).
    private func centralManagerCreationOptions() -> [String: Any]? {
        guard let restoreIdentifier else { return nil }
        return [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
    }

    /// Drains a single delegate event on the actor, preserving CoreBluetooth's callback order.
    private func process(_ event: DelegateEvent) {
        guard !isShutdown else { return }

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
        guard !isShutdown else { throw PeripheralError.bluetoothUnavailable }

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

    // MARK: - PoweredOn

    /// Suspends until the central manager is in a usable state, or throws a typed error for
    /// terminal states. Mirrors the authorization-continuation pattern.
    ///
    /// - Shut down or no central → ``PeripheralError/bluetoothUnavailable``
    /// - `.poweredOff` → ``PeripheralError/bluetoothPoweredOff``
    /// - `.unsupported` → ``PeripheralError/bluetoothUnsupported``
    /// - `.unauthorized` → ``PeripheralError/bluetoothUnavailable``
    /// - `.resetting` / `.unknown` → parks a continuation until the next state update
    /// - Task cancellation → ``CancellationError``
    ///
    /// - Parameter waiterID: A per-call UUID so the caller (via ``cancelPoweredOnContinuation(_:)``) may
    ///   cancel just this specific wait. The caller is responsible for minting the UUID — typically the
    ///   nonisolated façade's `withTaskCancellationHandler` onCancel.
    func waitUntilPoweredOn(waiterID: UUID) async throws {
        guard !isShutdown else { throw PeripheralError.bluetoothUnavailable }
        guard let centralManager else { throw PeripheralError.bluetoothUnavailable }
        switch centralManager.state {
        case .poweredOn:
            return
        case .poweredOff:
            throw PeripheralError.bluetoothPoweredOff
        case .unsupported:
            throw PeripheralError.bluetoothUnsupported
        case .unauthorized:
            throw PeripheralError.bluetoothUnavailable
        case .resetting, .unknown:
            try await suspendForPoweredOn(waiterID: waiterID)
        @unknown default:
            throw PeripheralError.bluetoothUnavailable
        }
    }

    /// Parks a continuation for ``waitUntilPoweredOn(waiterID:)`` until the radio becomes usable.
    private func suspendForPoweredOn(waiterID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            poweredOnContinuations[waiterID] = continuation
        }
    }

    /// Resolves any pending ``waitUntilPoweredOn()`` calls based on the current radio state.
    ///
    /// Called from ``handleCentralManagerStateUpdate()`` on every state update. Terminal states
    /// fail all waiters; `.poweredOn` resumes them successfully; transient states leave them parked.
    private func resolvePoweredOnWaiters() {
        let hasScanWaiter = scanWaiterContinuation != nil
        guard !poweredOnContinuations.isEmpty || hasScanWaiter else { return }
        guard let centralManager else { return }

        switch centralManager.state {
        case .poweredOn:
            // A parked scan waiter gets its scan issued and completes successfully on power-on.
            if let continuation = scanWaiterContinuation {
                scanWaiterContinuation = nil
                let services = scanWaiterServices
                scanWaiterServices = nil
                beginScan(services: services)
                continuation.resume(returning: ())
            }
            if !poweredOnContinuations.isEmpty {
                let pending = poweredOnContinuations
                poweredOnContinuations.removeAll()
                for continuation in pending.values {
                    continuation.resume(returning: ())
                }
            }
        case .poweredOff:
            failPoweredOnAndScanWaiters(with: PeripheralError.bluetoothPoweredOff)
        case .unsupported:
            failPoweredOnAndScanWaiters(with: PeripheralError.bluetoothUnsupported)
        case .unauthorized:
            failPoweredOnAndScanWaiters(with: PeripheralError.bluetoothUnavailable)
        case .resetting, .unknown:
            return
        @unknown default:
            failPoweredOnAndScanWaiters(with: PeripheralError.bluetoothUnavailable)
        }
    }

    /// Fails every parked ``waitUntilPoweredOn()`` continuation and any parked scan waiter with a
    /// terminal radio-state error.
    private func failPoweredOnAndScanWaiters(with error: PeripheralError) {
        if let continuation = scanWaiterContinuation {
            scanWaiterContinuation = nil
            scanWaiterServices = nil
            continuation.resume(throwing: error)
        }
        if !poweredOnContinuations.isEmpty {
            let pending = poweredOnContinuations
            poweredOnContinuations.removeAll()
            for continuation in pending.values {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Resumes a single pending ``waitUntilPoweredOn()`` continuation with a `CancellationError`,
    /// if still pending. Invoked from a `withTaskCancellationHandler` onCancel.
    func cancelPoweredOnContinuation(_ id: UUID) {
        poweredOnContinuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    // MARK: - Scanning

    /// Starts scanning for peripherals, optionally filtering by specific services.
    ///
    /// Rather than silently no-op'ing when the radio is not yet usable, this waits for a
    /// transient (`.resetting` / `.unknown`) state to resolve and fails fast with a typed
    /// ``PeripheralError`` for terminal states (`.poweredOff`, `.unsupported`, `.unauthorized`).
    ///
    /// A parked scan waiter (on a transient state) has four distinct outcomes, only one of which
    /// throws `CancellationError` (D-2): radio reaches `.poweredOn` (scan starts), `stopScanning()`
    /// is called (waiter completes successfully, no scan), the waiter is superseded by a later
    /// ``startScanning(services:)`` (completes successfully without scanning), or the radio
    /// resolves to a terminal state (throws the matching typed error).
    func startScanning(services: sending [CBUUID]? = nil) async throws {
        guard !isShutdown else {
            log?.warn(tags: [.category(.scanning)], "Attempted to start scan after shutdown")
            throw PeripheralError.bluetoothUnavailable
        }
        guard let centralManager else {
            log?.warn(tags: [.category(.scanning)], "Attempted to start scan without a central manager")
            throw PeripheralError.bluetoothUnavailable
        }

        switch centralManager.state {
        case .poweredOn:
            // An app-requested scan supersedes any deferred restored scan (D-2 filter precedence):
            // clear the stashed filter so a later power-on does not also resume it — CoreBluetooth
            // has a single scan, last writer wins.
            pendingRestoredScanServices = nil
            pendingRestoredScanOptions = nil
            beginScan(services: services)
        case .poweredOff:
            throw PeripheralError.bluetoothPoweredOff
        case .unsupported:
            throw PeripheralError.bluetoothUnsupported
        case .unauthorized:
            throw PeripheralError.bluetoothUnavailable
        case .resetting, .unknown:
            try await parkScanWaiter(services: services)
        @unknown default:
            throw PeripheralError.bluetoothUnavailable
        }
    }

    /// Parks a ``startScanning(services:)`` invocation until the radio resolves, it is superseded
    /// by a newer scan request, ``stopScanning()`` is called, or the calling task is cancelled.
    ///
    /// Supersede semantics: a later ``startScanning(services:)`` completes an earlier parked waiter
    /// successfully without scanning (the newer request owns the single-slot scan; coalescing is not
    /// attempted because the service filters may differ). Clears the deferred restored scan so an
    /// app scan wins filter precedence.
    ///
    /// The waiter is re-driven after resume, re-reading ``centralManager`` and its state, because a
    /// resumed continuation runs on a later actor turn and the radio may have flipped again.
    private func parkScanWaiter(services: sending [CBUUID]?) async throws {
        // A later startScanning supersedes a parked one: resolve the previous waiter successfully.
        if let previous = scanWaiterContinuation {
            scanWaiterContinuation = nil
            scanWaiterServices = nil
            previous.resume(returning: ())
        }

        // An app-requested scan supersedes any deferred restored scan (D-2 filter precedence).
        pendingRestoredScanServices = nil
        pendingRestoredScanOptions = nil

        scanWaiterServices = services
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            scanWaiterContinuation = continuation
        }

        // Resumed. Re-read the radio because it may have flipped since the waiter was resolved.
        guard let centralManager else { throw PeripheralError.bluetoothUnavailable }
        switch centralManager.state {
        case .poweredOn:
            // If ``resolvePoweredOnWaiters()`` already issued the scan, nothing left to do. If this
            // waiter was resolved by ``stopScanning()``, ``scanWaiterServices`` is nil and we must
            // not start a scan. Otherwise issue it now (e.g. after a transient re-park above).
            if scanWaiterServices != nil, centralManager.isScanning == false {
                let services = scanWaiterServices
                scanWaiterServices = nil
                beginScan(services: services)
            }
        case .resetting, .unknown:
            // The radio regressed to a transient state while we held the continuation; re-park
            // only while a scan is still requested. If ``stopScanning()`` resolved this waiter, it
            // cleared ``scanWaiterServices`` — return successfully, no scan, rather than re-parking.
            if scanWaiterServices != nil {
                try await parkScanWaiter(services: scanWaiterServices)
            }
        case .poweredOff:
            throw PeripheralError.bluetoothPoweredOff
        case .unsupported:
            throw PeripheralError.bluetoothUnsupported
        case .unauthorized:
            throw PeripheralError.bluetoothUnavailable
        @unknown default:
            throw PeripheralError.bluetoothUnavailable
        }
    }

    /// Cancels a parked ``startScanning(services:)`` waiter, invoked from a
    /// `withTaskCancellationHandler` onCancel. No-op when no waiter is parked.
    func cancelScanWaiter() {
        guard let continuation = scanWaiterContinuation else { return }
        scanWaiterContinuation = nil
        scanWaiterServices = nil
        continuation.resume(throwing: CancellationError())
    }

    /// Issues `scanForPeripherals` for the given filter and broadcasts the resulting state.
    private func beginScan(services: sending [CBUUID]?) {
        if services == nil || services?.isEmpty == true {
            log?.warn(
                tags: [.category(.scanning)],
                "Scanning with an empty/nil service filter; background scanning requires a non-empty service UUID filter"
            )
        }

        guard let centralManager else { return }
        centralManager.scanForPeripherals(withServices: services, options: nil)

        if centralManager.isScanning {
            log?.info(tags: [.category(.scanning)], "Scanning started with services: \(services ?? [])")
            updateState()
        } else {
            log?.warn(tags: [.category(.scanning)], "Failed to start scanning")
        }
    }

    /// Stops scanning and completes any parked scan waiter. Cancelling is always allowed, so this
    /// performs no radio wait.
    ///
    /// A ``startScanning(services:)`` suspended on a transient state is resolved **successfully**
    /// (void, no scan starts) — the start-then-stop sequence completed as the app requested and is
    /// not an error (D-2).
    func stopScanning() {
        // Complete any parked scan waiter successfully before tearing down the scan.
        if let continuation = scanWaiterContinuation {
            scanWaiterContinuation = nil
            scanWaiterServices = nil
            continuation.resume(returning: ())
        }

        guard !isShutdown else {
            log?.warn(tags: [.category(.scanning)], "Attempted to stop scan after shutdown")
            return
        }
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

    // MARK: - Delegate Entry Points (called via DelegateEventForwarder)

    /// Rehydrates scan and connection state delivered by CoreBluetooth on app relaunch.
    ///
    /// Restored `CBPeripheral`s arrive with no peripheral delegate and must be re-associated into
    /// ``cbPeripherals`` immediately. Connection state is seeded from each peripheral's
    /// `CBPeripheral.state`; no synchronous reconnect is issued (standing connects are OS-held).
    /// Tier-1 reconnect intent is re-armed only for peripherals whose per-connect
    /// `autoReconnect: true` intent was persisted before termination — a connection made with
    /// `autoReconnect: false` is restored (state seeded, reference registered) without re-arming
    /// the library ladder.
    /// If Bluetooth is later reported off/unauthorized, ``invalidatePeripherals()`` clears this
    /// state intentionally.
    ///
    /// Restored peripherals are deliberately **not** emitted on the `peripheralDiscoveries`
    /// advertisement feed — restoration carries no advertisement payload or RSSI, so consumers
    /// learn about restored devices via `discoveredPeripherals` and `connectionStateChanges` only.
    private func handleWillRestoreState(_ payload: RestorationPayload) {
        let restoredPeripherals = payload.state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let restoredScanServices = payload.state[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID]
        let restoredScanOptions = payload.state[CBCentralManagerRestoredStateScanOptionsKey] as? [String: Any]

        log?.info(
            tags: [.category(.scanning)],
            "Restoring BLE state: \(restoredPeripherals.count) peripheral(s), scanServices=\(restoredScanServices ?? [])"
        )

        let now = Date()
        var didMutatePeripherals = false

        // Reconnect intent persisted across launches; only ids in this set are re-armed below.
        let persistedIntent = persistedReconnectIntent()

        for cbPeripheral in restoredPeripherals {
            // Restored peripherals arrive with no delegate; re-associate into actor-owned maps using the same
            // identity rules as discovery — literally the same helper, so the two paths cannot drift and a
            // restored device interns the same handle it had before termination. Peripheral-level GATT callbacks
            // are not yet used by the library, so no `CBPeripheralDelegate` is attached here.
            //
            // `rssi` and `advertisement` are passed as `nil` to invoke the helper's keep-existing merge rule:
            // restoration carries neither, and a device discovered before termination must not have them wiped.
            let resolvedId = resolveAndUpsertDiscovered(
                cbPeripheral: cbPeripheral,
                name: cbPeripheral.name,
                rssi: nil,
                lastSeen: now,
                advertisement: nil
            )

            cbPeripherals[resolvedId] = cbPeripheral
            didMutatePeripherals = true

            // Seed connection state after the live reference is registered. Do not reconnect here.
            // Tier-1 intent is re-armed only when it was persisted at connect time (autoReconnect: true).
            let connectionState: ConnectionState?
            switch cbPeripheral.state {
            case .connected:
                connectionState = .connected
                if persistedIntent.contains(resolvedId) {
                    reconnectEnabled.insert(resolvedId)
                }
            case .connecting:
                connectionState = .connecting
                if persistedIntent.contains(resolvedId) {
                    reconnectEnabled.insert(resolvedId)
                }
            case .disconnecting:
                connectionState = .disconnecting
            case .disconnected:
                connectionState = nil
            @unknown default:
                connectionState = nil
            }

            if let connectionState {
                setConnectionState(connectionState, for: resolvedId)
            }
        }

        if didMutatePeripherals {
            broadcast(discoveredPeripherals, to: peripheralsContinuations)
        }

        // Resume a scan that was active at termination. If the central is not yet powered on
        // (willRestoreState can precede the poweredOn state update), stash the filter and resume
        // from handleCentralManagerStateUpdate once powered on. An empty filter is ignored —
        // background scans require a non-empty service filter, so re-issuing one is useless.
        if let restoredScanServices, !restoredScanServices.isEmpty {
            resumeRestoredScan(
                services: restoredScanServices,
                options: RestoredScanOptions(options: restoredScanOptions)
            )
        } else if restoredScanServices != nil {
            log?.warn(
                tags: [.category(.scanning)],
                "Ignoring restored scan with an empty service filter — background scanning requires a non-empty filter"
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
        resolvePoweredOnWaiters()
    }

    func handlePeripheralDiscovered(
        _ cbPeripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: Int
    ) {
        // Extract the untyped advertisement dictionary into a typed, Sendable snapshot exactly once. The raw
        // `[String: Any]` does not leave this actor; the same `AdvertisementData` feeds both the discovery event
        // and the stored `DiscoveredPeripheral` snapshot.
        let advertisement = AdvertisementData(rawAdvertisementData: advertisementData)

        // Emit lightweight discovery feed.
        // TODO: Implement verbose log level
        broadcast(
            PeripheralDiscoveryEvent(cbPeripheral: cbPeripheral, advertisement: advertisement, rssi: rssi),
            to: discoveryContinuations
        )

        // Identity resolution and the snapshot upsert live in the shared helper, so discovery and state
        // restoration cannot drift apart.
        let resolvedId = resolveAndUpsertDiscovered(
            cbPeripheral: cbPeripheral,
            name: cbPeripheral.name ?? advertisement.localName,
            rssi: rssi,
            lastSeen: Date(),
            advertisement: advertisement
        )

        // Stash the live reference under the resolved id. Never escapes the actor.
        cbPeripherals[resolvedId] = cbPeripheral
        broadcast(discoveredPeripherals, to: peripheralsContinuations)
    }

    /// Resolves the app-facing id for a peripheral, upserts its snapshot into ``discoveredPeripherals``, and
    /// mirrors the merged result onto the interned handle. Returns the resolved id.
    ///
    /// This is the library's **single identity-resolution site**, shared by discovery and state restoration. Those
    /// two paths previously carried near-duplicate copies of these rules, which had already drifted apart; keeping
    /// them together is what guarantees both return the same handle for the same device.
    ///
    /// Resolution is: derive `cbPeripheral.name ?? advertisement.localName ?? cbPeripheral.identifier.uuidString`,
    /// then match an existing entry by `id`, else by `cbIdentifier` (preserving that entry's original `id`, so a
    /// device that renames itself keeps its identity), else append.
    ///
    /// **Merge rule: `nil` means keep.** A `nil` `name`, `rssi`, or `advertisement` preserves the existing value
    /// rather than clearing it, falling back to `nil` (or an empty advertisement) when there is no existing entry.
    /// Discovery always passes real values, so the rule is a no-op there. Restoration depends on it: a restored
    /// peripheral carries no advertisement payload and no RSSI, and wiping those would silently downgrade a device
    /// the app had already discovered — visibly, now that the handle republishes them.
    ///
    /// `lastSeen` is always stamped by the caller. For restoration that means "when the live reference was last
    /// bound" rather than "last heard from", which is why the public property is documented as *last bound or seen*.
    ///
    /// This helper deliberately does **not** broadcast and does **not** emit a ``PeripheralDiscoveryEvent``.
    /// Discovery broadcasts once per advertisement and emits its event before resolution even begins; restoration
    /// broadcasts once after its whole loop and never emits on the advertisement feed. Leaving both to the callers
    /// preserves each of those contracts for free.
    ///
    /// - Important: The handle is updated *before* the caller broadcasts, so a consumer that receives snapshot *N*
    ///   can never read handle metadata older than *N*. Any future change that broadcasts earlier to shave latency
    ///   would break that guarantee.
    private func resolveAndUpsertDiscovered(
        cbPeripheral: CBPeripheral,
        name: String?,
        rssi: Int?,
        lastSeen: Date,
        advertisement: AdvertisementData?
    ) -> String {
        // TODO: FR-8.5 — Unique Identifier from Manufacturing Data.
        // KNOWN LIMITATION: advertised names are not unique. Two distinct physical devices that advertise the same
        // name resolve to the same `identifier` here, so they collapse into a single `discoveredPeripherals` entry
        // and a single `cbPeripherals` slot — the later discovery overwrites the earlier device's live
        // `CBPeripheral`, so `connect(id:)` may target whichever was seen last. FR-8.5 will replace this with a
        // stable identity derived from manufacturing data; until then the dedup key is best-effort. The
        // `cbIdentifier` fallback below only rescues a *single* device whose advertised name changes, not the
        // same-name collision between *different* devices.
        let identifier = cbPeripheral.name
            ?? advertisement?.localName
            ?? cbPeripheral.identifier.uuidString
        let cbIdentifier = cbPeripheral.identifier

        let existingIndex: Int?
        let resolvedId: String
        if let idx = discoveredPeripherals.firstIndex(where: { $0.id == identifier }) {
            existingIndex = idx
            resolvedId = identifier
        } else if let idx = discoveredPeripherals.firstIndex(where: { $0.cbIdentifier == cbIdentifier }) {
            existingIndex = idx
            resolvedId = discoveredPeripherals[idx].id
        } else {
            existingIndex = nil
            resolvedId = identifier
        }

        let existing = existingIndex.map { discoveredPeripherals[$0] }
        let mergedName = name ?? existing?.name
        let mergedRSSI = rssi ?? existing?.rssi
        // `??` is lazily evaluated, so the empty placeholder is only built on the restore-a-never-seen-device path.
        let mergedAdvertisement = advertisement
            ?? existing?.advertisement
            ?? AdvertisementData(rawAdvertisementData: [:])

        let snapshot = DiscoveredPeripheral(
            id: resolvedId,
            cbIdentifier: cbIdentifier,
            name: mergedName,
            rssi: mergedRSSI,
            lastSeen: lastSeen,
            advertisement: mergedAdvertisement,
            registry: registry
        )

        if let existingIndex {
            discoveredPeripherals[existingIndex] = snapshot
        } else {
            log?.debug(tags: [.category(.scanning), .peripheral(resolvedId)], "Adding newly discovered peripheral")
            discoveredPeripherals.append(snapshot)
        }

        // Apply before the caller broadcasts — see the Important note above.
        registry.applyDiscovery(
            id: resolvedId,
            cbIdentifier: cbIdentifier,
            name: mergedName,
            rssi: mergedRSSI,
            lastSeen: lastSeen,
            advertisement: mergedAdvertisement
        )

        return resolvedId
    }

    private func invalidatePeripherals() {
        // The value snapshots hold no CoreBluetooth reference to clear; drop the live registry instead.
        cbPeripherals.removeAll()
        clearConnectionStates()
        taskRegistry.cancelAll()
        reconnectAttempts.removeAll()
        reconnectEnabled.removeAll()
        persistReconnectIntent()
        intentionalDisconnects.removeAll()
        pendingRestoredScanServices = nil
        pendingRestoredScanOptions = nil
        broadcast(discoveredPeripherals, to: peripheralsContinuations)
        log?.debug("Invalidated all peripheral references")
    }

    // MARK: - Persisted Reconnect Intent

    /// `UserDefaults` key for the persisted reconnect-intent set, namespaced by restore identifier.
    ///
    /// `nil` when no ``restoreIdentifier`` is configured — without state restoration there is no
    /// relaunch path that could consume persisted intent, so nothing is written.
    private var reconnectIntentDefaultsKey: String? {
        restoreIdentifier.map { "com.five3apps.relia-ble.reconnect-intent.\($0)" }
    }

    /// Mirrors ``reconnectEnabled`` to `UserDefaults` so per-connect `autoReconnect` intent
    /// survives process death. ``handleWillRestoreState(_:)`` re-arms Tier-1 reconnect only for
    /// restored peripherals present in this persisted set.
    ///
    /// Called after every explicit mutation of ``reconnectEnabled`` (connect, disconnect,
    /// invalidation). Restoration itself only reads the set.
    private func persistReconnectIntent() {
        guard let key = reconnectIntentDefaultsKey else { return }
        UserDefaults.standard.set(Array(reconnectEnabled).sorted(), forKey: key)
    }

    /// Reads the reconnect-intent set persisted by a previous launch (or this one).
    private func persistedReconnectIntent() -> Set<String> {
        guard let key = reconnectIntentDefaultsKey,
              let stored = UserDefaults.standard.stringArray(forKey: key) else { return [] }
        return Set(stored)
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
        guard !isShutdown else {
            log?.warn(tags: [.peripheral(id)], "Attempted to connect after shutdown")
            throw PeripheralError.bluetoothUnavailable
        }
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
        persistReconnectIntent()
        intentionalDisconnects.remove(id)
        setConnectionState(.connecting, for: id)
        
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
        guard !isShutdown else {
            log?.warn(tags: [.peripheral(id)], "Attempted to disconnect after shutdown")
            throw PeripheralError.bluetoothUnavailable
        }
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
        persistReconnectIntent()
        taskRegistry.cancel(id)
        reconnectAttempts[id] = nil
        
        setConnectionState(.disconnecting, for: id)
        centralManager.cancelPeripheralConnection(cbPeripheral)
    }

    /// The single write path for per-peripheral connection state.
    ///
    /// Records the state, mirrors it onto the interned handle so ``Peripheral/connectionState`` stays in step, and
    /// broadcasts the change. Every transition must go through here — a bare `connectionStates[id] = …` would
    /// leave the handle's cached value silently stale.
    private func setConnectionState(_ state: ConnectionState, for id: String) {
        connectionStates[id] = state
        registry.applyConnectionState(id: id, state: state)
        broadcast(ConnectionStateChange(peripheralId: id, state: state), to: connectionStateChangesContinuations)
    }

    /// Drops all tracked connection state, mirroring the clear onto every affected handle and broadcasting a
    /// terminal transition for each.
    ///
    /// A bare `connectionStates.removeAll()` would leave handles reporting a state the library no longer believes —
    /// a handle stuck on `.connected` after the radio was invalidated is worse than one reporting nothing, because
    /// unlike the metadata properties it is not merely stale, it is known to be false.
    ///
    /// Clearing is silent on the handle (``Peripheral/connectionState`` reverts to `nil`, meaning "not tracked")
    /// but **not** on the stream: a subscriber that only ever learns about transitions from
    /// `connectionStateChanges` would otherwise keep rendering `.connected` forever, since a cleared peripheral
    /// produces no further events. `.disconnected(reason: .bluetoothUnavailable)` is emitted instead — true at the
    /// moment it is sent, and the reason a consumer needs to react to.
    ///
    /// `shutdown()` also routes through here, but it finishes and drops every continuation first, so the broadcast
    /// is a no-op there — a torn-down stack ends its streams rather than emitting a final state into them.
    private func clearConnectionStates() {
        for id in connectionStates.keys {
            registry.applyConnectionState(id: id, state: nil)
            broadcast(
                ConnectionStateChange(peripheralId: id, state: .disconnected(reason: .bluetoothUnavailable)),
                to: connectionStateChangesContinuations
            )
        }
        connectionStates.removeAll()
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
        
        log?.info(tags: [.peripheral(id), .category(.connection)], "Peripheral connected")
        setConnectionState(.connected, for: id)
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
            log?.info(tags: [.peripheral(id), .category(.connection)], "Peripheral disconnected (explicit)")
            setConnectionState(.disconnected(reason: nil), for: id)
            
            return
        }
        
        if payload.isReconnecting {
            // Defensively cancel any pending library ladder so Tier 0 (system) and Tier 1
            // (library) cannot overlap under odd callback ordering.
            taskRegistry.cancel(id)

            log?.info(tags: [.peripheral(id), .category(.connection)], "System auto-reconnect in progress")
            setConnectionState(.reconnecting(source: .system, attempt: nil, nextRetryAt: nil), for: id)
            
            return
        }
        
        let mappedError: PeripheralError? = payload.error.map { ($0 as? CBError).map(PeripheralError.fromCBError) ?? .unknown }
        if let error = mappedError {
            log?.warn(tags: [.peripheral(id), .category(.connection)], "Peripheral disconnected with error: \(error)")
        } else {
            log?.info(tags: [.peripheral(id), .category(.connection)], "Peripheral disconnected")
        }
        
        setConnectionState(.disconnected(reason: mappedError), for: id)
        armReconnect(id: id)
    }

    private func handleDidFailToConnect(_ payload: ConnectionPayload) {
        guard let id = id(for: payload.peripheral) else {
            log?.warn(tags: [.category(.connection)], "didFailToConnect for unknown peripheral — dropped")
            return
        }
        
        let mappedError: PeripheralError? = payload.error.map { ($0 as? CBError).map(PeripheralError.fromCBError) ?? .unknown }
        log?.warn(tags: [.peripheral(id), .category(.connection)], "Peripheral connection failed with error: \(mappedError ?? .unknown)")
        
        setConnectionState(.failed(reason: mappedError), for: id)
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
        taskRegistry.cancel(id)

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
        setConnectionState(.reconnecting(source: .library, attempt: attempt, nextRetryAt: nextRetryAt), for: id)

        let task = Task { [weak self] in
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
        taskRegistry.insert(id, task)
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
            log?.warn(tags: [.peripheral(id), .category(.connection)], "Reconnect attempt failed: \(reason)")
            setConnectionState(.failed(reason: reason), for: id)
        }
    }
    
    private func clearReconnectState(for id: String) {
        taskRegistry.cancel(id)
        reconnectAttempts[id] = nil
        intentionalDisconnects.remove(id)
    }

    /// Test-only hook
    func setReconnectPolicy(_ policy: ReconnectPolicy) {
        reconnectPolicy = policy
    }

    /// Test-only hook: overrides the idle disconnect interval (seconds). `0` tears down as soon
    /// as demand reaches zero.
    func setIdleDisconnectInterval(_ interval: TimeInterval) {
        if !interval.isFinite || interval < 0 {
            idleDisconnectInterval = 5.0
        } else {
            idleDisconnectInterval = interval
        }
    }

    /// Test-only hook: number of continuations currently parked by ``waitUntilPoweredOn()``.
    func testPendingPoweredOnWaiterCount() -> Int {
        poweredOnContinuations.count
    }

    /// Test-only hook: whether a ``startScanning(services:)`` waiter is currently parked.
    func testPendingScanWaiterCount() -> Int {
        scanWaiterContinuation == nil ? 0 : 1
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

    /// Test-only hook: invokes ``handleWillRestoreState(_:)`` directly for defensive unit tests
    /// (e.g. empty scan filter, defer-until-powered-on, disconnected-peripheral seeding) that
    /// cannot use the faithful mock `simulateStateRestoration` path.
    ///
    /// Does not go through the shim or event pipeline — production restoration is covered by
    /// cold-relaunch tests that set `CBMCentralManagerMock.simulateStateRestoration`.
    ///
    /// - Parameter peripheralIds: Live `cbPeripherals` keys to include in the restoration dictionary.
    func testHandleWillRestoreState(
        peripheralIds: [String] = [],
        scanServices: [CBUUID]? = nil
    ) {
        var state: [String: Any] = [:]
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
        handleWillRestoreState(RestorationPayload(state: state))
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

    /// Test-only hook: number of registered `connectionStateChanges` subscribers.
    ///
    /// Stream registration is asynchronous — the factory schedules `register(...)` on a detached
    /// actor hop (see ``connectionStateChangesStream()``). Tests that must observe a
    /// broadcast emitted *right after* subscribing (e.g. the restore path) poll this until their
    /// subscription has landed, otherwise a non-replaying broadcast can be missed entirely.
    func testConnectionStateSubscriberCount() -> Int {
        connectionStateChangesContinuations.count
    }

    /// Test-only hook: number of registered `discoveredPeripherals` subscribers. See
    /// ``testConnectionStateSubscriberCount()`` for why tests need to observe registration.
    func testPeripheralsSubscriberCount() -> Int {
        peripheralsContinuations.count
    }

    /// Test-only hook: service filter stashed when a restored scan was deferred until powered on.
    func testPendingRestoredScanServices() -> [CBUUID]? {
        pendingRestoredScanServices
    }

    /// Test-only hook: restore identifier captured on first ``ensureInitialized`` call.
    func testRestoreIdentifier() -> String? {
        restoreIdentifier
    }

    /// Test-only hook: keys of the options dictionary ``setupCentralManager()`` would pass to the
    /// factory right now. Verifies restore-key wiring at the unit level.
    func testCentralCreationOptionKeys() -> [String] {
        centralManagerCreationOptions().map { Array($0.keys) } ?? []
    }

    /// Test-only hook: whether the installed delegate is the restoring peer shim.
    ///
    /// Paired with ``testCentralCreationOptionKeys()`` so tests can assert that the restore-id
    /// option and the restoring delegate are always installed together.
    func testDelegateIsRestoringShim() -> Bool {
        delegateShim is RestoringBluetoothDelegateShim
    }

    /// Test-only hook: whether the installed delegate is the non-restoring peer shim.
    func testDelegateIsNonRestoringShim() -> Bool {
        delegateShim is BluetoothDelegateShim
    }

    /// Test-only hook: reconnect intent persisted for the current restore identifier.
    func testPersistedReconnectIntent() -> Set<String> {
        persistedReconnectIntent()
    }

    /// Test-only hook: removes any persisted reconnect intent for the current restore identifier.
    func testClearPersistedReconnectIntent() {
        guard let key = reconnectIntentDefaultsKey else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }

    }

// MARK: - BluetoothDelegateShim

/// Yields CoreBluetooth delegate callbacks into ``BluetoothActor``'s ordered event pipeline.
///
/// Shared by both shims so callback ferrying stays in one place. Holds no actor reference (only
/// the pipeline continuation), avoiding retain cycles.
fileprivate final class DelegateEventForwarder: @unchecked Sendable {
    private let eventContinuation: AsyncStream<DelegateEvent>.Continuation

    init(eventContinuation: AsyncStream<DelegateEvent>.Continuation) {
        self.eventContinuation = eventContinuation
    }

    func stateUpdate() {
        // Yielding is synchronous and thread-safe; ordering is preserved because CoreBluetooth
        // invokes delegate methods serially on its dispatch queue.
        eventContinuation.yield(.stateUpdate)
    }

    func discovered(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: Int
    ) {
        // Ferry the non-Sendable CBPeripheral and advertisement dictionary across the actor isolation hop in a
        // single-purpose payload. They are extracted into Sendable types (Peripheral / AdvertisementData) inside
        // the actor.
        let payload = DiscoveryPayload(peripheral: peripheral, advertisementData: advertisementData, rssi: rssi)
        eventContinuation.yield(.discovered(payload))
    }

    func connected(peripheral: CBPeripheral) {
        let payload = ConnectionPayload(peripheral: peripheral, isReconnecting: false, error: nil)
        eventContinuation.yield(.connected(payload))
    }

    func connectFailed(peripheral: CBPeripheral, error: Error?) {
        let payload = ConnectionPayload(peripheral: peripheral, isReconnecting: false, error: error)
        eventContinuation.yield(.connectFailed(payload))
    }

    func disconnected(peripheral: CBPeripheral, isReconnecting: Bool, error: Error?) {
        let payload = ConnectionPayload(peripheral: peripheral, isReconnecting: isReconnecting, error: error)
        eventContinuation.yield(.disconnected(payload))
    }

    func willRestore(state: [String: Any]) {
        // First callback on relaunch when a restore identifier was used. Ferry the non-Sendable
        // restoration dictionary across the actor hop; extraction happens inside the actor.
        eventContinuation.yield(.willRestore(RestorationPayload(state: state)))
    }
}

/// Non-restoring `CBCentralManagerDelegate` bridge into ``DelegateEventForwarder``.
///
/// Intentionally does **not** implement `centralManager(_:willRestoreState:)`. Real CoreBluetooth
/// uses ObjC `responds(to:)` and logs API MISUSE when that method is present without a restore
/// identifier. Use ``RestoringBluetoothDelegateShim`` when restoration is enabled.
///
/// - Important: Keep the five shared callbacks below in lockstep with
///   ``RestoringBluetoothDelegateShim`` (same signatures, same forwarder calls). Drift silently
///   drops events on one path. Shared ferrying lives only in ``DelegateEventForwarder``.
final class BluetoothDelegateShim: NSObject, CBCentralManagerDelegate {
    private let forwarder: DelegateEventForwarder

    fileprivate init(forwarder: DelegateEventForwarder) {
        self.forwarder = forwarder
        super.init()
    }

    // MARK: Shared callbacks — keep in sync with RestoringBluetoothDelegateShim

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        forwarder.stateUpdate()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        forwarder.discovered(peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        forwarder.connected(peripheral: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        forwarder.connectFailed(peripheral: peripheral, error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        forwarder.disconnected(peripheral: peripheral, isReconnecting: isReconnecting, error: error)
    }
}

/// Restoring `CBCentralManagerDelegate` bridge into ``DelegateEventForwarder``.
///
/// Only installed when ``ReliaBLEConfig/restoreIdentifier`` is non-`nil`, so the central is always
/// created with a matching `CBCentralManagerOptionRestoreIdentifierKey`.
///
/// Peer of ``BluetoothDelegateShim`` (not a subclass): CoreBluetoothMock dispatches
/// `willRestoreState` via an unconditional Swift protocol call (extension default is a no-op), so
/// each type needs its own witness table. Real CoreBluetooth additionally needs the method absent
/// on the non-restoring peer for ObjC `responds(to:)` / API MISUSE.
///
/// - Important: Keep the five shared callbacks below in lockstep with ``BluetoothDelegateShim``
///   (same signatures, same forwarder calls). Drift silently drops events on one path.
final class RestoringBluetoothDelegateShim: NSObject, CBCentralManagerDelegate {
    private let forwarder: DelegateEventForwarder

    fileprivate init(forwarder: DelegateEventForwarder) {
        self.forwarder = forwarder
        super.init()
    }

    // MARK: Shared callbacks — keep in sync with BluetoothDelegateShim

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        forwarder.stateUpdate()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        forwarder.discovered(peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        forwarder.connected(peripheral: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        forwarder.connectFailed(peripheral: peripheral, error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        forwarder.disconnected(peripheral: peripheral, isReconnecting: isReconnecting, error: error)
    }

    // MARK: Restoration-only

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        forwarder.willRestore(state: dict)
    }
}
