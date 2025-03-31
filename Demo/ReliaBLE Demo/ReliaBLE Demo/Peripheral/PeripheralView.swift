//
//  PeripheralView.swift
//  ReliaBLE Demo
//
//  Created by Justin Bergen on 11/24/24.
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

// Default values for demo purposes
private let defaultPeripheralName = "ReliaBLE Demo"
private let defaultServiceUUID = "12345678-90AB-CDEF-1234-567890ABCDEF"

struct PeripheralView: View {
    @StateObject private var peripheralManager = PeripheralManager()
    @State private var peripheralName: String = defaultPeripheralName
    @State private var serviceUUIDString: String = defaultServiceUUID

    var serviceUUID: CBUUID? {
        let uuidString = serviceUUIDString
        // Accept 128-bit UUIDs
        if let uuid = UUID(uuidString: uuidString) {
            return CBUUID(string: uuid.uuidString)
        }
        // Accept 16-bit (4 hex digits) or 32-bit (8 hex digits) UUIDs
        else if (uuidString.count == 4 || uuidString.count == 8),
                uuidString.allSatisfy({ char in
                    ("0"..."9").contains(char) || ("A"..."F").contains(char) || ("a"..."f").contains(char)
                })
        {
            return CBUUID(string: uuidString)
        }
        return nil
    }

    var isValid: Bool {
        // Valid if peripheralName is not empty and serviceUUID is a valid format
        return !peripheralName.isEmpty && serviceUUID != nil
    }

    var body: some View {
        Form {
            Section(header: Text("Peripheral Settings")) {
                HStack {
                    TextField("Peripheral Name", text: $peripheralName)
                    if !peripheralName.isEmpty {
                        Button(action: {
                            peripheralName = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                        .accessibilityLabel("Clear peripheral name")
                    }
                }
                .disabled(peripheralManager.isAdvertising)

                HStack {
                    TextField("Service UUID (e.g., 180F or 128-bit)", text: $serviceUUIDString)
                    if !serviceUUIDString.isEmpty {
                        Button(action: {
                            serviceUUIDString = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                        .accessibilityLabel("Clear service UUID")
                    }
                }
                .disabled(peripheralManager.isAdvertising)

                if !serviceUUIDString.isEmpty && serviceUUID == nil {
                    Text("Invalid UUID (use 4, 8, or 36 chars)").foregroundColor(.red)
                }
            }
            Section {
                Button("Start Advertising") {
                    if let uuid = serviceUUID {
                        peripheralManager.startAdvertising(name: peripheralName, serviceUUID: uuid)
                    }
                }
                .disabled(!isValid || peripheralManager.state != .poweredOn || peripheralManager.isAdvertising)
                Button("Stop Advertising") {
                    peripheralManager.stopAdvertising()
                }
                .disabled(!peripheralManager.isAdvertising)
            }
            Section(header: Text("Status")) {
                Text("State: \(peripheralManager.state.description)")
                Text(peripheralManager.isAdvertising ? "Advertising" : "Not Advertising")
            }
        }
        .navigationTitle("Peripheral Mode")
    }
}

extension CBManagerState {
    var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .resetting: return "Resetting"
        case .unsupported: return "Unsupported"
        case .unauthorized: return "Unauthorized"
        case .poweredOff: return "Powered Off"
        case .poweredOn: return "Powered On"
        @unknown default: return "Unknown"
        }
    }
}

#Preview {
    PeripheralView()
}
