//
//  PeripheralHandleRegistry.swift
//  ReliaBLE
//
//  Created by Justin Bergen on 8/1/25.
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

/// The seam through which ``BluetoothActor`` pushes resolved peripheral data out to handles.
///
/// The actor owns identity resolution, the live `CBPeripheral` map, and connection state; it does **not** own
/// handle instances. This protocol inverts that dependency so the actor can update handles without knowing about
/// ``ReliaBLEManager`` or ``PeripheralHandleRegistry``.
///
/// ## Contract for implementations
///
/// Every method is invoked **from the actor's executor**, synchronously. That has consequences:
///
/// - Implementations must be non-blocking and allocation-light. Whatever they do, the actor's executor waits.
/// - They must **not** spawn `Task { await actor… }`. It compiles fine inside a synchronous function and reorders
///   arbitrarily against the ordered discovery stream.
/// - They must not invoke app-supplied callbacks while holding a lock.
/// - Nothing reachable from this protocol may retain ``ReliaBLEManager`` strongly. The actor stores the bridge, and
///   live stream subscribers retain the actor — a strong manager reference here would pin the manager, its central,
///   and every handle for the lifetime of a single un-terminated `for await`.
///
/// Direct re-entry into the actor is already impossible: these methods are synchronous and non-throwing, so
/// `await` cannot appear inside them.
protocol PeripheralRegistryBridge: Sendable {
    /// Returns the interned handle for `id`, creating it with empty metadata if this is the first request.
    ///
    /// This is what ``DiscoveredPeripheral/peripheral`` resolves through, which is why it lives on the bridge
    /// rather than only on the concrete registry: a snapshot carries this seam and nothing else.
    func peripheral(id: String) -> Peripheral

    /// Interns the handle for `id` if it does not exist yet, then mirrors the resolved snapshot onto it.
    ///
    /// This is deliberately one create-or-update call rather than a separate "ensure" plus "update": it runs once
    /// per advertisement per device, which is the library's hottest path, and splitting it would only double lock
    /// acquisitions.
    func applyDiscovery(
        id: String,
        cbIdentifier: UUID?,
        name: String?,
        rssi: Int?,
        lastSeen: Date?,
        advertisement: AdvertisementData?
    )

    /// Interns the handle for `id` if needed, then mirrors a connection-state transition onto it.
    ///
    /// A `nil` state means the library no longer tracks a connection state for `id` — pass it when the actor's
    /// tracking is cleared, so a handle cannot keep reporting a state that is known to be false. Clearing is the
    /// one case that does **not** intern: it corrects an existing handle if there is one, and is otherwise a no-op.
    func applyConnectionState(id: String, state: ConnectionState?)

    /// Drops every interned handle. Called from terminal teardown only.
    func removeAllHandles()
}

/// The per-manager store of ``Peripheral`` handles.
///
/// This type is what makes "one handle instance per id per manager" true. It is owned by ``ReliaBLEManager`` rather
/// than by ``BluetoothActor``, because ``ReliaBLEManager/peripheral(id:)`` must be synchronous — callable from a
/// SwiftUI body, and callable before any `CBCentralManager` exists. Interning on the actor would force `async` on
/// the library's most basic entry point.
///
/// There is deliberately **no** process-global registry. Each manager is an independent BLE stack, so two managers
/// mean two registries and two distinct handles for the same physical device.
///
/// ## Growth
///
/// Handles are held **strongly** and keyed by resolved id, and every discovery interns one — including for devices
/// the app never asks about. Nothing evicts them: `BluetoothActor.shutdown()` empties the table, but that is
/// test/harness teardown, so in a shipping app **the registry retains one handle per distinct id observed for the
/// lifetime of the manager**. A long-running background scan in a dense RF environment is therefore the case to
/// watch; each entry is small (an id plus last-known metadata) and bounded by the number of distinct devices seen,
/// not by advertisement volume.
///
/// Weak-value storage (`[String: WeakBox<Peripheral>]` with prune-on-insert) is the known stronger answer —
/// interning identity would then last exactly as long as the app holds a reference — and is deferred rather than
/// rejected. Revisit it if the observed-device count per session becomes unbounded in practice.
///
/// ## Retain graph
///
/// ```text
/// manager  → registry (strong) → handles (strong) → manager (weak)
/// manager  → actor    (strong) → registry-as-bridge (strong) → manager (weak)
/// snapshot → registry (strong)
/// ```
///
/// Acyclic in every direction. The registry conforms to ``PeripheralRegistryBridge`` itself, rather than through a
/// separate adapter object, which is what makes the "nothing actor-reachable retains the manager strongly" rule
/// hold automatically — the registry's only manager reference is already weak.
final class PeripheralHandleRegistry: PeripheralRegistryBridge, Sendable {
    private struct Storage {
        weak var manager: ReliaBLEManager?
        var handles: [String: Peripheral] = [:]
        var isAttached = false
    }

    private let storage = Mutex(Storage())

    /// Creates an unattached registry.
    ///
    /// The manager is supplied afterwards via ``attach(manager:)``. This two-phase construction is not stylistic:
    /// `ReliaBLEManager.init` cannot pass `self` to the registry before all of its stored properties are
    /// initialized, and `bluetooth` needs the registry — so the registry must exist first and learn about its
    /// manager second.
    init() {}

    /// Completes construction by binding the owning manager. Called once, at the end of `ReliaBLEManager.init`.
    ///
    /// Handles capture their weak manager reference at creation time, from this stored reference, so nothing may
    /// call ``peripheral(id:)`` before this runs.
    func attach(manager: ReliaBLEManager) {
        storage.withLock {
            $0.manager = manager
            $0.isAttached = true
        }
    }

    // MARK: - PeripheralRegistryBridge

    /// Returns the interned handle for `id`, creating it with empty metadata if this is the first request.
    ///
    /// Synchronous and lock-protected: no actor hop, and safe to call before the central manager exists.
    func peripheral(id: String) -> Peripheral {
        storage.withLock { storage in
            assert(
                storage.isAttached,
                "PeripheralHandleRegistry.peripheral(id:) called before attach(manager:); the handle would be "
                    + "permanently orphaned."
            )

            if let existing = storage.handles[id] { return existing }

            let handle = Peripheral(id: id, manager: storage.manager)
            storage.handles[id] = handle

            return handle
        }
    }

    func applyDiscovery(
        id: String,
        cbIdentifier: UUID?,
        name: String?,
        rssi: Int?,
        lastSeen: Date?,
        advertisement: AdvertisementData?
    ) {
        // Lock order is registry → handle, and this avoids nesting entirely: take the handle out from under the
        // registry lock, release it, and only then touch the handle's own lock.
        let handle = peripheral(id: id)
        handle.applyMetadata(
            cbIdentifier: cbIdentifier,
            name: name,
            rssi: rssi,
            lastSeen: lastSeen,
            advertisement: advertisement
        )
    }

    func applyConnectionState(id: String, state: ConnectionState?) {
        // A clear is the one case that must not intern. Minting a handle purely to write `nil` onto it would grow
        // the table with entries nobody requested and nobody can observe — a handle created later reads `nil`
        // anyway. A real state, by contrast, must intern: a handle obtained after the transition has to report it
        // rather than diverge from the actor's tracking.
        guard let handle = state == nil ? existingHandle(id: id) : peripheral(id: id) else { return }
        handle.applyConnectionState(state)
    }

    /// Returns the handle for `id` only if one has already been interned, without creating one.
    private func existingHandle(id: String) -> Peripheral? {
        storage.withLock { $0.handles[id] }
    }

    /// Drops every interned handle. Called from `BluetoothActor.shutdown()`.
    ///
    /// Handles the app still holds keep working — orphaned, throwing ``PeripheralError/bluetoothUnavailable`` — but
    /// the registry stops growing along with a stack that is already dead. Note that a radio reset
    /// (`invalidatePeripherals`) deliberately does *not* do this: a handle must survive one, metadata intact.
    func removeAllHandles() {
        storage.withLock { $0.handles.removeAll() }
    }
}
