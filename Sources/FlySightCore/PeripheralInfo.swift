//
//  PeripheralInfo.swift
//  
//
//  Created by Michael Cooper on 2024-05-25.
//

import Foundation
import CoreBluetooth

public extension FlySightCore {
    struct PeripheralInfo: Identifiable {
        public var peripheral: CBPeripheral // Changed to var to allow updates
        public var rssi: Int
        public var name: String
        public var isConnected: Bool
        public var isPairingMode: Bool
        public var isBonded: Bool          // Added isBonded property

        public var id: UUID {
            peripheral.identifier
        }

        // Updated initializer to include isBonded
        public init(peripheral: CBPeripheral, rssi: Int, name: String, isConnected: Bool = false, isPairingMode: Bool = false, isBonded: Bool = false) {
            self.peripheral = peripheral
            self.rssi = rssi
            self.name = name
            self.isConnected = isConnected
            self.isPairingMode = isPairingMode
            self.isBonded = isBonded        // Initialize isBonded
        }
    }
}

// Explicit Equatable conformance for clarity, especially due to CBPeripheral.
// This is also implicitly required if PeripheralInfo is used as an associated value in an Equatable enum.
extension FlySightCore.PeripheralInfo: Equatable {
    public static func == (lhs: FlySightCore.PeripheralInfo, rhs: FlySightCore.PeripheralInfo) -> Bool {
        return lhs.id == rhs.id && // Primary comparison based on identifier
               lhs.rssi == rhs.rssi &&
               lhs.name == rhs.name &&
               lhs.isConnected == rhs.isConnected &&
               lhs.isPairingMode == rhs.isPairingMode &&
               lhs.isBonded == rhs.isBonded
        // Note: CBPeripheral itself is a class and does not conform to Equatable.
        // We compare PeripheralInfo instances based on their properties, using 'id' for peripheral identity.
    }
}

extension FlySightCore.PeripheralInfo: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id) // Hashing based on the unique identifier is appropriate
    }
}
