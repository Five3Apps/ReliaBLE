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

/// An immutable, `Sendable` value snapshot of a Bluetooth peripheral and its metadata.
///
/// A `Peripheral` carries no reference to the underlying CoreBluetooth `CBPeripheral`. The live `CBPeripheral` is
/// owned exclusively by ``BluetoothActor`` in an `id`-keyed registry that never escapes the actor. Operations that
/// need the live peripheral (such as ``ReliaBLEManager/connect(to:)``) forward the snapshot's ``id``; the actor looks
/// up the live reference and throws ``PeripheralError/notFound`` if the snapshot has since gone stale.
///
/// The integrating app can also construct a `Peripheral` from a known identifier *before* it has been discovered —
/// for example, a wearable bound to the user's account — using ``init(id:)``. Such a snapshot has no
/// ``advertisement`` (and no live reference) until ``BluetoothActor`` matches it against a discovered `CBPeripheral`.
///
/// Because it is a pure value type, a `Peripheral` is freely sendable across isolation domains and safe to hand to
/// the integrating app for UI display.
public struct Peripheral: Sendable, Identifiable, Hashable {
    /// Unique identifier for the peripheral.
    ///
    /// When provided by the integrating app via ``init(id:)`` this is the app's own identifier. When resolved at
    /// discovery time it is the peripheral's advertised name, its local name, or — as a fallback — the CoreBluetooth
    /// identifier string.
    public let id: String

    /// The CoreBluetooth identifier for the peripheral, used to retrieve it after invalidation.
    ///
    /// `nil` for an app-constructed peripheral that has not yet been discovered.
    public let cbIdentifier: UUID?

    /// The name advertised by the peripheral, if available.
    public let name: String?

    /// Signal strength indicator (RSSI) of the most recent advertisement.
    public let rssi: Int?

    /// The timestamp when the peripheral was last seen.
    public let lastSeen: Date?

    /// The typed advertisement data from the most recent discovery.
    ///
    /// `nil` until the peripheral has been discovered. Advertisement data is transient, per-discovery information; it
    /// is not the peripheral's connected GATT service catalog.
    public let advertisement: AdvertisementData?

    /// Registers a known peripheral before it has been discovered.
    ///
    /// Use this when the integrating app already has a stable identifier for a peripheral — such as a device bound to
    /// the user's account — and wants ReliaBLE to match it against the corresponding `CBPeripheral` once discovered.
    /// The resulting snapshot has no ``cbIdentifier``, ``name``, ``rssi``, ``lastSeen``, or ``advertisement`` until
    /// discovery populates them.
    ///
    /// - Parameter id: The integrating app's unique identifier for the peripheral.
    public init(id: String) {
        self.init(id: id, cbIdentifier: nil, name: nil, rssi: nil, lastSeen: nil, advertisement: nil)
    }

    /// Creates a fully-specified peripheral snapshot. Used internally by ``BluetoothActor`` at discovery time.
    ///
    /// - Parameters:
    ///   - id: Unique identifier for the peripheral.
    ///   - cbIdentifier: The CoreBluetooth identifier, used to re-resolve the live peripheral after invalidation.
    ///   - name: The name advertised by the peripheral, if available.
    ///   - rssi: Signal strength indicator (RSSI) of the most recent advertisement.
    ///   - lastSeen: The timestamp when the peripheral was last seen.
    ///   - advertisement: The typed advertisement data from the most recent discovery.
    init(
        id: String,
        cbIdentifier: UUID? = nil,
        name: String? = nil,
        rssi: Int? = nil,
        lastSeen: Date? = nil,
        advertisement: AdvertisementData? = nil
    ) {
        self.id = id
        self.cbIdentifier = cbIdentifier
        self.name = name
        self.rssi = rssi
        self.lastSeen = lastSeen
        self.advertisement = advertisement
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: Peripheral, rhs: Peripheral) -> Bool {
        // Equality keys on `id` only: the identifier is unique and the matching between `Peripheral` snapshots and
        // their live `CBPeripheral` is handled internally by ``BluetoothActor``.
        return lhs.id == rhs.id
    }
}
