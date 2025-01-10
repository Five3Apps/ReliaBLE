//
//  LoggingService.swift
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

/// Service for managing all logging within ReliaBLE.
public class LoggingService {
    let willowLogger: Logger
    
    init(levels: LogLevel, writers: [LogWriter], queue: DispatchQueue) {
        willowLogger = Logger(
            logLevels: levels,
            writers: writers,
            executionMethod: .asynchronous(queue: queue)
        )
    }
    
    /// Controls whether to allow log messages to be sent to the writers.
    public var enabled: Bool {
        get { willowLogger.enabled }
        set { willowLogger.enabled = newValue }
    }
}
