//
//  PeripheralError.swift
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

/// Errors thrown by peripheral operations such as ``ReliaBLEManager/connect(to:)``.
public enum PeripheralError: Error, Sendable, Equatable {
    /// The peripheral is no longer known to the library.
    ///
    /// A ``Peripheral`` is a value snapshot captured at discovery time. The live CoreBluetooth peripheral it refers to
    /// is held internally by the library keyed by ``Peripheral/id``. If that reference has since been invalidated (for
    /// example, after Bluetooth reset) the snapshot is stale and operations that require the live peripheral throw
    /// this error.
    case notFound

    /// Bluetooth is unavailable, so the operation could not be performed.
    ///
    /// Thrown when a peripheral operation is attempted before the underlying `CBCentralManager` exists — for example,
    /// because Bluetooth has not been authorized yet. Call ``ReliaBLEManager/authorizeBluetooth()`` and wait for a
    /// ready state before retrying.
    case bluetoothUnavailable

    /// The connection to the peripheral failed.
    case connectionFailed

    /// The connection attempt timed out.
    case connectionTimeout

    /// The peripheral disconnected unexpectedly.
    case peripheralDisconnected

    /// An unknown CoreBluetooth error occurred.
    case unknown

    /// Maps a `CBError` to a ``PeripheralError`` for public surfacing.
    ///
    /// The mapper is exhaustive — unrecognized codes fall back to ``unknown``.
    static func fromCBError(_ error: CBError) -> PeripheralError {
        switch error.code {
        case .connectionFailed: return .connectionFailed
        case .connectionTimeout: return .connectionTimeout
        case .peripheralDisconnected: return .peripheralDisconnected
        default: return .unknown
        }
    }
}
