//
//  ConstantsAndTypes.swift
//  FlySightCore
//
//  Created by Michael Cooper on 2025-05-17.
//

import Foundation

public extension FlySightCore { // Also extends the FlySightCore enum namespace

    // General Control Point Protocol Constants
    public static let CP_RESPONSE_ID: UInt8        = 0xF0

    public struct CP_STATUS {
        public static let success: UInt8            = 0x01 // CP_STATUS_SUCCESS
        public static let cmdNotSupported: UInt8    = 0x02 // CP_STATUS_CMD_NOT_SUPPORTED
        public static let invalidParameter: UInt8   = 0x03 // CP_STATUS_INVALID_PARAMETER
        public static let operationFailed: UInt8    = 0x04 // CP_STATUS_OPERATION_FAILED
        public static let operationNotPermitted: UInt8 = 0x05 // CP_STATUS_OPERATION_NOT_PERMITTED
        public static let busy: UInt8               = 0x06 // CP_STATUS_BUSY

        // Moved cpStatusToString here as a static internal method
        static internal func string(for status: UInt8) -> String {
            switch status {
            case FlySightCore.CP_STATUS.success: return "Success"
            case FlySightCore.CP_STATUS.cmdNotSupported: return "Command Not Supported"
            case FlySightCore.CP_STATUS.invalidParameter: return "Invalid Parameter"
            case FlySightCore.CP_STATUS.operationFailed: return "Operation Failed"
            case FlySightCore.CP_STATUS.operationNotPermitted: return "Operation Not Permitted"
            case FlySightCore.CP_STATUS.busy: return "Busy"
            default: return "Unknown Status (0x\(String(format: "%02X", status)))"
            }
        }
    }

    // Constants for Sensor Data (SD) Control Point Opcodes
    struct SDControlOpcodes { // Renamed from GNSSControlOpcodes
        public static let setMask: UInt8            = 0x01 // SD_CMD_SET_GNSS_BLE_MASK
        public static let getMask: UInt8            = 0x02 // SD_CMD_GET_GNSS_BLE_MASK
    }

    // Constants for Starter Pistol (SP) Control Point Opcodes
    struct SPControlOpcodes {
        public static let startCountdown: UInt8     = 0x01 // SP_CMD_START_COUNTDOWN
        public static let cancelCountdown: UInt8    = 0x02 // SP_CMD_CANCEL_COUNTDOWN
    }
}
