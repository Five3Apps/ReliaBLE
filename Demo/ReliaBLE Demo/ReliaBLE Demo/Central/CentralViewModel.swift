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

import CoreBluetooth
import SwiftData
import SwiftUI

import ReliaBLE

@Observable class CentralViewModel {
    var currentState: BluetoothState = .unknown
    var servicesInput = ""

    private var deviceStore: DeviceStoreActor?
    private var reliaBLE: ReliaBLEManager?

    func setDependencies(deviceStore: DeviceStoreActor, reliaBLE: ReliaBLEManager) {
        self.deviceStore = deviceStore
        self.reliaBLE = reliaBLE
    }

    // MARK: - Stream Handlers
    //
    // Fed by the `.task { for await … }` loops in `CentralView`. Only UI state updates
    // run on the main actor; SwiftData writes go through `DeviceStoreActor`.

    @MainActor
    func updateState(_ state: BluetoothState) {
        currentState = state
    }

    func authorizeBluetooth() {
        Task { try? await reliaBLE?.authorizeBluetooth() }
    }

    func startScanning() {
        let services = parseServices(from: servicesInput)
        Task { await reliaBLE?.startScanning(services: services) }
    }

    func stopScanning() {
        Task { await reliaBLE?.stopScanning() }
    }

    func clearAllData() {
        Task { await deviceStore?.clearAll() }
    }

    func deleteDiscoveries(ids: [PersistentIdentifier]) {
        Task { await deviceStore?.deleteDiscoveries(ids: ids) }
    }

    func deleteDevices(ids: [PersistentIdentifier]) {
        Task { await deviceStore?.deleteDevices(ids: ids) }
    }

    private func parseServices(from input: String) -> [CBUUID]? {
        let components = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let uuids = components.filter { !$0.isEmpty }.map { CBUUID(string: $0) }

        return uuids.isEmpty ? nil : uuids
    }
}