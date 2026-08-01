//
//  DiscoveredPeripheral.swift
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

/// An immutable, `Sendable` value snapshot of a peripheral as it appeared during a scan.
///
/// `DiscoveredPeripheral` is the element type of ``ReliaBLEManager/discoveredPeripherals`` — the de-duplicated
/// "nearby" list. Each element captures what the library knew about a device at the moment the list was emitted.
/// It is a pure value: freely sendable, safe to diff, and safe to hand straight to SwiftUI as list data.
///
/// Snapshots represent *real* observations only. A peripheral the app knows about but has not seen — one obtained
/// via ``ReliaBLEManager/peripheral(id:)`` — never appears here as a synthetic row. Peripherals recovered through
/// state restoration do appear, with an empty ``advertisement`` and a `nil` ``rssi``.
///
/// To act on a snapshot, cross over to its control handle:
///
/// ```swift
/// for await peripherals in manager.discoveredPeripherals {
///     for snapshot in peripherals where snapshot.name == "MyBand" {
///         try await snapshot.peripheral.connect()
///     }
/// }
/// ```
///
/// A `DiscoveredPeripheral` carries no reference to the underlying `CBPeripheral`. The live object is owned
/// exclusively by the library in an ``id``-keyed map that never escapes its internal concurrency domain.
public struct DiscoveredPeripheral: Sendable, Identifiable, Hashable {
    /// Unique, app-facing identifier for the peripheral.
    ///
    /// Resolved at discovery time from the peripheral's advertised name, its local name, or — as a fallback — the
    /// CoreBluetooth identifier string. This is the same identifier ``Peripheral/id`` carries, and is **not** the
    /// CoreBluetooth `UUID` reported by ``PeripheralDiscoveryEvent/id``.
    public let id: String

    /// The CoreBluetooth identifier for the peripheral, used to re-resolve the live peripheral after invalidation.
    public let cbIdentifier: UUID?

    /// The name advertised by the peripheral, if available.
    public let name: String?

    /// Signal strength indicator (RSSI) of the most recent advertisement.
    ///
    /// `nil` for a peripheral recovered through state restoration, which carries no advertisement payload.
    public let rssi: Int?

    /// The timestamp when the peripheral was last seen, or last bound through state restoration.
    public let lastSeen: Date?

    /// The typed advertisement data from the most recent discovery.
    ///
    /// Empty for a peripheral recovered through state restoration. Advertisement data is transient, per-discovery
    /// information; it is not the peripheral's connected GATT service catalog.
    public let advertisement: AdvertisementData?

    /// The registry that vended this snapshot, which is what makes ``peripheral`` resolve to the *same* handle the
    /// producing manager would return. Excluded from `==` and `hash`.
    ///
    /// Held strongly, and deliberately so: a snapshot that outlives its manager keeps the registry — and therefore
    /// the interning guarantee — alive, so `snapshot.peripheral === snapshot.peripheral` still holds. The handle's
    /// own manager reference is weak, so connecting through an orphaned snapshot fails cleanly with
    /// ``PeripheralError/bluetoothUnavailable`` rather than silently minting fresh handles.
    let registry: any PeripheralRegistryBridge

    /// The interned control handle for this peripheral, on the manager that produced the snapshot.
    ///
    /// Returns the very same object as `manager.peripheral(id: snapshot.id)` — repeated accesses yield an
    /// identical (`===`) instance.
    public var peripheral: Peripheral { registry.peripheral(id: id) }

    /// Creates a snapshot. Internal — snapshots originate from the library's scan and restore paths only.
    init(
        id: String,
        cbIdentifier: UUID? = nil,
        name: String? = nil,
        rssi: Int? = nil,
        lastSeen: Date? = nil,
        advertisement: AdvertisementData? = nil,
        registry: any PeripheralRegistryBridge
    ) {
        self.id = id
        self.cbIdentifier = cbIdentifier
        self.name = name
        self.rssi = rssi
        self.lastSeen = lastSeen
        self.advertisement = advertisement
        self.registry = registry
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Equality keys on ``id`` only — the identifier is what the library uses to match a snapshot to its live
    /// `CBPeripheral`, and the vending registry is an implementation detail.
    public static func == (lhs: DiscoveredPeripheral, rhs: DiscoveredPeripheral) -> Bool {
        return lhs.id == rhs.id
    }
}
