//
//  PeripheralManager.swift
//  ReliaBLE Demo
//
//  Created by Justin Bergen on 3/30/25.
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

class PeripheralManager: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    @Published var state: CBManagerState = .unknown
    @Published var isAdvertising: Bool = false
    private var peripheralManager: CBPeripheralManager!
    private var peripheralName: String = ""
    private var serviceUUID: CBUUID?

    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func startAdvertising(name: String, serviceUUID: CBUUID) {
        self.peripheralName = name
        self.serviceUUID = serviceUUID
        peripheralManager.removeAllServices()
        let service = CBMutableService(type: serviceUUID, primary: true)
        peripheralManager.add(service)
    }

    func stopAdvertising() {
        peripheralManager.stopAdvertising()
        isAdvertising = false
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        state = peripheral.state
        if state != .poweredOn {
            isAdvertising = false
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            print("Failed to add service: \(error.localizedDescription)")
            return
        }
        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: peripheralName,
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID!]
        ]
        peripheralManager.startAdvertising(advertisementData)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            print("Failed to start advertising: \(error.localizedDescription)")
            isAdvertising = false
        } else {
            isAdvertising = true
        }
    }
}
