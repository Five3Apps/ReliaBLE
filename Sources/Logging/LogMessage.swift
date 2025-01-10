//
//  LogMessage.swift
//  ReliaBLE
//
//  Created by Justin Bergen on 12/15/24.
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

@preconcurrency import Willow

/// An enumeration representing defined tags that can be associated with log messages. These are used
/// to categorize log messages for better organization and filtering.
public enum LogTag {
    /// A tag representing a specific category the log message relates to. See ``Category`` for more details.
    case category(Category)
    /// A tag representing a specific peripheral device, identified by its unique identifier.
    case peripheral(String)
    
    /// A special tag representing a specific category of log messages, such as "scanning" or "connection".
    /// Log messages can have multiple category tags but that should be the exception rather than the rule.
    public enum Category: String {
        case scanning
        case connection
    }
    
    /// A convenience property that returns the tag as a key/value tuple to be used in ``LogMessage.attributes``.
    var attribute: (key: String, value: String) {
        switch self {
        case .peripheral(let peripheralId):
            return ("Peripheral", peripheralId)
        case .category(let category):
            return ("Category", category.rawValue)
        }
    }
}

/// A message structure that conforms to Willow's LogMessage protocol for structured logging.
/// Contains optional tags for categorization and metadata, along with the main message content.
public struct LogMessage: Willow.LogMessage {
    var tags: [LogTag]?
    var message: String
    
    // MARK: - Willow.LogMessage Conformance
    
    /// The name of the log message, which returns the message content.
    public var name: String {
        message
    }
    
    /// A dictionary of attributes associated with the log message. Converts any tags into a
    /// dictionary format to be used as attributes in the log message. "Categories" contains a
    /// comma-separated list of all category tags and other keys contain their respective tag
    ///  values.
    /// - Returns: A dictionary containing tag attributes.
    public var attributes: [String : Any] {
        guard let tags else {
            return [:]
        }

        var result: [String: Any] = [:]
        var categories: [String] = []

        for tag in tags {
            let (key, value) = tag.attribute
            if key == "Category" {
                categories.append(value)
            } else {
                result[key] = value
            }
        }

        if !categories.isEmpty {
            result["Categories"] = categories.joined(separator: ", ")
        }

        return result
    }
}
