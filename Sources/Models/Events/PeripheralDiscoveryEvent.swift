//
//  PeripheralDiscoveryEvent.swift
//  ReliaBLE
//
//  Created by Justin Bergen on 3/6/25.
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
import CoreBluetooth

/// A representation of a discovered Bluetooth peripheral with metadata.
public struct PeripheralDiscoveryEvent: Identifiable, Hashable {
    /// Unique identifier for the peripheral as set by CoreBluetooth
    public let id: UUID
    
    /// The name advertised by the peripheral, if available
    public let name: String?
    
    /// Advertised service UUIDs
    public var serviceUUIDs: [CBUUID]? {
        advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
    }
    
    /// Signal strength indicator (RSSI)
    public let rssi: Int
    
    /// Complete advertisement data dictionary from the most recent discovery
    public let advertisementData: [String: Any]
    
    /// Create a discovered peripheral from CoreBluetooth information
    init(peripheral: CBPeripheral, advertisementData: [String: Any], rssi: Int) {
        self.id = peripheral.identifier
        self.name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        self.rssi = rssi
        self.advertisementData = advertisementData
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: PeripheralDiscoveryEvent, rhs: PeripheralDiscoveryEvent) -> Bool {
        // Two peripherals should be considered equal if they have the same identifier. However,
        // I have seen edge cases where the identifier did not change for a new CBPeripheral instance.
        // https://developer.apple.com/forums/thread/742497
        
        lhs.id == rhs.id
    }
}
