//
//  ReliaBLEManager.swift
//  ReliaBLE
//
//  Created by Justin Bergen on 11/18/24.
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

@preconcurrency import Willow

/// The main entry point for the ReliaBLE library.
public class ReliaBLEManager {
    public let loggingService: LoggingService
    
    private let log: LoggingService
    
    public init(config: ReliaBLEConfig = ReliaBLEConfig()) {
        loggingService = LoggingService(levels: config.logLevels, writers: config.logWriters, queue: config.logQueue)
        loggingService.enabled = config.loggingEnabled
        
        log = loggingService
    }
    
    /// This is a test function that returns a string.
    /// - Returns: A string that says "Hello, this is ReliaBLE!"
    public func testFunction() -> String {
        log.debug(tags: [.category(.connection), .category(.scanning), .peripheral("123")], "testFunction() called")
        log.info(tags: [.category(.connection), .category(.scanning), .peripheral("123")], "testFunction() called")
        log.warn(tags: [.category(.connection), .category(.scanning), .peripheral("123")], "testFunction() called")
        log.error(tags: [.category(.connection), .category(.scanning), .peripheral("123")], "testFunction() called")
        
        return "Hello, this is ReliaBLE!"
    }
}
