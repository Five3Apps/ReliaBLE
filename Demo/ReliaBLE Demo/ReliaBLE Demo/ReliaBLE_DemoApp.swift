//
//  ReliaBLE_DemoApp.swift
//  ReliaBLE Demo
//
//  Created by Justin Bergen on 11/18/24.
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

import SwiftUI
import SwiftData
import ReliaBLE

private struct BLEManagerKey: EnvironmentKey {
    static let defaultValue: ReliaBLEManager = ReliaBLEManager(config: ReliaBLEConfig())
}

extension EnvironmentValues {
    var bleManager: ReliaBLEManager {
        get { self[BLEManagerKey.self] }
        set { self[BLEManagerKey.self] = newValue }
    }
}

@main
struct ReliaBLE_DemoApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Device.self,
            DiscoveryEvent.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    var reliaBLE: ReliaBLEManager = {
        var config = ReliaBLEConfig()
        // Uncomment to disable debug level logs
//        config.logLevels = [LogLevel.info, LogLevel.warn, LogLevel.error]
        config.logWriters = [OSLogWriter(subsystem: "com.five3apps.relia-ble-demo", category: "BLE")]
        config.logQueue = DispatchQueue(label: "com.five3apps.relia-ble-demo.logging", qos: .utility)
        config.loggingEnabled = true
        
        return ReliaBLEManager(config: config)
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .environment(\.bleManager, reliaBLE)
    }
}
