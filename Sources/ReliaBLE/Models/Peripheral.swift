//
//  Peripheral.swift
//  ReliaBLE
//
//  Created by Justin Bergen on 2/24/25.
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

import Foundation
import Synchronization

/// A long-lived control handle for a Bluetooth peripheral.
///
/// A `Peripheral` is the object an app holds onto and acts through: it owns ``connect(autoReconnect:)`` and
/// ``disconnect()``, and it exposes the last-known metadata for the device it represents. Unlike a
/// ``DiscoveredPeripheral`` — a per-scan value snapshot — a handle is *stable*: there is exactly **one handle
/// instance per ``id`` per ``ReliaBLEManager``, so it is safe to store one in a view model and rely on reference
/// identity (`===`).
///
/// ## Obtaining a handle
///
/// Handles are never constructed directly. Obtain one either from a known identifier, before the device has ever
/// been seen:
///
/// ```swift
/// let band = manager.peripheral(id: "user-band")
/// ```
///
/// …or from a discovery snapshot:
///
/// ```swift
/// for await discovered in manager.discoveredPeripherals {
///     for snapshot in discovered {
///         let handle = snapshot.peripheral   // the same instance `peripheral(id:)` returns
///     }
/// }
/// ```
///
/// ## Metadata is last-known, not live
///
/// ``name``, ``rssi``, ``lastSeen``, ``advertisement``, and ``connectionState`` are synchronous, cached reads of
/// the most recent value the library resolved for this ``id``. They are deliberately *not* `async`, so SwiftUI row
/// bodies can read them inline. Two consequences follow:
///
/// - **Reads are per-property, not one atomic snapshot.** Reading ``name`` then ``rssi`` can straddle two
///   discovery updates. This is benign for display but is a real part of the contract.
/// - **There is no change notification.** `Peripheral` is a plain `Sendable` class — it is not `@Observable` and
///   publishes nothing. Use ``ReliaBLEManager/discoveredPeripherals`` as the "something changed" tick and re-read
///   handle metadata inside that loop; likewise re-read ``connectionState`` inside a
///   ``ReliaBLEManager/connectionStateChanges`` loop.
///
/// Metadata survives a radio reset: after the library invalidates its live CoreBluetooth references, the last-known
/// values remain readable while ``connect(autoReconnect:)`` throws ``PeripheralError/notFound`` until the device is
/// rediscovered.
///
/// ## Concurrency
///
/// `Peripheral` is a checked `Sendable` class. All mutable state lives inside a single `Mutex`; every other stored
/// property is immutable. The handle holds **no** `CBPeripheral` — live CoreBluetooth objects never leave the
/// library's internal isolation domain, and operations forward by ``id``.
///
/// The handle's reference to its manager is **weak**: a handle can legitimately outlive the manager that vended it.
/// An orphaned handle keeps its metadata but throws ``PeripheralError/bluetoothUnavailable`` from
/// ``connect(autoReconnect:)`` and ``disconnect()``.
public final class Peripheral: Sendable, Identifiable, Hashable {
    /// Everything mutable about a handle, guarded by a single lock.
    ///
    /// The `weak` manager reference is sound here specifically *because* it is boxed: every read and write happens
    /// under the mutex, and the runtime's weak load/zeroing is atomic with respect to deallocation. A bare
    /// `weak var` on an `@unchecked Sendable` class would not be.
    private struct State {
        weak var manager: ReliaBLEManager?
        var cbIdentifier: UUID?
        var name: String?
        var rssi: Int?
        var lastSeen: Date?
        var advertisement: AdvertisementData?
        var connectionState: ConnectionState?
    }

    /// Unique, app-facing identifier for the peripheral.
    ///
    /// When the app creates the handle via ``ReliaBLEManager/peripheral(id:)`` this is the app's own identifier.
    /// When the library resolves it at discovery time it is the peripheral's advertised name, its local name, or —
    /// as a fallback — the CoreBluetooth identifier string.
    public let id: String

    private let state: Mutex<State>

    /// Creates a handle. **Only ``PeripheralHandleRegistry`` may call this** — the registry is what guarantees the
    /// one-instance-per-id invariant, and a second construction site would silently break it. This is enforced by
    /// review convention rather than by access control, since the registry lives in its own file.
    init(id: String, manager: ReliaBLEManager?) {
        self.id = id
        self.state = Mutex(State(manager: manager))
    }

    // MARK: - Last-known metadata

    /// The CoreBluetooth identifier for the peripheral, used to re-resolve the live peripheral after invalidation.
    ///
    /// `nil` until the peripheral has been discovered or restored.
    public var cbIdentifier: UUID? { state.withLock { $0.cbIdentifier } }

    /// The name most recently advertised by the peripheral, if any.
    public var name: String? { state.withLock { $0.name } }

    /// Signal strength indicator (RSSI) from the most recent advertisement.
    public var rssi: Int? { state.withLock { $0.rssi } }

    /// When the peripheral was last seen — or, for a peripheral recovered through state restoration, when its live
    /// reference was last bound.
    public var lastSeen: Date? { state.withLock { $0.lastSeen } }

    /// The typed advertisement data from the most recent discovery.
    ///
    /// `nil` until the peripheral has been discovered. Advertisement data is transient, per-discovery information;
    /// it is not the peripheral's connected GATT service catalog.
    public var advertisement: AdvertisementData? { state.withLock { $0.advertisement } }

    /// The last-known connection state for this peripheral, or `nil` if the library is not tracking one.
    ///
    /// Mirrored from the library's internal connection tracking, including when that tracking is *cleared*: unlike
    /// the metadata properties above, this reverts to `nil` when the library drops its connection state (for
    /// example after Bluetooth is powered off and live references are invalidated), rather than reporting a state
    /// that is known to be false. As with the other cached properties there is no change notification — re-read it
    /// inside a ``ReliaBLEManager/connectionStateChanges`` loop.
    ///
    /// That loop is a complete tick: a clear emits ``ConnectionState/disconnected(reason:)`` carrying
    /// ``PeripheralError/bluetoothUnavailable``, so re-reading on every event is sufficient and this property never
    /// strands a stale `.connected`. Note the deliberate asymmetry — the event describes the transition that
    /// happened, while the handle reports `nil` for "the library is no longer tracking this peripheral."
    public var connectionState: ConnectionState? { state.withLock { $0.connectionState } }

    // MARK: - Connection

    /// Initiates a connection to this peripheral.
    ///
    /// Rather than silently no-op'ing or throwing when the radio is not yet usable, this waits for
    /// a transient (`.resetting` / `.unknown`) radio state to resolve before issuing the connect,
    /// and fails fast with a typed error for terminal states (``PeripheralError/bluetoothPoweredOff``,
    /// ``PeripheralError/bluetoothUnsupported``, ``PeripheralError/bluetoothUnavailable``). Cancelling
    /// the calling task while parked on a transient state unblocks the wait with a `CancellationError`.
    ///
    /// - Parameter autoReconnect: When `true` (the default), the library passes
    ///   `CBConnectPeripheralOptionEnableAutoReconnect` to the system and arms the app-side exponential-backoff
    ///   ladder for cases the OS option doesn't cover. Set to `false` for one-shot connections where reconnection
    ///   is not desired.
    /// - Throws: ``PeripheralError/notFound`` if the library holds no live reference for this ``id`` — either it
    ///   has never been discovered, or its reference was invalidated. ``PeripheralError/bluetoothUnavailable`` if
    ///   Bluetooth has not been set up (for example, not yet authorized), or if the manager that vended this handle
    ///   has been deallocated or shut down.
    public func connect(autoReconnect: Bool = true) async throws {
        guard let manager = state.withLock({ $0.manager }) else { throw PeripheralError.bluetoothUnavailable }

        await manager.bluetooth.ensureCentralManager()

        // Register the manual-connect hold FIRST so a connect that throws (e.g. bluetoothPoweredOff)
        // still leaves durable demand behind — the throw is informational, not destructive (D-hold).
        await manager.bluetooth.applyManualConnectHold(id: id, reconnectDesired: autoReconnect)

        // Await a usable radio (cancellable), then ensure the link. Failures after the hold is
        // recorded (terminal radio, missing peripheral, etc.) are warned so Console shows why
        // the call threw; `CancellationError` is not a failure and is rethrown quietly.
        do {
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await manager.bluetooth.waitUntilPoweredOn(waiterID: waiterID)
            } onCancel: {
                Task { await manager.bluetooth.cancelPoweredOnContinuation(waiterID) }
            }

            try await manager.bluetooth.reevaluateLink(id: id, reason: .explicitConnect)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            manager.loggingService.warn(
                tags: [.peripheral(id), .category(.connection)],
                "Manual connect failed: \(error)"
            )
            throw error
        }
    }

    /// Initiates a disconnection from this peripheral.
    ///
    /// Clears this handle's manual-connect hold and intentionally cancels the link per the settling
    /// rule. Returns success even when the library holds no live reference (e.g. during a radio
    /// outage), because dropping a hold must never throw `.notFound`.
    public func disconnect() async throws {
        guard let manager = state.withLock({ $0.manager }) else { throw PeripheralError.bluetoothUnavailable }

        await manager.bluetooth.applyManualDisconnect(id: id)
    }

    /// Acquires a work lease on this peripheral (internal demand substrate).
    ///
    /// Ensures a central, awaits a usable radio (cancellable), then forwards to the actor lease
    /// acquisition, which creates demand and drives an auto-connect without a prior manual
    /// ``connect(autoReconnect:)``. `@testable`-visible only; no public surface this phase (D-work).
    func acquireWorkLease() async throws -> WorkLeaseToken {
        guard let manager = state.withLock({ $0.manager }) else { throw PeripheralError.bluetoothUnavailable }

        await manager.bluetooth.ensureCentralManager()

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await manager.bluetooth.waitUntilPoweredOn(waiterID: waiterID)
        } onCancel: {
            Task { await manager.bluetooth.cancelPoweredOnContinuation(waiterID) }
        }

        return try await manager.bluetooth.acquireWorkLease(id: id)
    }

    /// Releases a work lease previously acquired on this peripheral. Releasing an unknown or
    /// already-released token is a no-op.
    func releaseWorkLease(_ token: WorkLeaseToken) async {
        guard let manager = state.withLock({ $0.manager }) else { return }
        await manager.bluetooth.releaseWorkLease(token)
    }

    // MARK: - Internal mutation
    //
    // Both entry points are called from `PeripheralHandleRegistry` on behalf of `BluetoothActor`, so writes are
    // already serialized by the actor's executor. The lock exists to make *reads* from arbitrary isolation domains
    // safe, not to order writes.
    //
    // FR-10 (#52) will attach the sticky discovery filter, command queue, and GATT readiness state to this type.
    // Nothing for it is stored here yet.

    /// Mirrors the resolved discovery/restore snapshot onto the handle.
    ///
    /// Values are applied exactly as given: the caller has already merged them (see
    /// `BluetoothActor.resolveAndUpsertDiscovered`), so the handle and the snapshot list never disagree.
    func applyMetadata(
        cbIdentifier: UUID?,
        name: String?,
        rssi: Int?,
        lastSeen: Date?,
        advertisement: AdvertisementData?
    ) {
        state.withLock {
            $0.cbIdentifier = cbIdentifier
            $0.name = name
            $0.rssi = rssi
            $0.lastSeen = lastSeen
            $0.advertisement = advertisement
        }
    }

    /// Mirrors a connection-state transition onto the handle. `nil` clears it, for when the library stops tracking
    /// a connection state for this peripheral entirely.
    func applyConnectionState(_ connectionState: ConnectionState?) {
        state.withLock { $0.connectionState = connectionState }
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Equality keys on ``id`` only, matching the id-keyed connection-state tracking used throughout the library.
    ///
    /// Within a single manager this is equivalent to identity, because handles are interned. Across *two* managers
    /// it is not: two handles for the same ``id`` vended by different managers compare `==` but are distinct
    /// objects on distinct registries, and each can only talk to its own manager. Multi-manager apps must not mix
    /// them; use `===` when identity is what you mean.
    public static func == (lhs: Peripheral, rhs: Peripheral) -> Bool {
        return lhs.id == rhs.id
    }
}
