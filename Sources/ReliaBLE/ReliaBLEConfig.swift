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

/// The `ReliaBLEConfig` struct defines the configuration options for the ReliaBLE library. This struct is used to
/// configure the logging service used by ReliaBLE.
public struct ReliaBLEConfig {
    /// The log levels to that will be send to ``logWriters`` for logging. The default value is all log levels.
    public var logLevels = LogLevel.all

    /// The log writers that will receive log messages. The default value is a single ``OSLogWriter`` with the subsystem
    /// "com.five3apps.relia-ble" and the category "BLE".
    public var logWriters: [LogWriter] = [OSLogWriter(subsystem: "com.five3apps.relia-ble", category: "BLE")]

    /// The queue that will be used for processing log messages. The default value is a utility queue with the label
    /// "com.five3apps.relia-ble.logging".
    public var logQueue = DispatchQueue(label: "com.five3apps.relia-ble.logging", qos: .utility)
    
    /// Whether or not logging is enabled. The default value is `false`.
    public var loggingEnabled = false
    
    /// Initializes a new `ReliaBLEConfig` instance with the default values.
    public init() {
        
    }
}
