//
//  AdvertisementData.swift
//  ReliaBLE
//
//  Created by Justin Bergen on 6/13/26.
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

/// A strongly-typed, `Sendable` snapshot of a peripheral's advertisement data.
///
/// CoreBluetooth surfaces advertisement data as a loosely-typed `[String: Any]` dictionary keyed by
/// `CBAdvertisementData*` constants. ``AdvertisementData`` extracts those values once, at discovery time and inside
/// the library's internal concurrency domain, so the untyped dictionary never crosses into the public surface.
///
/// - Note: This is a typed-only representation. Vendor-specific or otherwise non-standard advertisement keys are not
///   currently surfaced; a raw escape hatch may be added in a future release if needed.
public struct AdvertisementData: Sendable, Hashable {
    /// The local name of the peripheral, from `CBAdvertisementDataLocalNameKey`.
    public let localName: String?

    /// The advertised service UUIDs, from `CBAdvertisementDataServiceUUIDsKey`.
    public let serviceUUIDs: [CBUUID]

    /// The manufacturer-specific data, from `CBAdvertisementDataManufacturerDataKey`.
    public let manufacturerData: Data?

    /// The transmit power level, from `CBAdvertisementDataTxPowerLevelKey`.
    public let txPowerLevel: Int?

    /// Whether the advertising event is connectable, from `CBAdvertisementDataIsConnectable`.
    public let isConnectable: Bool?

    /// Service-specific advertisement data, keyed by service UUID, from `CBAdvertisementDataServiceDataKey`.
    public let serviceData: [CBUUID: Data]

    /// Service UUIDs found in the advertisement's overflow area, from `CBAdvertisementDataOverflowServiceUUIDsKey`.
    public let overflowServiceUUIDs: [CBUUID]

    /// Solicited service UUIDs, from `CBAdvertisementDataSolicitedServiceUUIDsKey`.
    public let solicitedServiceUUIDs: [CBUUID]

    /// Extracts a typed snapshot from CoreBluetooth's raw advertisement dictionary.
    ///
    /// This initializer is intentionally internal: the untyped `[String: Any]` should be extracted exactly once,
    /// inside the library, and never exposed to consumers.
    ///
    /// - Parameter rawAdvertisementData: The advertisement dictionary delivered by
    ///   `centralManager(_:didDiscover:advertisementData:rssi:)`.
    init(rawAdvertisementData: [String: Any]) {
        localName = rawAdvertisementData[CBAdvertisementDataLocalNameKey] as? String
        serviceUUIDs = rawAdvertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        manufacturerData = rawAdvertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        txPowerLevel = (rawAdvertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        isConnectable = (rawAdvertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        serviceData = rawAdvertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        overflowServiceUUIDs = rawAdvertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        solicitedServiceUUIDs = rawAdvertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? []
    }
}
