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

import CoreBluetooth
import Foundation

/// A representation of a discovered Bluetooth peripheral with metadata.
///
/// This peripheral is a wrapper around the CoreBluetooth `CBPeripheral` object and provides additional metadata
/// and functionality.
///
/// A `Peripheral` can exist without a `CBPeripheral` but all `CBPeripherals` will have a corresponding `Peripheral`.
/// This allows the integrating app to request communiication with a peripheral prior to it having been discovered
/// by CoreBluetooth, or if CoreBluetooth has invalidated all of its `CBPeripherals`.
public final class Peripheral: Identifiable, Hashable, @unchecked Sendable {
    private let mutationLock = NSLock()
    
    /// Unique identifier for the peripheral as set by the integrating app.
    public let id: String
    
    /// The CoreBluetooth peripheral identifier, used to retrieve the peripheral after invalidation.
    private var _peripheralIdentifier: UUID?
    var peripheralIdentifier: UUID? {
        mutationLock.lock(); defer { mutationLock.unlock() }
        return _peripheralIdentifier
    }
    
    private var _peripheral: CBPeripheral?
    /// Reference to the CoreBluetooth peripheral object
    ///
    /// - Warning: Intgrating app should not hold a strong reference!
    var peripheral: CBPeripheral? {
        mutationLock.lock(); defer { mutationLock.unlock() }
        
        return _peripheral
    }
    
    /// The name advertised by the peripheral, if available
    public var name: String? {
        // No lock needed here since this is a computed property that accesses `peripheral` and `advertisementData`
        // which already handle their own synchronization.
        return peripheral?.name ?? advertisementData?[CBAdvertisementDataLocalNameKey] as? String
    }
    
    /// Advertised service UUIDs
    public var serviceUUIDs: [CBUUID]? {
        // No lock needed here since this is a computed property that accesses `advertisementData`
        // which already handles its own synchronization.
        advertisementData?[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
    }
    
    private var _rssi: Int?
    /// Signal strength indicator (RSSI) of the most recent advertisement
    public var rssi: Int? {
        mutationLock.lock(); defer { mutationLock.unlock() }
        
        // Return the cached RSSI value if available.
        return _rssi
    }
    
    private var _advertisementData: [String: Any]?
    /// Complete advertisement data dictionary from the most recent discovery
    public var advertisementData: [String: Any]? {
        mutationLock.lock(); defer { mutationLock.unlock() }
        
        // Return the cached advertisement data if available.
        return _advertisementData

    }
    
    private var _lastSeen: Date?
    /// The timestamp when the peripheral was last seen
    public var lastSeen: Date? {
        mutationLock.lock(); defer { mutationLock.unlock() }
        
        // Return the cached last seen date if available.
        return _lastSeen
    }
    
    /// Create a peripheral with a unique identifier and optional CoreBluetooth peripheral data. The integrating app
    /// should use this initializer to create a `Peripheral` instance when it has a unique identifier for a peripheral
    /// but has not yet discovered the peripheral with CoreBluetooth. ``BluetoothActor`` will update the instance
    /// with CoreBluetooth data when the peripheral is discovered.
    /// - Parameters:
    ///  - id: Unique identifier for the peripheral as set by the integrating app.
    ///  - peripheral: Reference to the CoreBluetooth `CBPeripheral` object
    ///  - advertisementData: Complete advertisement data dictionary from the most recent discovery
    ///  - rssi: Signal strength indicator (RSSI) of the most recent advertisement
    public init(id: String, peripheral: CBPeripheral? = nil, advertisementData: [String: Any]? = nil, rssi: Int? = nil) {
        self.id = id
        
        mutationLock.name = "Peripheral-\(id)-MutationLock"
        
        _peripheral = peripheral
        _peripheralIdentifier = peripheral?.identifier
        _rssi = rssi
        _advertisementData = advertisementData
        
        if peripheral != nil && rssi != nil {
            // Only set the last seen date if we have a valid CBPeripheral and RSSI value.
            // This indicates that we have received an advertisement from the peripheral.
            _lastSeen = Date()
        }
    }
    
    func update(cbPeripheral: CBPeripheral, advertisementData: [String: Any]? = nil, rssi: Int? = nil) {
        mutationLock.lock(); defer { mutationLock.unlock() }
        
        _peripheral = cbPeripheral
        _peripheralIdentifier = cbPeripheral.identifier
        _advertisementData = advertisementData
        _rssi = rssi
        
        if rssi != nil {
            // Only set the last seen date if we have a valid RSSI value.
            // This indicates that we have received an advertisement from the peripheral.
            _lastSeen = Date()
        }
    }
    
    /// Invalidates the CoreBluetooth peripheral reference
    func invalidateCBPeripheral() {
        mutationLock.lock(); defer { mutationLock.unlock() }
        
        _peripheral = nil
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: Peripheral, rhs: Peripheral) -> Bool {
        // No need to compare `CBPeripheral` objects or identifiers, since the `id` is unique and matching between
        // `Peripheral` and `CBPeripheral` instances are handled internally.
        return lhs.id == rhs.id
    }
}
