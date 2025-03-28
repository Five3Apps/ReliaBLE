//
//  CentralViewModel.swift
//  ReliaBLE Demo
//
//  Created by Justin Bergen on 3/8/25.
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

import Combine
import CoreBluetooth
import SwiftData
import SwiftUI

import ReliaBLE

class CentralViewModel: ObservableObject {
    @Published var currentState: BluetoothState = .unknown
    @Published var servicesInput = ""
    
    var cancellables = Set<AnyCancellable>()
    
    private var modelContext: ModelContext?
    private var reliaBLE: ReliaBLEManager?
    
    func setDependencies(modelContext: ModelContext, reliaBLE: ReliaBLEManager) {
        self.modelContext = modelContext
        self.reliaBLE = reliaBLE
        
        setupSubscriptions()
    }
    
    private func setupSubscriptions() {
        guard let reliaBLE = reliaBLE, let modelContext = modelContext else { return }
        
        reliaBLE.state
            .receive(on: DispatchQueue.main)
            .assign(to: \.currentState, on: self)
            .store(in: &cancellables)
        
        reliaBLE.peripheralDiscoveries
            .receive(on: DispatchQueue.main)
            .sink { discoveryEvent in
                let event = DiscoveryEvent(
                    peripheralIdentifier: discoveryEvent.id.uuidString,
                    name: discoveryEvent.name ?? "Unknown",
                    rssi: discoveryEvent.rssi,
                    timestamp: Date()
                )
                modelContext.insert(event)
                try? modelContext.save()
            }
            .store(in: &cancellables)

        reliaBLE.discoveredPeripherals
            .receive(on: DispatchQueue.main)
            .sink { peripherals in
                do {
                    let allDevices = try modelContext.fetch(FetchDescriptor<Device>())
                    for peripheral in peripherals {
                        if let existingDevice = allDevices.first(where: { $0.id == peripheral.id }) {
                            existingDevice.name = peripheral.name
                            existingDevice.lastSeen = peripheral.lastSeen
                        } else {
                            let newDevice = Device(id: peripheral.id, name: peripheral.name, lastSeen: Date())
                            modelContext.insert(newDevice)
                        }
                    }
                    try modelContext.save()
                } catch {
                    print("Error fetching devices: \(error)")
                }
            }
            .store(in: &cancellables)
    }
    
    func authorizeBluetooth() {
        try? reliaBLE?.authorizeBluetooth()
    }
    
    func startScanning() {
        let services = parseServices(from: servicesInput)
        reliaBLE?.startScanning(services: services)
    }
    
    func stopScanning() {
        reliaBLE?.stopScanning()
    }
    
    func clearAllData() {
        guard let modelContext = modelContext else { return }
        
        do {
            let discoveryDescriptor = FetchDescriptor<DiscoveryEvent>(sortBy: [])
            let discoveries = try modelContext.fetch(discoveryDescriptor)
            discoveries.forEach { modelContext.delete($0) }
            
            let deviceDescriptor = FetchDescriptor<Device>(sortBy: [])
            let devices = try modelContext.fetch(deviceDescriptor)
            devices.forEach { modelContext.delete($0) }
            
            try modelContext.save()
        } catch {
            print("Failed to clear data: \(error)")
        }
    }
    
    func deleteDiscoveries(_ items: [DiscoveryEvent]) {
        items.forEach { modelContext?.delete($0) }
        try? modelContext?.save()
    }
    
    func deleteDevices(_ items: [Device]) {
        items.forEach { modelContext?.delete($0) }
        try? modelContext?.save()
    }
    
    private func parseServices(from input: String) -> [CBUUID]? {
        let components = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let uuids = components.filter { !$0.isEmpty }.map { CBUUID(string: $0) }
        
        return uuids.isEmpty ? nil : uuids
    }
}
