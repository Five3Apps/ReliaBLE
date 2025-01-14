//
//  ReliaBLEConfig.swift
//  ReliaBLE
//
//  Created by Justin Bergen on 12/14/24.
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

@preconcurrency import Willow

/// The `LogLevel` struct defines all the default log levels for ReliaBLE. Each default log level has a defined bitmask
/// that is used to satisfy the raw value backing the log level.
public typealias LogLevel = Willow.LogLevel

public struct ReliaBLEConfig {
    public var logLevels = LogLevel.all
    public var logWriters: [LogWriter] = [OSLogWriter(subsystem: "com.five3apps.relia-ble", category: "BLE")]
    public var logQueue = DispatchQueue(label: "com.five3apps.relia-ble.logging", qos: .utility)
    public var loggingEnabled = false
    
    public init() {
        
    }
}
