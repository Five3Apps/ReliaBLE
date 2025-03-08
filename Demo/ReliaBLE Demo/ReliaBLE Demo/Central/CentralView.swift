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
    
    @StateObject private var viewModel = CentralViewModel()
    
    var body: some View {
        NavigationSplitView {
            Text("ReliaBLE state: \(viewModel.currentState.description)")
            
            if case BluetoothState.unauthorized(let authState) = viewModel.currentState, authState == .notDetermined {
                Button("Authorize Bluetooth") {
                    viewModel.authorizeBluetooth()
                }
                .buttonStyle(.bordered)
            } else if case BluetoothState.ready = viewModel.currentState {
                TextField("Enter service UUIDs (comma-separated)", text: $viewModel.servicesInput)
                    .textFieldStyle(.roundedBorder)
                    .padding()
                
                Button("Start Scanning") {
                    viewModel.startScanning()
                }
                .buttonStyle(.bordered)
            } else if case BluetoothState.scanning = viewModel.currentState {
                Button("Stop Scanning") {
                    viewModel.stopScanning()
                }
                .buttonStyle(.bordered)
            }
            
            Button(viewModel.logsButtonTitle) {
                viewModel.toggleLogging()
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
                .onDelete { offsets in
                    let itemsToDelete = offsets.map { discoveries[$0] }
                    viewModel.deleteDiscoveries(itemsToDelete)
                }
            }
            .onAppear {
                viewModel.setDependencies(modelContext: modelContext, reliaBLE: reliaBLE)
            }
            .onDisappear {
                viewModel.cancellables.removeAll()
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear All") {
                        viewModel.clearAllData()
                    }
                }
#endif
            }
        } detail: {
            Text("Select a device")
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
