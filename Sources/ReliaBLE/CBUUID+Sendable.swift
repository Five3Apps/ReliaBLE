//
//  CBUUID+Sendable.swift
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

// `CBUUID` is effectively immutable after initialization — it wraps a fixed 16-, 32-, or 128-bit
// Bluetooth UUID and exposes no mutating API. Marking it `@unchecked Sendable` lets value types that
// store `CBUUID` (notably ``AdvertisementData``) be `Sendable` and cross the ``BluetoothActor`` boundary.
//
// This declaration lives in the shared source tree, so in the `ReliaBLEMock` target it applies to
// `CBMUUID` via the `CBUUID = CBMUUID` typealias. If a future version of CoreBluetoothMock declares
// `CBMUUID: Sendable` upstream, this becomes a redundant-conformance error in that target only; guard
// it per target at that point.
extension CBUUID: @retroactive @unchecked Sendable {}
