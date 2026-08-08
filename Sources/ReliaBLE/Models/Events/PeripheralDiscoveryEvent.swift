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

/// A lightweight, `Sendable` event emitted for each advertisement received while scanning.
public struct PeripheralDiscoveryEvent: Identifiable, Hashable, Sendable {
    /// CoreBluetooth `UUID` identifier assigned by the system.
    ///
    /// This is **not** the app-facing peripheral identifier (which is a `String` carried by
    /// ``Peripheral/id`` and ``DiscoveredPeripheral/id``). Until FR-8.5 provides direct
    /// advertisement-to-id correlation, map via ``DiscoveredPeripheral`` or its
    /// ``DiscoveredPeripheral/peripheral`` handle.
    public let id: UUID

    /// The name advertised by the peripheral, if available
    public let name: String?
    
    /// Signal strength indicator (RSSI)
    public let rssi: Int
    
    /// The typed advertisement data from this discovery.
    public let advertisement: AdvertisementData
    
    /// Create a discovered peripheral event from CoreBluetooth information.
    ///
    /// - Parameters:
    ///   - cbPeripheral: The CoreBluetooth peripheral.
    ///   - advertisement: Parsed advertisement data.
    ///   - rssi: Signal strength of the advertisement.
    init(cbPeripheral: CBPeripheral, advertisement: AdvertisementData, rssi: Int) {
        self.id = cbPeripheral.identifier
        self.name = cbPeripheral.name ?? advertisement.localName
        self.rssi = rssi
        self.advertisement = advertisement
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
