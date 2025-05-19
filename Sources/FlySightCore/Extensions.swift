//
//  Extensions.swift
//
//
//  Created by Michael Cooper on 2024-05-25.
//

import Foundation

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
