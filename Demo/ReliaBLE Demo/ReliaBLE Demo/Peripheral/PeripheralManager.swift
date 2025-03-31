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