//
//  Device.swift
//  ReliaBLE Demo
//
//  Created by Justin Bergen on 11/18/24.
//

import Foundation
import SwiftData

@Model
final class Device {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
