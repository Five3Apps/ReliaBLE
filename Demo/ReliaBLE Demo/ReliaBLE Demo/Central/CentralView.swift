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

import CoreBluetooth
import SwiftUI
import SwiftData

import ReliaBLE

extension ConnectionState {
    var description: String {
        switch self {
        case .connecting: "Connecting"
        case .reconnecting(let source, let attempt, _):
            switch source {
            case .system: "System reconnecting…"
            case .library: "Reconnecting (attempt \(attempt ?? 0))"
            }
        case .connected: "Connected"
        case .disconnecting: "Disconnecting"
        case .disconnected(let reason): "Disconnected\(reason.map { " (\($0))" } ?? "")"
        case .failed(let reason): "Failed\(reason.map { " (\($0))" } ?? "")"
        }
    }

    var nextRetryAt: Date? {
        if case .reconnecting(_, _, let date) = self { return date }
        return nil
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .reconnecting: .yellow
        case .disconnected(let reason): reason == nil ? .secondary : .orange
        case .failed: .red
        default: .orange
        }
    }

    /// True when a connection is active or in progress (including reconnect).
    var isActiveConnection: Bool {
        switch self {
        case .connecting, .connected, .disconnecting, .reconnecting:
            true
        case .disconnected, .failed:
            false
        }
    }

    /// Auto-reconnect can only be changed when initiating a fresh connect.
    var canEditAutoReconnect: Bool {
        !isActiveConnection
    }
}

struct CentralView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.bleManager) private var reliaBLE

    @Query private var discoveries: [DiscoveryEvent]
    @Query private var devices: [Device]

    @State private var viewModel = CentralViewModel()
    @State private var selectedView: String = "Devices"

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

            Picker("Select View", selection: $selectedView) {
                Text("Devices").tag("Devices")
                Text("Discoveries").tag("Discoveries")
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()

            Group {
                if selectedView == "Devices" {
                    deviceList
                } else {
                    discoveriesList
                }
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
        .task {
            let manager = reliaBLE
            let store = await DeviceStoreActor.create(container: modelContext.container)
            viewModel.setDependencies(deviceStore: store, reliaBLE: manager)

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await state in manager.state {
                        await viewModel.updateState(state)
                    }
                }
                group.addTask {
                    for await discoveryEvent in manager.peripheralDiscoveries {
                        await store.insertDiscovery(discoveryEvent)
                    }
                }
                group.addTask {
                    for await peripherals in manager.discoveredPeripherals {
                        await store.syncDevices(peripherals)
                    }
                }
                group.addTask {
                    for await change in manager.connectionStateChanges {
                        await viewModel.updateConnectionState(change)
                    }
                }
            }
        }
    }

    private var deviceList: some View {
        List {
            ForEach(devices, id: \.persistentModelID) { device in
                NavigationLink {
                    DeviceDetailView(
                        device: device,
                        viewModel: viewModel,
                        reliaBLE: reliaBLE
                    )
                } label: {
                    Text("\(device.name ?? "Unknown")")
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { devices[$0].persistentModelID }
                viewModel.deleteDevices(ids: ids)
            }
        }
    }

    private var discoveriesList: some View {
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
                let ids = offsets.map { discoveries[$0].persistentModelID }
                viewModel.deleteDiscoveries(ids: ids)
            }
        }
    }
}

private struct DeviceDetailView: View {
    let device: Device
    let viewModel: CentralViewModel
    let reliaBLE: ReliaBLEManager

    @State private var autoReconnect = true

    private var connectionState: ConnectionState? {
        viewModel.connectionStates[device.id]
    }

    private var isActive: Bool {
        connectionState?.isActiveConnection == true
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("ID: \(device.id)")
            Text("Last seen: \(device.lastSeen?.formatted(date: .numeric, time: .standard) ?? "")")

            if let state = connectionState {
                Text("Connection: \(state.description)")
                    .foregroundStyle(state.color)

                if let retryAt = state.nextRetryAt {
                    CountdownView(targetDate: retryAt)
                }
            } else {
                Text("Connection: unknown")
                    .foregroundStyle(.secondary)
            }

            Button(action: {
                if isActive {
                    Task { try? await reliaBLE.disconnect(from: Peripheral(id: device.id)) }
                } else {
                    Task {
                        try? await reliaBLE.connect(
                            to: Peripheral(id: device.id),
                            autoReconnect: autoReconnect
                        )
                    }
                }
            }) {
                Text(isActive ? "Disconnect" : "Connect")
            }
            .buttonStyle(.bordered)

            Toggle("Auto Reconnect:", isOn: $autoReconnect)
                .disabled(connectionState.map { !$0.canEditAutoReconnect } ?? false)
        }
        .padding()
    }
}

private struct CountdownView: View {
    let targetDate: Date

    @State private var now = Date()

    var body: some View {
        let remaining = max(0, targetDate.timeIntervalSince(now))
        Text("Next retry in: \(Int(remaining))s")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                now = Date()
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
