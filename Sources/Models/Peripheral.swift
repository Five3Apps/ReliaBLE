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
/// A `Peripheral` can exist without a `CBPeripheral` but all `CBPeripherals` will have a coresponding `Peripheral`.
/// This allows the integrating app to request communiication with a peripheral prior to it having been discovered
/// by CoreBluetooth, or if CoreBluetooth has invalidated all of its `CBPeripherals`.
public class Peripheral: Identifiable, Hashable {
    /// Unique identifier for the peripheral as set by the integrating app.
    public let id: String
    
    /// The CoreBluetooth peripheral identifier, used to retrieve the peripheral after invalidation.
    var peripheralIdentifier: UUID?
    
    /// Reference to the CoreBluetooth peripheral object
    ///
    /// - Warning: Intgrating app should not hold a strong reference!
    var peripheral: CBPeripheral?
    
    /// The name advertised by the peripheral, if available
    public var name: String? {
        peripheral?.name ?? advertisementData?[CBAdvertisementDataLocalNameKey] as? String
    }
    
    /// Advertised service UUIDs
    public var serviceUUIDs: [CBUUID]? {
        advertisementData?[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
    }
    
    /// Signal strength indicator (RSSI) of the most recent advertisement
    public internal(set) var rssi: Int?
    
    /// Complete advertisement data dictionary from the most recent discovery
    public internal(set) var advertisementData: [String: Any]?
    
    /// The timestamp when the peripheral was last seen
    public internal(set) var lastSeen: Date?
    
    /// Create a peripheral with a unique identifier and optional CoreBluetooth peripheral data. The integrating app
    /// should use this initializer to create a `Peripheral` instance when it has a unique identifier for a peripheral
    /// but has not yet discovered the peripheral with CoreBluetooth. The ``PeripheralManager`` will update the instance
    /// with CoreBluetooth data when the peripheral is discovered.
    /// - Parameters:
    ///  - id: Unique identifier for the peripheral as set by the integrating app.
    ///  - peripheral: Reference to the CoreBluetooth `CBPeripheral` object
    ///  - advertisementData: Complete advertisement data dictionary from the most recent discovery
    ///  - rssi: Signal strength indicator (RSSI) of the most recent advertisement
    public init(id: String, peripheral: CBPeripheral? = nil, advertisementData: [String: Any]? = nil, rssi: Int? = nil) {
        self.id = id
        self.peripheralIdentifier = peripheral?.identifier
        self.peripheral = peripheral
        self.rssi = rssi
        self.advertisementData = advertisementData
        
        if peripheral != nil && rssi != nil {
            // Only set the last seen date if we have a valid CBPeripheral and RSSI value.
            // This indicates that we have received an advertisement from the peripheral.
            self.lastSeen = Date()
        }
    }
    
    func update(cbPeripheral: CBPeripheral, advertisementData: [String: Any]? = nil, rssi: Int? = nil) {
        self.peripheralIdentifier = cbPeripheral.identifier
        self.peripheral = cbPeripheral
        self.advertisementData = advertisementData
        self.rssi = rssi
        
        if rssi != nil {
            // Only set the last seen date if we have a valid RSSI value.
            // This indicates that we have received an advertisement from the peripheral.
            self.lastSeen = Date()
        }
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: Peripheral, rhs: Peripheral) -> Bool {
        // Original implementation: lhs.id == rhs.id
        
        // Two peripherals should be considered equal if they have the same identifier. However,
        // I have seen edge cases where the identifier did not change for a new CBPeripheral instance.
        // https://developer.apple.com/forums/thread/742497
        if lhs.id != rhs.id {
            return false
        }
        
        return lhs.peripheral === rhs.peripheral
    }
}
