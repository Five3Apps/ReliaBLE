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

enum LogTag {
    enum Category: String {
        case scanning
        case connection
    }
    
    case category(Category)
    case peripheral(String)

    var attribute: (key: String, value: String) {
        switch self {
        case .peripheral(let peripheralId):
            return ("Peripheral", peripheralId)
        case .category(let category):
            return ("Category", category.rawValue)
        }
    }
}

struct LogMessage: Willow.LogMessage {
    var tags: [LogTag]?
    var message: String
    
    // MARK: - LogMessage
    
    var name: String {
        message
    }
    
    var attributes: [String : Any] {
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
            result["Category"] = categories.joined(separator: ",")
        }

        return result
    }
}
