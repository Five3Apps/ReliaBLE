import Combine
import CoreBluetooth
import SwiftData
import SwiftUI

import ReliaBLE

class CentralViewModel: ObservableObject {
    @Published var currentState: BluetoothState = .unknown
    @Published var logsButtonTitle = "Disable Logging"
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
    
    func toggleLogging() {
        if logsButtonTitle == "Enable Logging" {
            reliaBLE?.loggingService.enabled = true
            logsButtonTitle = "Disable Logging"
        } else {
            reliaBLE?.loggingService.enabled = false
            logsButtonTitle = "Enable Logging"
        }
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
