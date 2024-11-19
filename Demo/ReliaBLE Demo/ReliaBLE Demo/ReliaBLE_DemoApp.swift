//
//  ReliaBLE_DemoApp.swift
//  ReliaBLE Demo
//
//  Created by Justin Bergen on 11/18/24.
//

import SwiftUI
import SwiftData

@main
struct ReliaBLE_DemoApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Device.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
