//
//  Extensions.swift
//
//
//  Created by Michael Cooper on 2024-05-25.
//

import Foundation
import CoreBluetooth // Required for CBError, CBATTError, CBATTErrorDomain, CBErrorDomain

extension BinaryInteger {
    public func fileSize() -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB] // Adjust based on your needs
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(self))
    }
}

extension Data {
    func hexEncodedString(options: HexEncodingOptions = []) -> String {
        let format = options.contains(.upperCase) ? "%02hhX" : "%02hhx"
        return self.map { String(format: format, $0) }.joined()
    }

    // Moved from BluetoothManager.swift - internal access level by default
    var littleEndianData: Data {
        // Assuming platform is already little-endian (iOS devices are).
        // For a truly cross-platform library where this might run on big-endian,
        // you would need to check endianness and reverse if necessary.
        // For iOS/macOS, direct return is fine.
        return self
    }
}

struct HexEncodingOptions: OptionSet {
    let rawValue: Int
    static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
}

// Moved from BluetoothManager.swift - internal access level by default
extension UInt32 {
    var littleEndianData: Data {
        var value = self.littleEndian // Ensures the integer is in little-endian byte order
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}

extension UInt16 { // Added for completeness if needed for other commands
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}

// MARK: - BLE Error Extension
public struct BLEErrorDetails {
    public let cbAttError: CBATTError?
    public let cbError: CBError?

    /// Checks if the error indicates insufficient authentication.
    public var isInsufficientAuthentication: Bool {
        if let attErrCode = cbAttError?.errorCode {
            return attErrCode == CBATTError.Code.insufficientAuthentication.rawValue
        }
        if let cbErrCode = cbError?.errorCode {
            // These CBError codes often relate to pairing/authentication issues.
            return cbErrCode == CBError.Code.peerRemovedPairingInformation.rawValue ||
                   cbErrCode == CBError.Code.unknownDevice.rawValue || // Can occur if device is not paired or connection is stale
                   cbErrCode == CBError.Code.connectionFailed.rawValue // Generic, but can be related
        }
        return false
    }

    /// Checks if the error indicates insufficient encryption.
    public var isInsufficientEncryption: Bool {
        if let attErrCode = cbAttError?.errorCode {
            return attErrCode == CBATTError.Code.insufficientEncryption.rawValue
        }
        // CBError doesn't have a direct "insufficientEncryption" but some pairing errors might imply it.
        if let cbErrCode = cbError?.errorCode {
            return cbErrCode == CBError.Code.encryptionTimedOut.rawValue
        }
        return false
    }
}

public extension Error {
    /// Attempts to interpret the error as a Core Bluetooth specific error (CBATTError or CBError).
    var asBLEError: BLEErrorDetails? {
        let nsError = self as NSError

        // Prioritize CBATTError if the domain matches
        if nsError.domain == CBATTErrorDomain, let attError = CBATTError(_nsError: nsError) as? CBATTError {
             return BLEErrorDetails(cbAttError: attError, cbError: nil)
        }
        // Check for CBError
        if nsError.domain == CBErrorDomain, let cbErr = CBError(_nsError: nsError) as? CBError {
             return BLEErrorDetails(cbAttError: nil, cbError: cbErr)
        }

        // Direct casting as a fallback (though NSError domain check is more robust for CB errors)
        if let cbAttError = self as? CBATTError {
            return BLEErrorDetails(cbAttError: cbAttError, cbError: nil)
        }
        if let cbError = self as? CBError {
            return BLEErrorDetails(cbAttError: nil, cbError: cbError)
        }

        return nil
    }
}
