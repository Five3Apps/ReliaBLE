//
//  PeripheralManager.swift
//  ReliaBLE
//
//  Created by Justin Bergen on 3/8/25.
//
//  Copyright (c) 2025 Five3 Apps, LLC <justin@five3apps.com>
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

class PeripheralManager {
    private let log: LoggingService
    
    private var discoveredPeripherals = [Peripheral]()
    private let discoveredPeripheralsSubject = PassthroughSubject<[Peripheral], Never>()
    private let queue = DispatchQueue(label: "com.five3apps.relia-ble.peripheralmanager", qos: .userInitiated, attributes: [.concurrent])
    
    public var discoveredPeripheralsPublisher: AnyPublisher<[Peripheral], Never> {
        discoveredPeripheralsSubject.eraseToAnyPublisher()
    }

    init(loggingService: LoggingService) {
        self.log = loggingService
    }
    
    func discoveredPeripheral(_ cbPeripheral: CBPeripheral, advertisementData: [String: Any]? = nil, rssi: Int? = nil) {
        // TODO: FR-8.5: Unique Identifier from Manufacturing Data -- Connect to id once implmented
        // TODO: If there's no identifier should we ignore it?
        let identifier = cbPeripheral.name ?? advertisementData?[CBAdvertisementDataLocalNameKey] as? String ?? cbPeripheral.identifier.uuidString
        
        queue.sync {
            // First check if the peripheral has already been discovered by identifier
            if let existingPeripheral = discoveredPeripherals.first(where: { $0.id == identifier }) {
                existingPeripheral.update(cbPeripheral: cbPeripheral, advertisementData: advertisementData, rssi: rssi)
                discoveredPeripheralsSubject.send(discoveredPeripherals)
                return
            }
            
            // Next check if the peripheral has already been discovered by CBPeripheral identifier
            if let existingPeripheral = discoveredPeripherals.first(where: { $0.peripheral?.identifier == cbPeripheral.identifier }) {
                existingPeripheral.update(cbPeripheral: cbPeripheral, advertisementData: advertisementData, rssi: rssi)
                discoveredPeripheralsSubject.send(discoveredPeripherals)
                return
            }
            
            let newPeripheral = Peripheral(id: identifier, peripheral: cbPeripheral, advertisementData: advertisementData, rssi: rssi)
            log.debug(tags: [.category(.scanning), .peripheral(newPeripheral.id)], "Adding newly discovered peripheral")
            discoveredPeripherals.append(newPeripheral)
            discoveredPeripheralsSubject.send(discoveredPeripherals)
        }
    }
    
    func invalidatePeripherals() {
        queue.sync {
            for peripheral in discoveredPeripherals {
                peripheral.peripheral = nil
            }
            discoveredPeripheralsSubject.send(discoveredPeripherals)
            log.debug("Invalidated all peripheral references")
        }
    }
    
    func refreshPeripherals(using centralManager: CBCentralManager) {
        queue.sync {
            let identifiers = discoveredPeripherals.compactMap { $0.peripheralIdentifier }
            guard !identifiers.isEmpty else {
                log.debug("No peripheral identifiers to refresh")
                
                return
            }
            
            let retrievedPeripherals = centralManager.retrievePeripherals(withIdentifiers: identifiers)
            for cbPeripheral in retrievedPeripherals {
                if let peripheral = discoveredPeripherals.first(where: { $0.peripheralIdentifier == cbPeripheral.identifier }) {
                    peripheral.update(cbPeripheral: cbPeripheral)
                }
            }
            discoveredPeripheralsSubject.send(discoveredPeripherals)
            log.debug("Refreshed \(retrievedPeripherals.count) peripherals from CBCentralManager")
        }
    }
}
