//
//  CentralView.swift
//  ReliaBLE Demo
//
//  Created by Justin Bergen on 11/24/24.
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
import SwiftUI
import SwiftData

import ReliaBLE

struct CentralView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.bleManager) private var reliaBLE
    
    @Query private var discoveries: [DiscoveryEvent]
    @Query private var devices: [Device]
    
    @State private var logsButtonTitle = "Disable Logging"
    @State private var currentState: BluetoothState = .unknown
    @State private var cancellables = Set<AnyCancellable>()
    @State private var servicesInput: String = ""
    
    var body: some View {
        NavigationSplitView {
            if let reliaBLE {
                Text("ReliaBLE state: \(currentState.description)")
                    .onReceive(reliaBLE.state.receive(on: DispatchQueue.main)) { newState in
                        self.currentState = newState
                    }
            }
            
            if case BluetoothState.unauthorized(let authState) = currentState, authState == .notDetermined {
                Button("Authorize Bluetooth") {
                    try? reliaBLE?.authorizeBluetooth()
                }
                .buttonStyle(.bordered)
            } else if case BluetoothState.ready = currentState {
                TextField("Enter service UUIDs (comma-separated)", text: $servicesInput)
                    .textFieldStyle(.roundedBorder)
                    .padding()
                
                Button("Start Scanning") {
                    let services = parseServices(from: servicesInput)
                    reliaBLE?.startScanning(services: services)
                }
                .buttonStyle(.bordered)
            } else if case BluetoothState.scanning = currentState {
                Button("Stop Scanning") {
                    reliaBLE?.stopScanning()
                }
                .buttonStyle(.bordered)
            }
            
            Button(logsButtonTitle) {
                if logsButtonTitle == "Enable Logging" {
                    reliaBLE?.loggingService.enabled = true
                    logsButtonTitle = "Disable Logging"
                } else {
                    reliaBLE?.loggingService.enabled = false
                    logsButtonTitle = "Enable Logging"
                }
            }
            .buttonStyle(.bordered)
            
            List {
                ForEach(discoveries) { discoveryEvent in
                    let timestampString = discoveryEvent.timestamp.formatted(date: .numeric, time: .standard)
                    let deviceName = discoveryEvent.name
                    
                    NavigationLink {
                        Text("Device \(deviceName) seen at \(timestampString): \(discoveryEvent.rssi) dBm")
                    } label: {
                        Text("Device \(deviceName) seen at \(timestampString): \(discoveryEvent.rssi) dBm")
                    }
                }
                .onDelete(perform: deleteDiscoveries)
            }
            .onAppear {
                subscribeToDiscoveryEvents()
            }
            .onDisappear {
                cancellables.removeAll()
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear All") {
                        clearAllData()
                    }
                }
#endif
            }
        } detail: {
            Text("Select a device")
        }
    }
    
    // MARK: - Private Helpers
    
    private func parseServices(from input: String) -> [CBUUID]? {
        let components = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let uuids = components.filter { !$0.isEmpty }.map { CBUUID(string: $0) }
        
        return uuids.isEmpty ? nil : uuids
    }
    
    private func subscribeToDiscoveryEvents() {
        reliaBLE?.peripheralDiscoveries
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
    
    private func clearAllData() {
        withAnimation {
            discoveries.forEach { modelContext.delete($0) }
            devices.forEach { modelContext.delete($0) }
            try? modelContext.save()
        }
    }
    
    private func deleteDiscoveries(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(discoveries[index])
            }
            try? modelContext.save()
        }
    }
    
    private func deleteDevices(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(devices[index])
            }
        }
    }
}

#Preview {
    CentralView()
        .modelContainer(
            for: [Device.self, DiscoveryEvent.self],
            inMemory: true
        )
}
