//
//  LogWriters.swift
//  ReliaBLE
//
//  Created by Justin Bergen on 12/19/24.
//
//  Copyright (c) 2024 Five3 Apps, LLC <justin@five3apps.com>
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
import os

@preconcurrency import Willow

/// The OSLogWriter class runs all modifiers in the order they were created and passes the resulting message
/// off to an OSLog with the specified subsystem and category.
public class OSLogWriter: LogModifierWriter {
    public let subsystem: String
    public let category: String

    /// Array of modifiers that the writer should execute (in order) on incoming messages.
    public let modifiers: [LogModifier]

    private let log: OSLog

    /// Creates an `OSLogWriter` instance from the specified `subsystem` and `category`.
    ///
    /// - Parameters:
    ///   - subsystem: The subsystem.
    ///   - category:  The category.
    public init(subsystem: String, category: String, modifiers: [LogModifier] = []) {
        self.subsystem = subsystem
        self.category = category
        self.modifiers = modifiers
        self.log = OSLog(subsystem: subsystem, category: category)
    }

    /// Writes the message to the `OSLog` using the `os_log` function.
    ///
    /// Each modifier is run over the message in the order they are provided before writing the message to
    /// the console.
    ///
    /// - Parameters:
    ///   - message:   The original message to write to the console.
    ///   - logLevel:  The log level associated with the message.
    ///   - logSource:  The souce of the log message.
    public func writeMessage(_ message: String, logLevel: LogLevel, logSource: LogSource) {
        let message = modifyMessage(message, logLevel: logLevel, logSource: logSource)
        let type = logType(forLogLevel: logLevel)

        os_log("%@", log: log, type: type, message)
    }

    /// Writes the breadrumb to the `OSLog` using the `os_log` function.
    ///
    /// Each modifier is run over the breadrumb in the order they are provided before writing the breadrumb to
    /// the console.
    ///
    /// - Parameters:
    ///   - message:   The original breadrumb to write to the console
    ///   - logLevel:  The log level associated with the message.
    ///   - logSource:  The souce of the log message.
    public func writeMessage(_ message: Willow.LogMessage, logLevel: LogLevel, logSource: LogSource) {
        var tagsString = ""
        for attribute in message.attributes {
            tagsString += "[\(attribute.key): \(attribute.value)]"
        }
        tagsString += message.attributes.count > 0 ? " " : ""
        
        let message = modifyMessage("\(tagsString)\(message.name)", logLevel: logLevel, logSource: logSource)
        let type = logType(forLogLevel: logLevel)

        os_log("%@", log: log, type: type, message)
    }

    /// Returns the `OSLogType` to use for the specified `LogLevel`.
    ///
    /// - Parameter logLevel: The level to be map to a `OSLogType`.
    ///
    /// - Returns: An `OSLogType` corresponding to the `LogLevel`.
    public func logType(forLogLevel logLevel: LogLevel) -> OSLogType {
        switch logLevel {
        case LogLevel.debug: return .debug
        case LogLevel.info:  return .info
        case LogLevel.warn:  return .default
        case LogLevel.error: return .error
        default:             return .default
        }
    }
}
