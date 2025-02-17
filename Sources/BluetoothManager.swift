//
//  BluetoothManager.swift
//  ReliaBLE
//
//  Created by Justin Bergen on 1/16/25.
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
import Foundation

/// High-level manager for all Bluetooth operations. Manages the CBCentralManager and provides a single point of access
/// for all Bluetooth operations.
class BluetoothManager: NSObject, CBCentralManagerDelegate {
    private var centralManager: CBCentralManager?
    private let queue = DispatchQueue(label: "com.five3apps.relia-ble.bluetoothmanager", qos: .userInitiated, attributes: [.concurrent])
    private let log: LoggingService
    
    private let stateSubject = CurrentValueSubject<BluetoothState, Never>(.unknown)
    
    // MARK: - Initialization

    /// Initializes the BluetoothManager with the provided LoggingService. Initializing a BluetoothManager does not
    /// start the CBCentralManager or trigger an authorization alert. This allows the integrating app to control when
    /// and how Bluetooth autorization is presented to the user.
    ///
    /// When the integrating app desires to request Bluetooth authorization from iOS it can call ``authorize()``.
    ///
    /// - Parameter loggingService: The LoggingService to use for logging.
    /// - Returns: A new instance of BluetoothManager.
    init(loggingService: LoggingService) {
        log = loggingService
        
        super.init()
        
        if CBCentralManager.authorization == .allowedAlways {
            setupCentralManager()
        }
        
        updateState()
    }
    
    private func setupCentralManager() {
        guard centralManager == nil else {
            return
        }
        
        log.info("Initializing CBCentralManager")
        centralManager = CBCentralManager(delegate: self, queue: queue, options: nil)
    }
    
    // MARK: - State
    
    /// Publisher for the real-time state of the underlying Core Bluetooth system.
    var state: AnyPublisher<BluetoothState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    
    /// Synchronous access to the current state of the underlying Core Bluetooth system.
    var currentState: BluetoothState {
        stateSubject.value
    }

    private func updateState() {
        switch CBCentralManager.authorization {
        case .notDetermined:
            stateSubject.send(.unauthorized(.notDetermined))
            
            return
        case .denied:
            stateSubject.send(.unauthorized(.denied))
            
            return
        case .restricted:
            stateSubject.send(.unauthorized(.restricted))
            
            return
        default:
            break
        }
        
        switch centralManager?.state {
        case .poweredOn:
            stateSubject.send(.ready)
        case .poweredOff:
            stateSubject.send(.poweredOff)
        case .resetting:
            stateSubject.send(.resetting)
        case .unsupported:
            stateSubject.send(.unsupported)
        case .unknown:
            stateSubject.send(.unknown)
        default:
            stateSubject.send(.unknown)
        }
    }
    
    /// Requests authorization to use Bluetooth. This method will throw an error if the user has denied or restricted
    /// Bluetooth access.
    ///
    /// - Throws: An ``AuthorizationError`` error if the user has denied or restricted Bluetooth access.
    func authorize() throws {
        log.info("Authorizing bluetooth")
        
        switch CBCentralManager.authorization {
        case .notDetermined:
            setupCentralManager()
        case .denied:
            throw AuthorizationError.denied
        case .restricted:
            throw AuthorizationError.restricted
        case .allowedAlways:
            setupCentralManager()
        @unknown default:
            throw AuthorizationError.unknown
        }
    }
    
    // MARK: - CBCentralManagerDelegate
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.debug("centralManagerDidUpdateState: \(central.state.rawValue)")
        
        updateState()
    }
}

/// A typealias for the authorization status of the Core Bluetooth manager.
/// 
/// This typealias maps `CBManagerAuthorization` to `AuthorizationStatus`, providing a more readable and convenient
/// way to refer to the authorization status of the Bluetooth manager in the code.
public typealias AuthorizationStatus = CBManagerAuthorization

/// Represents the various states of `BluetoothManager` and the underlying Core Bluetooth system.
///
/// This enumeration provides a thread-safe representation of possible Bluetooth states that can be used across
/// concurrent environments.
public enum BluetoothState: Sendable {
    /// Bluetooth is powered on and the `BluetoothManager` is ready to use.
    case ready
    /// Bluetooth is currently powered off on the device.
    case poweredOff
    /// Indicates the connection with the system service was momentarily lost.
    ///
    /// This state indicates that Bluetooth is trying to reconnect. After it reconnects, `BluetoothManager` updates the
    /// state value.
    case resetting
    /// The app is not authorized to use Bluetooth. Associated value provides specific authorization status.
    case unauthorized(AuthorizationStatus)
    /// The platform doesn't support Bluetooth Low Energy.
    case unsupported
    /// The state of the `BluetoothManager` is unknown.
    ///
    /// This is a temporary state. After Core Bluetooth initializes or resets, `BluetoothManager` updates the
    /// state value.
    case unknown
    
    /// A user-friendly string representation of the `BluetoothState`.
    ///
    /// - Returns: A string describing the `BluetoothState`.
    public var description: String {
        switch self {
        case .ready:
            "Ready"
        case .poweredOff:
            "Powered Off"
        case .resetting:
            "Resetting"
        case .unauthorized(let authorizationStatus):
            switch authorizationStatus {
            case .notDetermined:
                "Not Authorized"
            case .restricted:
                "Restricted"
            case .denied:
                "Denied"
            default:
                "Unauthorized"
            }
        case .unsupported:
            "Unsupported"
        case .unknown:
            "Unknown"
        }
    }
}

// MARK - Errors

/// A Swift error enumeration representing authorization-related errors in Bluetooth operations.
///
/// This type conforms to Swift's `Error` protocol and encapsulates various authorization failures that may occur
/// during Bluetooth operations.
public enum AuthorizationError: Error {
    /// The user explicitly denied Bluetooth access for this app.
    case denied
    /// Indicates this app isn’t authorized to use Bluetooth.
    case restricted
    /// The authorization status is unknown.
    case unknown
}
