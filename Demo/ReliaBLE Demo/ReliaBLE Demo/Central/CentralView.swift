//
//  CentralView.swift
//  ReliaBLE Demo
//
//  Created by Justin Bergen on 11/24/24.
//

import SwiftUI
import SwiftData

import ReliaBLE

struct CentralView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var devices: [Device]
    
    private var reliaBLE = ReliaBLE()

    var body: some View {
        NavigationSplitView {
            Text(reliaBLE.testFunction())
            
            List {
                ForEach(devices) { device in
                    NavigationLink {
                        Text("Device seen at \(device.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                    } label: {
                        Text(device.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                    }
                }
                .onDelete(perform: deleteDevices)
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
#endif
                ToolbarItem {
                    Button(action: addDevice) {
                        Label("Add Device", systemImage: "plus")
                    }
                }
            }
        } detail: {
            Text("Select an device")
        }
    }

    private func addDevice() {
        withAnimation {
            let newDevice = Device(timestamp: Date())
            modelContext.insert(newDevice)
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
        .modelContainer(for: Device.self, inMemory: true)
}
