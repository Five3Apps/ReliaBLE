//
//  DeviceStoreActor.swift
//  ReliaBLE Demo
//
//  Copyright (c) 2025 Five3 Apps, LLC <justin@five3apps.com>
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
import SwiftData

import ReliaBLE

/// Canonical off-main SwiftData persistence for ReliaBLE discovery events.
///
/// Copy this pattern when building a real app:
/// - Hold `ReliaBLEManager` on the main actor (or inject via SwiftUI environment).
/// - Consume `AsyncStream` surfaces in `.task { for await … }`.
/// - Create the store with ``create(container:)`` so SwiftData's `ModelActor` runs off the main thread.
/// - Route every SwiftData write through this actor; keep reads on `@MainActor` via `@Query`.
actor DeviceStoreActor: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        let modelContext = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.modelContainer = modelContainer
    }

    /// Creates a background-isolated store. Safe to call from `@MainActor` (e.g. SwiftUI `.task`);
    /// construction is explicitly detached so `ModelActor` does not inherit main-thread execution.
    static nonisolated func create(container: ModelContainer) async -> DeviceStoreActor {
        await Task.detached {
            DeviceStoreActor(modelContainer: container)
        }.value
    }

    func insertDiscovery(_ discoveryEvent: PeripheralDiscoveryEvent) {
        assertWritesOffMainThread()

        let event = DiscoveryEvent(
            peripheralIdentifier: discoveryEvent.id.uuidString,
            name: discoveryEvent.name ?? "Unknown",
            rssi: discoveryEvent.rssi,
            timestamp: Date()
        )
        modelContext.insert(event)
        try? modelContext.save()
    }

    func syncDevices(_ peripherals: [Peripheral]) {
        assertWritesOffMainThread()

        do {
            let allDevices = try modelContext.fetch(FetchDescriptor<Device>())
            for peripheral in peripherals {
                if let existingDevice = allDevices.first(where: { $0.id == peripheral.id }) {
                    existingDevice.name = peripheral.name
                    existingDevice.lastSeen = peripheral.lastSeen
                } else {
                    let newDevice = Device(id: peripheral.id, name: peripheral.name, lastSeen: peripheral.lastSeen)
                    modelContext.insert(newDevice)
                }
            }
            try modelContext.save()
        } catch {
            print("Error fetching devices: \(error)")
        }
    }

    func clearAll() {
        assertWritesOffMainThread()

        do {
            let discoveries = try modelContext.fetch(FetchDescriptor<DiscoveryEvent>())
            discoveries.forEach { modelContext.delete($0) }

            let devices = try modelContext.fetch(FetchDescriptor<Device>())
            devices.forEach { modelContext.delete($0) }

            try modelContext.save()
        } catch {
            print("Failed to clear data: \(error)")
        }
    }

    func deleteDiscoveries(ids: [PersistentIdentifier]) {
        assertWritesOffMainThread()
        guard !ids.isEmpty else { return }

        let idSet = Set(ids)
        do {
            let events = try modelContext.fetch(FetchDescriptor<DiscoveryEvent>())
            for event in events where idSet.contains(event.persistentModelID) {
                modelContext.delete(event)
            }
            try modelContext.save()
        } catch {
            print("Failed to delete discoveries: \(error)")
        }
    }

    func deleteDevices(ids: [PersistentIdentifier]) {
        assertWritesOffMainThread()
        guard !ids.isEmpty else { return }

        let idSet = Set(ids)
        do {
            let devices = try modelContext.fetch(FetchDescriptor<Device>())
            for device in devices where idSet.contains(device.persistentModelID) {
                modelContext.delete(device)
            }
            try modelContext.save()
        } catch {
            print("Failed to delete devices: \(error)")
        }
    }

    private func assertWritesOffMainThread() {
        #if DEBUG
        assert(!Thread.isMainThread, "SwiftData writes must run off the main thread")
        #endif
    }
}