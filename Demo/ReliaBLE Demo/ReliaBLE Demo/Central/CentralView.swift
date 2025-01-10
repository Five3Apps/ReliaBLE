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

import SwiftUI
import SwiftData

import ReliaBLE

struct CentralView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.bleManager) private var reliaBLE
    
    @Query private var devices: [Device]
    
    @State private var logsButtonTitle = "Disable Logging"
    
    var body: some View {
        NavigationSplitView {
            Button("Call Test Function") {
                _ = reliaBLE?.testFunction()
            }
            .buttonStyle(.bordered)
            
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
