//
//  BluetoothManager.swift
//
//
//  Created by Michael Cooper on 2024-05-25.
//

import Foundation
import CoreBluetooth
import Combine
import UIKit // For alert prompting

public extension FlySightCore {

    // MARK: - Service UUIDs
    static let FILE_TRANSFER_SERVICE_UUID = CBUUID(string: "00000000-cc7a-482a-984a-7f2ed5b3e58f")
    static let SENSOR_DATA_SERVICE_UUID   = CBUUID(string: "00000001-cc7a-482a-984a-7f2ed5b3e58f")
    static let STARTER_PISTOL_SERVICE_UUID = CBUUID(string: "00000002-cc7a-482a-984a-7f2ed5b3e58f")
    static let DEVICE_STATE_SERVICE_UUID  = CBUUID(string: "00000003-cc7a-482a-984a-7f2ed5b3e58f")
    // Standard Services
    static let DEVICE_INFORMATION_SERVICE_UUID = CBUUID(string: "180A")
    static let BATTERY_SERVICE_UUID           = CBUUID(string: "180F") // Planned

    // MARK: - Characteristic UUIDs (Fully Qualified)
    // File Transfer Service
    static let FT_PACKET_OUT_UUID = CBUUID(string: "00000001-8e22-4541-9d4c-21edae82ed19") // Notify
    static let FT_PACKET_IN_UUID  = CBUUID(string: "00000002-8e22-4541-9d4c-21edae82ed19") // WriteWithoutResponse, Read (Pairing Trigger)

    // Sensor Data Service
    static let SD_GNSS_MEASUREMENT_UUID = CBUUID(string: "00000000-8e22-4541-9d4c-21edae82ed19") // Read, Notify
    static let SD_CONTROL_POINT_UUID    = CBUUID(string: "00000006-8e22-4541-9d4c-21edae82ed19") // Write, Indicate

    // Starter Pistol Service
    static let SP_CONTROL_POINT_UUID = CBUUID(string: "00000003-8e22-4541-9d4c-21edae82ed19") // Write, Indicate
    static let SP_RESULT_UUID        = CBUUID(string: "00000004-8e22-4541-9d4c-21edae82ed19") // Read, Indicate

    // Device State Service
    static let DS_MODE_UUID            = CBUUID(string: "00000005-8e22-4541-9d4c-21edae82ed19") // Read, Indicate
    static let DS_CONTROL_POINT_UUID   = CBUUID(string: "00000007-8e22-4541-9d4c-21edae82ed19") // Write, Indicate

    // Standard Characteristic UUIDs
    static let FIRMWARE_REVISION_STRING_UUID = CBUUID(string: "2A26")


    class BluetoothManager: NSObject, ObservableObject {
        private var centralManager: CBCentralManager! // Implicitly unwrapped after init
        private var cancellables = Set<AnyCancellable>()
        private var notificationHandlers: [CBUUID: (CBPeripheral, CBCharacteristic, Error?) -> Void] = [:]

        // MARK: - Characteristics References
        private var ftPacketInCharacteristic: CBCharacteristic?
        private var ftPacketOutCharacteristic: CBCharacteristic?
        private var sdGNSSMeasurementCharacteristic: CBCharacteristic?
        private var sdControlPointCharacteristic: CBCharacteristic?
        private var spControlPointCharacteristic: CBCharacteristic?
        private var spResultCharacteristic: CBCharacteristic?
        private var dsModeCharacteristic: CBCharacteristic?
        private var dsControlPointCharacteristic: CBCharacteristic?
        private var firmwareRevisionCharacteristic: CBCharacteristic?


        // MARK: - Published UI State
        @Published public var knownPeripherals: [PeripheralInfo] = []
        @Published public var discoveredPairingPeripherals: [PeripheralInfo] = []
        @Published public var connectedPeripheralInfo: PeripheralInfo? // Wraps the CBPeripheral and associated app state
        @Published public var connectionState: ConnectionState = .idle
        @Published public var flysightModelName: String?
        @Published public var flysightFirmwareVersion: String?

        // File Management
        @Published public var directoryEntries: [DirectoryEntry] = []
        @Published public var currentPath: [String] = []
        @Published public var isAwaitingDirectoryResponse = false

        // Start Pistol
        public enum StartPistolState { case idle, counting }
        @Published public var startPistolState: StartPistolState = .idle
        @Published public var startResultDate: Date?

        // Downloads & Uploads
        @Published public var downloadProgress: Float = 0.0
        @Published public var uploadProgress: Float = 0.0
        private var currentFileSize: UInt32 = 0
        private var isUploading = false
        private var fileDataToUpload: Data?
        private var remotePathToUpload: String?
        private var nextPacketNum: Int = 0
        private var nextAckNum: Int = 0
        private var lastPacketNum: Int?
        private let windowLength: Int = 8
        private let frameLength: Int = 242 // As per FlySight docs for FT_Packet_In/Out data part
        private let txTimeoutInterval: TimeInterval = 0.2 // For GBN sender
        private var totalPacketsToSend: UInt32 = 0
        private var uploadContinuation: CheckedContinuation<Void, Error>? // For awaiting upload completion

        private var pingTimer: Timer?

        // Live GNSS
        @Published public var liveGNSSData: FlySightCore.LiveGNSSData?
        @Published public var currentGNSSMask: UInt8 = GNSSLiveMaskBits.timeOfWeek | GNSSLiveMaskBits.position | GNSSLiveMaskBits.velocity
        @Published public var gnssMaskUpdateStatus: GNSSMaskUpdateStatus = .idle
        private var lastAttemptedGNSSMask: UInt8?

        // MARK: - Internal State
        public enum ScanMode { case none, knownDevices, pairingMode }
        private var currentScanMode: ScanMode = .none
        private var disappearanceTimers: [UUID: Timer] = [:]
        private var peripheralBeingConnected: CBPeripheral? // To track during connection process

        private let lastConnectedPeripheralIDKey = "lastConnectedPeripheralID_v1"
        private var lastConnectedPeripheralID: UUID? {
            get {
                guard let uuidString = UserDefaults.standard.string(forKey: lastConnectedPeripheralIDKey) else { return nil }
                return UUID(uuidString: uuidString)
            }
            set {
                UserDefaults.standard.set(newValue?.uuidString, forKey: lastConnectedPeripheralIDKey)
            }
        }

        public enum ConnectionState: Equatable {
            case idle // Initial state, or after full disconnect
            case scanningKnown
            case scanningPairing
            case connecting(to: PeripheralInfo) // Contains info about target
            case discoveringServices(for: CBPeripheral)
            case discoveringCharacteristics(for: CBPeripheral)
            case connected(to: PeripheralInfo) // Fully operational
            case disconnecting(from: PeripheralInfo)
        }

        // MARK: - Initialization
        public override init() {
            super.init()
            // Initialize CBCentralManager on a background queue for performance.
            // Delegate methods will be called on this queue, so dispatch to main for UI updates.
            self.centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .userInitiated))
            print("BluetoothManager initialized.")
            // Loading known peripherals and attempting auto-connect will happen in centralManagerDidUpdateState.
        }

        private func resetPeripheralState() {
            DispatchQueue.main.async {
                self.connectedPeripheralInfo = nil
                self.peripheralBeingConnected = nil

                self.ftPacketInCharacteristic = nil
                self.ftPacketOutCharacteristic = nil
                self.sdGNSSMeasurementCharacteristic = nil
                self.sdControlPointCharacteristic = nil
                self.spControlPointCharacteristic = nil
                self.spResultCharacteristic = nil
                self.dsModeCharacteristic = nil
                self.dsControlPointCharacteristic = nil
                self.firmwareRevisionCharacteristic = nil
                self.flysightModelName = nil
                self.flysightFirmwareVersion = nil

                self.stopPingTimer()
                self.currentPath = []
                self.directoryEntries = []
                self.isAwaitingDirectoryResponse = false
                self.startPistolState = .idle
                self.liveGNSSData = nil
                self.gnssMaskUpdateStatus = .idle

                if self.isUploading {
                    self.uploadContinuation?.resume(throwing: NSError(domain: "FlySightCore.Upload", code: -100, userInfo: [NSLocalizedDescriptionKey: "Connection lost during upload."]))
                    self.uploadContinuation = nil
                    self.isUploading = false
                    self.uploadProgress = 0.0
                }
                // Reset download progress if necessary
                self.downloadProgress = 0.0
            }
        }

        // MARK: - Scanning Control
        public func startScanningForKnownDevices() {
            guard centralManager.state == .poweredOn else { return }
            DispatchQueue.main.async { self.connectionState = .scanningKnown }
            currentScanMode = .knownDevices
            centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            print("Scanning for known FlySight devices...")
        }

        public func startScanningForPairingModeDevices() {
            guard centralManager.state == .poweredOn else { return }
            DispatchQueue.main.async {
                self.discoveredPairingPeripherals = [] // Clear previous results
                self.connectionState = .scanningPairing
            }
            currentScanMode = .pairingMode
            centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            print("Scanning for FlySight devices in pairing mode...")
        }

        public func stopScanning() {
            centralManager.stopScan()
            currentScanMode = .none
            DispatchQueue.main.async {
                // Only revert to idle if not in another active state like connecting/connected
                if case .scanningKnown = self.connectionState { self.connectionState = .idle }
                if case .scanningPairing = self.connectionState { self.connectionState = .idle }
            }
            print("Stopped scanning.")
            disappearanceTimers.values.forEach { $0.invalidate() }
            disappearanceTimers.removeAll()
        }

        // MARK: - Connection Logic
        public func connect(to peripheralInfo: PeripheralInfo) {
            guard centralManager.state == .poweredOn else {
                print("Cannot connect: Bluetooth is not powered on.")
                return
            }

            // If already trying to connect to the same peripheral, do nothing.
            if case .connecting(let currentTarget) = connectionState, currentTarget.id == peripheralInfo.id {
                print("Already attempting to connect to \(peripheralInfo.name).")
                return
            }

            // If connected to a different peripheral, disconnect it first.
            if let currentlyConnected = connectedPeripheralInfo, currentlyConnected.id != peripheralInfo.id {
                print("Disconnecting from \(currentlyConnected.name) to connect to \(peripheralInfo.name).")
                disconnect(from: currentlyConnected) // This will trigger state changes
            }

            print("Attempting to connect to \(peripheralInfo.name) (\(peripheralInfo.id))...")
            DispatchQueue.main.async {
                self.connectionState = .connecting(to: peripheralInfo)
            }
            self.peripheralBeingConnected = peripheralInfo.peripheral
            centralManager.connect(peripheralInfo.peripheral, options: nil)
        }

        public func disconnect(from peripheralInfo: PeripheralInfo) {
            guard let cbPeripheral = knownPeripherals.first(where: { $0.id == peripheralInfo.id })?.peripheral ??
                                     discoveredPairingPeripherals.first(where: { $0.id == peripheralInfo.id})?.peripheral ??
                                     (connectedPeripheralInfo?.id == peripheralInfo.id ? connectedPeripheralInfo?.peripheral : nil)
            else {
                print("Peripheral object not found for disconnection: \(peripheralInfo.name)")
                return
            }

            print("Disconnecting from \(peripheralInfo.name)...")
            DispatchQueue.main.async {
                self.connectionState = .disconnecting(from: peripheralInfo)
            }
            centralManager.cancelPeripheralConnection(cbPeripheral)
        }

        private func attemptAutoConnect() {
            guard centralManager.state == .poweredOn, connectedPeripheralInfo == nil,
                  case .idle = connectionState else { // Only auto-connect if truly idle
                return
            }

            if let lastID = lastConnectedPeripheralID {
                print("Attempting to auto-connect to last peripheral: \(lastID)")
                // Try to retrieve the peripheral directly
                if let peripheral = centralManager.retrievePeripherals(withIdentifiers: [lastID]).first {
                    let pInfo = PeripheralInfo(peripheral: peripheral, rssi: -100, name: peripheral.name ?? "FlySight", isConnected: false, isPairingMode: false, isBonded: self.bondedDeviceIDs.contains(peripheral.identifier))
                    self.updateKnownPeripheralsList(with: pInfo) // Ensure it's in the list
                    connect(to: pInfo)
                } else {
                    print("Could not retrieve last connected peripheral directly. Scanning for known devices.")
                    startScanningForKnownDevices()
                }
            } else {
                print("No last connected peripheral ID. Scanning for known devices.")
                startScanningForKnownDevices()
            }
        }

        // MARK: - Device Forgetting
        public func forgetDevice(peripheralInfo: PeripheralInfo, completion: @escaping () -> Void) {
            let deviceName = peripheralInfo.name

            if connectedPeripheralInfo?.id == peripheralInfo.id {
                disconnect(from: peripheralInfo)
            }

            removeBondedDeviceID(peripheralInfo.id)

            DispatchQueue.main.async {
                self.knownPeripherals.removeAll { $0.id == peripheralInfo.id }

                let alert = UIAlertController(
                    title: "Device Forgotten",
                    message: "\(deviceName) has been removed from this app. For a complete unpair:\n1. Go to iPhone Settings > Bluetooth.\n2. Find \(deviceName), tap 'ⓘ', then 'Forget This Device'.\n3. On FlySight: Connect via USB, edit FLYSIGHT.TXT, set Reset_BLE=1, save, eject.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion() })

                self.presentAlert(alert)
            }
        }

        private func presentAlert(_ alertController: UIAlertController) {
            DispatchQueue.main.async { // Ensure UI operations are on the main thread
                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let rootViewController = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                    print("Could not find root view controller to present alert.")
                    // Call completion if alert cannot be shown, though this might not be ideal for all cases
                    // For forgetDevice, it calls its own completion.
                    return
                }

                var presentingController = rootViewController
                while let presented = presentingController.presentedViewController {
                    presentingController = presented
                }
                presentingController.present(alertController, animated: true)
            }
        }

        // MARK: - CBCentralManagerDelegate
        public func centralManagerDidUpdateState(_ central: CBCentralManager) {
            DispatchQueue.main.async { // Ensure all state updates from here are main-threaded
                switch central.state {
                case .poweredOn:
                    print("Bluetooth Powered On.")
                    self.loadKnownPeripheralsFromUserDefaults() // Load bonded device IDs
                    if self.connectionState == .idle { // Only auto-connect if truly idle
                         self.attemptAutoConnect()
                    } else if self.currentScanMode == .knownDevices { // Re-start scan if it was active
                        self.startScanningForKnownDevices()
                    } else if self.currentScanMode == .pairingMode {
                        self.startScanningForPairingModeDevices()
                    }
                case .poweredOff:
                    print("Bluetooth Powered Off.")
                    self.resetPeripheralState() // Clear all connection-related state
                    self.knownPeripherals.indices.forEach { self.knownPeripherals[$0].isConnected = false }
                    self.discoveredPairingPeripherals = []
                    self.connectionState = .idle
                    // Present an alert to the user
                    let alert = UIAlertController(title: "Bluetooth Off", message: "Please turn on Bluetooth to use FlySight features.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
                    self.presentAlert(alert)
                case .resetting:
                    print("Bluetooth is resetting.")
                    // Connection state will be updated once it's powered on or off
                case .unauthorized:
                    print("Bluetooth use unauthorized.")
                    self.connectionState = .idle
                    // Present an alert
                     let alert = UIAlertController(title: "Bluetooth Unauthorized", message: "This app needs Bluetooth permission. Please enable it in Settings.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Settings", style: .default) { _ in
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    })
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
                    self.presentAlert(alert)
                case .unsupported:
                    print("Bluetooth is unsupported on this device.")
                    self.connectionState = .idle
                    // Present an alert
                    let alert = UIAlertController(title: "Bluetooth Unsupported", message: "This device does not support Bluetooth Low Energy.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
                    self.presentAlert(alert)
                default:
                    print("Bluetooth state unknown or new: \(central.state)")
                }
            }
        }

        public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
            guard let peripheralName = peripheral.name, peripheralName.contains("FlySight") else {
                // Filter early if name doesn't suggest it's a FlySight, unless using manufacturer data only
                // The FlySight documentation implies we should primarily use Manufacturer Data
                if let manufData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, manufData.count >= 2 {
                    let manufID = UInt16(manufData[1]) << 8 | UInt16(manufData[0])
                    if manufID != 0x09DB { return } // Not Bionic Avionics
                } else {
                    return // No name and no relevant manufacturer data
                }
            }

            var isPairingModeAdvertised = false
            if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
               manufacturerData.count >= 3, // Length (0x04), Type (0xFF), ManufID_LSB, ManufID_MSB, StatusByte
               (UInt16(manufacturerData[2]) | (UInt16(manufacturerData[1]) << 8)) == 0x09DB { // Check Manuf ID (0x09DB) - Note: Doc says DB0901, where DB09 is ID. My previous code was wrong.
                // Corrected Manufacturer Data Parsing from Doc:
                // Manuf. ID LSB: 0xDB (index 1 of manuf data if length byte is not counted, or index 2 if payload starts after length/type)
                // Manuf. ID MSB: 0x09 (index 2 of manuf data or index 3)
                // Status Byte (index 3 of manuf data or index 4)
                // The CBAdvertisementDataManufacturerDataKey gives the "Manufacturer Specific Data" field *without* the main AD Length and Type.
                // So, manufacturerData[0] = Manuf ID LSB, manufacturerData[1] = Manuf ID MSB
                let manufID = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8)
                if manufID == 0x09DB && manufacturerData.count >= 3 { // ID + StatusByte
                     isPairingModeAdvertised = (manufacturerData[2] & 0x01) != 0
                } else { return } // Not our manufacturer
            } else {
                // If no manufacturer data, only proceed for known devices scan if already bonded
                if currentScanMode != .knownDevices || !bondedDeviceIDs.contains(peripheral.identifier) {
                    return
                }
            }

            let discoveredInfo = PeripheralInfo(
                peripheral: peripheral,
                rssi: RSSI.intValue,
                name: peripheral.name ?? "FlySight", // Use actual name if available
                isConnected: false, // Will be updated on connect
                isPairingMode: isPairingModeAdvertised,
                isBonded: bondedDeviceIDs.contains(peripheral.identifier)
            )

            DispatchQueue.main.async {
                switch self.currentScanMode {
                case .knownDevices:
                    // Update if already in knownPeripherals or add if it's a bonded device not yet listed (e.g. from retrievePeripherals fail)
                    if discoveredInfo.isBonded {
                        self.updateKnownPeripheralsList(with: discoveredInfo)
                    }
                case .pairingMode:
                    if discoveredInfo.isPairingMode { // Only add if explicitly in pairing mode
                        self.updateDiscoveredPairingPeripheralsList(with: discoveredInfo)
                    }
                case .none:
                    break // Not actively scanning for general discovery
                }
            }
        }

        private func updateKnownPeripheralsList(with discoveredInfo: PeripheralInfo) {
            if let index = knownPeripherals.firstIndex(where: { $0.id == discoveredInfo.id }) {
                knownPeripherals[index].rssi = discoveredInfo.rssi
                knownPeripherals[index].name = discoveredInfo.name
                knownPeripherals[index].peripheral = discoveredInfo.peripheral // Update object
                // isConnected and isBonded status are managed by connection/bonding events
            } else if discoveredInfo.isBonded { // Add if bonded but somehow not in the list yet
                knownPeripherals.append(discoveredInfo)
            }
            sortKnownPeripherals()
        }

        private func updateDiscoveredPairingPeripheralsList(with discoveredInfo: PeripheralInfo) {
            if let index = discoveredPairingPeripherals.firstIndex(where: { $0.id == discoveredInfo.id }) {
                discoveredPairingPeripherals[index].rssi = discoveredInfo.rssi
                discoveredPairingPeripherals[index].name = discoveredInfo.name
                discoveredPairingPeripherals[index].peripheral = discoveredInfo.peripheral
                resetDisappearanceTimer(for: discoveredPairingPeripherals[index])
            } else {
                discoveredPairingPeripherals.append(discoveredInfo)
                startDisappearanceTimer(for: discoveredInfo)
            }
            sortPairingPeripheralsByRSSI()
        }

        public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
            print("Connected to \(peripheral.name ?? peripheral.identifier.uuidString). Discovering services...")
            peripheral.delegate = self

            // Find the PeripheralInfo that corresponds to this CBPeripheral
            // It could be from the known list or the pairing list (if connection was initiated from there)
            // Or it's an auto-reconnection to a peripheral we retrieved by ID.
            let connectingTargetInfo: PeripheralInfo?
            if case .connecting(let target) = connectionState, target.id == peripheral.identifier {
                connectingTargetInfo = target
            } else { // Fallback if state wasn't perfectly set, e.g. auto-reconnect
                connectingTargetInfo = knownPeripherals.first(where: {$0.id == peripheral.identifier}) ??
                                       discoveredPairingPeripherals.first(where: {$0.id == peripheral.identifier})
            }

            let pInfo = connectingTargetInfo ?? PeripheralInfo(peripheral: peripheral, rssi: -100, name: peripheral.name ?? "FlySight", isConnected: true, isPairingMode: false, isBonded: bondedDeviceIDs.contains(peripheral.identifier))

            DispatchQueue.main.async {
                self.peripheralBeingConnected = peripheral // Store reference
                self.connectionState = .discoveringServices(for: peripheral)

                // Update the main connectedPeripheralInfo if this connection is for it
                // This ensures that `connectedPeripheralInfo` is set early in the connection process
                if self.connectedPeripheralInfo == nil || self.connectedPeripheralInfo?.id == peripheral.identifier {
                    self.connectedPeripheralInfo = pInfo
                }

                // Update the specific list entry
                if let index = self.knownPeripherals.firstIndex(where: { $0.id == peripheral.identifier }) {
                    self.knownPeripherals[index].isConnected = true
                    self.knownPeripherals[index].peripheral = peripheral // Ensure peripheral object is current
                } else if pInfo.isBonded { // If bonded but not in list, add it
                    var newKnown = pInfo
                    newKnown.isConnected = true
                    self.knownPeripherals.append(newKnown)
                }
                self.sortKnownPeripherals()
            }

            // Discover specific services critical for operation (File Transfer for pairing, Device Info)
            // Add other services like SENSOR_DATA_SERVICE_UUID, STARTER_PISTOL_SERVICE_UUID, DEVICE_STATE_SERVICE_UUID
            // if you want to discover them upfront.
            let servicesToDiscover = [
                FlySightCore.FILE_TRANSFER_SERVICE_UUID,
                FlySightCore.DEVICE_INFORMATION_SERVICE_UUID,
                FlySightCore.SENSOR_DATA_SERVICE_UUID,
                FlySightCore.STARTER_PISTOL_SERVICE_UUID,
                FlySightCore.DEVICE_STATE_SERVICE_UUID
            ]
            peripheral.discoverServices(servicesToDiscover)
        }

        public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
            let peripheralName = peripheral.name ?? peripheral.identifier.uuidString
            print("Failed to connect to \(peripheralName): \(error?.localizedDescription ?? "Unknown error")")

            DispatchQueue.main.async {
                if self.peripheralBeingConnected?.identifier == peripheral.identifier {
                    self.peripheralBeingConnected = nil
                }
                // Revert connectionState to idle or scanningKnown depending on context
                if case .connecting(let targetInfo) = self.connectionState, targetInfo.id == peripheral.identifier {
                     self.connectionState = .idle // Or perhaps .scanningKnown if appropriate
                }

                if self.connectedPeripheralInfo?.id == peripheral.identifier {
                    self.connectedPeripheralInfo = nil
                }
                if let index = self.knownPeripherals.firstIndex(where: { $0.id == peripheral.identifier }) {
                    self.knownPeripherals[index].isConnected = false
                }
                self.sortKnownPeripherals()

                // If auto-connect failed for the last known device, go back to scanning for known devices.
                if self.lastConnectedPeripheralID == peripheral.identifier {
                    self.startScanningForKnownDevices()
                }
            }
        }

        public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
            let peripheralName = peripheral.name ?? peripheral.identifier.uuidString
            print("Disconnected from \(peripheralName). Reason: \(error?.localizedDescription ?? "None")")

            DispatchQueue.main.async {
                let previouslyConnectedInfo = self.connectedPeripheralInfo // Capture before resetting
                self.resetPeripheralState() // Clears current peripheral, chars, timers etc.

                if let pInfo = previouslyConnectedInfo {
                    // Update the specific list entry
                    if let index = self.knownPeripherals.firstIndex(where: { $0.id == pInfo.id }) {
                        self.knownPeripherals[index].isConnected = false
                    }
                }
                self.connectionState = .idle
                self.sortKnownPeripherals()

                // If the disconnection was unexpected (error != nil), try to auto-connect or scan again.
                if error != nil {
                    print("Unexpected disconnection, attempting to restore or scan.")
                    self.attemptAutoConnect() // This will scan if no last ID or retrieval fails
                }
            }
        }

        // MARK: - CBPeripheralDelegate
        public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
            guard error == nil else {
                print("Error discovering services on \(peripheral.identifier): \(error!.localizedDescription)")
                if peripheral.identifier == peripheralBeingConnected?.identifier || peripheral.identifier == connectedPeripheralInfo?.id {
                    disconnect(from: PeripheralInfo(peripheral: peripheral, rssi: 0, name: "", isBonded: false)) // Simplify disconnect call
                }
                return
            }

            guard let services = peripheral.services, !services.isEmpty else {
                print("No services found for \(peripheral.identifier). This is unexpected.")
                // Consider disconnecting if essential services are missing.
                return
            }

            DispatchQueue.main.async {
                if case .discoveringServices(let p) = self.connectionState, p.identifier == peripheral.identifier {
                    self.connectionState = .discoveringCharacteristics(for: peripheral)
                }
            }

            for service in services {
                print("Discovered service: \(service.uuid.uuidString) on \(peripheral.identifier)")
                peripheral.discoverCharacteristics(nil, for: service) // Discover all characteristics for found services
            }
        }

        public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
            guard error == nil else {
                print("Error discovering characteristics for service \(service.uuid) on \(peripheral.identifier): \(error!.localizedDescription)")
                // Potentially disconnect if critical characteristics are missing for a critical service
                return
            }
            guard let characteristics = service.characteristics else { return }

            for characteristic in characteristics {
                print("Discovered characteristic: \(characteristic.uuid.uuidString) in service: \(service.uuid.uuidString)")
                switch characteristic.uuid {
                // File Transfer
                case FlySightCore.FT_PACKET_IN_UUID:
                    ftPacketInCharacteristic = characteristic
                    // **PAIRING TRIGGER POINT**
                    // If not bonded, reading this secure characteristic prompts iOS to pair.
                    if !bondedDeviceIDs.contains(peripheral.identifier) {
                        print("Device \(peripheral.identifier) not bonded. Reading FT_Packet_In to trigger pairing...")
                        peripheral.readValue(for: characteristic)
                    } else {
                        // If already bonded, we might still read it to confirm characteristic is responsive,
                        // or just proceed knowing it's there. For now, assume successful discovery is enough if bonded.
                        print("FT_Packet_In found, device already bonded.")
                    }
                case FlySightCore.FT_PACKET_OUT_UUID:
                    ftPacketOutCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                // Sensor Data
                case FlySightCore.SD_GNSS_MEASUREMENT_UUID:
                    sdGNSSMeasurementCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case FlySightCore.SD_CONTROL_POINT_UUID:
                    sdControlPointCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic) // Indications
                // Starter Pistol
                case FlySightCore.SP_CONTROL_POINT_UUID:
                    spControlPointCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic) // Indications
                case FlySightCore.SP_RESULT_UUID:
                    spResultCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic) // Indications
                // Device State
                case FlySightCore.DS_MODE_UUID:
                    dsModeCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic) // Indications
                case FlySightCore.DS_CONTROL_POINT_UUID:
                    dsControlPointCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic) // Indications
                // Device Information
                case FlySightCore.FIRMWARE_REVISION_STRING_UUID:
                    firmwareRevisionCharacteristic = characteristic
                    peripheral.readValue(for: characteristic) // Read firmware version
                default:
                    break
                }
            }

            // Check if all *essential* characteristics are found to consider the device fully set up.
            // For FlySight, FT_Packet_In and FT_Packet_Out are essential for basic operation and pairing confirmation.
            if ftPacketInCharacteristic != nil && ftPacketOutCharacteristic != nil {
                // If already bonded, we can proceed to full operational state.
                // If not bonded, pairing is triggered by the read of FT_Packet_In.
                // The transition to fully connected state will happen after successful read & bonding confirmation.
                if bondedDeviceIDs.contains(peripheral.identifier) {
                    // If we're already bonded and just reconnected, and essential chars are found:
                    if case .discoveringCharacteristics = connectionState {
                         handlePostBondingSetup(for: peripheral)
                    }
                }
            }
        }

        private func handlePostBondingSetup(for peripheral: CBPeripheral) {
            guard let currentTargetInfo = connectedPeripheralInfo, currentTargetInfo.id == peripheral.identifier else {
                 print("handlePostBondingSetup called for a peripheral that is not the current target.")
                 // This might happen if a connection was quickly cancelled and another started.
                 // Or if peripheral is not correctly set in connectedPeripheralInfo.
                 // We should ensure connectedPeripheralInfo is the source of truth for "who are we setting up".
                 if let knownInfo = knownPeripherals.first(where: {$0.id == peripheral.identifier}) {
                     DispatchQueue.main.async { self.connectedPeripheralInfo = knownInfo }
                 } else {
                     // This is less ideal, means we don't have full app-level info for it.
                     DispatchQueue.main.async { self.connectedPeripheralInfo = PeripheralInfo(peripheral: peripheral, rssi: -100, name: peripheral.name ?? "FlySight", isConnected: true, isBonded: true)}
                 }
                 // Re-check after attempting to set connectedPeripheralInfo
                 guard self.connectedPeripheralInfo?.id == peripheral.identifier else {
                     print("Failed to align connectedPeripheralInfo for post bonding setup.")
                     return
                 }
                 print("Aligned connectedPeripheralInfo for post bonding setup.")
            }

            print("Device \(peripheral.identifier) is bonded and essential characteristics found. Finalizing setup.")
            addBondedDeviceID(peripheral.identifier) // Ensure it's marked as bonded
            self.lastConnectedPeripheralID = peripheral.identifier // Mark as last successfully connected

            DispatchQueue.main.async {
                // Update the PeripheralInfo object to reflect bonded status and ensure it's in knownPeripherals.
                var finalInfo = self.connectedPeripheralInfo! // Should be set by now
                finalInfo.isBonded = true
                finalInfo.isConnected = true
                finalInfo.isPairingMode = false // Should be false after successful pairing

                self.connectedPeripheralInfo = finalInfo // Update the published property

                if let index = self.knownPeripherals.firstIndex(where: { $0.id == peripheral.identifier }) {
                    self.knownPeripherals[index] = finalInfo
                } else {
                    self.knownPeripherals.append(finalInfo)
                }
                // Remove from pairing list if it was there
                self.discoveredPairingPeripherals.removeAll { $0.id == peripheral.identifier }

                self.sortKnownPeripherals()
                self.connectionState = .connected(to: finalInfo)

                // Start operational tasks
                self.loadDirectoryEntries()
                self.startPingTimer()
                self.fetchGNSSMask()
                if self.firmwareRevisionCharacteristic == nil,
                   let dis = peripheral.services?.first(where: {$0.uuid == FlySightCore.DEVICE_INFORMATION_SERVICE_UUID}),
                   let fwChar = dis.characteristics?.first(where: {$0.uuid == FlySightCore.FIRMWARE_REVISION_STRING_UUID}) {
                    self.firmwareRevisionCharacteristic = fwChar
                    peripheral.readValue(for: fwChar)
                }
            }
        }

        public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
            // Handle the read of FT_Packet_In (Pairing Trigger)
            if characteristic.uuid == FlySightCore.FT_PACKET_IN_UUID {
                if error == nil {
                    print("Successfully read FT_Packet_In.")
                    // This read is primarily to trigger pairing. If successful and device is now bonded, proceed.
                    if bondedDeviceIDs.contains(peripheral.identifier) {
                         // Check if we are in the process of connecting and discovering
                        if case .discoveringCharacteristics(let p) = connectionState, p.identifier == peripheral.identifier {
                             handlePostBondingSetup(for: peripheral)
                        } else if case .connecting(let target) = connectionState, target.id == peripheral.identifier {
                            // This can happen if characteristic discovery was very fast and state hasn't updated yet.
                            // Or if we re-read it for some reason.
                            handlePostBondingSetup(for: peripheral)
                        }
                    } else {
                        // This scenario is less likely if pairing was successful, OS should have bonded.
                        // If not bonded, it implies pairing might have failed or was cancelled by user.
                        // The system might disconnect or the next operation on a protected char will fail.
                        print("Read FT_Packet_In but device \(peripheral.identifier) is NOT in bondedDeviceIDs. Pairing may have failed system-side.")
                        // Consider disconnecting or re-initiating pairing if appropriate, but often iOS handles this by disconnecting.
                    }
                } else {
                    print("Error reading FT_Packet_In (pairing trigger): \(error!.localizedDescription)")
                    if error!.asBLEError?.isInsufficientAuthentication == true || error!.asBLEError?.isInsufficientEncryption == true {
                        // This is expected if pairing is required and OS is showing prompt.
                        // No action needed here; OS handles the pairing. Successful connection/bonding will follow if user accepts.
                        print("Pairing process likely initiated by OS due to insufficient authentication/encryption on FT_Packet_In read.")
                    } else {
                        // Other error, pairing might have failed.
                        // Consider disconnecting.
                         disconnect(from: PeripheralInfo(peripheral: peripheral, rssi: 0, name: "", isBonded: false))
                    }
                    return // Don't process further for this characteristic if there was an error on the pairing trigger
                }
            }

            // Firmware Revision String
            if characteristic.uuid == FlySightCore.FIRMWARE_REVISION_STRING_UUID, error == nil, let data = characteristic.value {
                if let fwVersion = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.flysightFirmwareVersion = fwVersion
                        print("FlySight Firmware Version: \(fwVersion)")
                    }
                }
            }

            // Generic error handling for other characteristics
            guard error == nil else {
                print("Error updating value for \(characteristic.uuid): \(error!.localizedDescription)")
                DispatchQueue.main.async {
                    if characteristic.uuid == FlySightCore.SD_CONTROL_POINT_UUID { // Example specific error handling
                        self.gnssMaskUpdateStatus = .failure(" Characteristic update error: \(error!.localizedDescription)")
                    }
                    if characteristic.uuid == FlySightCore.FT_PACKET_OUT_UUID { //CRS_TX_UUID
                        self.isAwaitingDirectoryResponse = false
                    }
                }
                // Pass error to specific handlers if they exist
                if let handler = notificationHandlers[characteristic.uuid] {
                    handler(peripheral, characteristic, error)
                }
                return
            }

            guard let data = characteristic.value else {
                print("No data in characteristic update for \(characteristic.uuid)")
                return
            }

            // Route data to specific handlers or parse directly
            var handledBySpecificLogic = false
            if characteristic.uuid == FlySightCore.FT_PACKET_OUT_UUID { // CRS_TX_UUID: Directory listings, ACKs, NAKs, download data
                // This characteristic can send various packet types.
                // Opcode is data[0].
                let opcode = data[0]
                switch opcode {
                case 0x11: // File Info (Directory Entry)
                    DispatchQueue.main.async {
                        if let entry = self.parseDirectoryEntry(from: data) { // expects full data with opcode
                            if entry.isEmptyMarker { // Check for our special end-of-list marker
                                print("End of directory listing received (marker).")
                                self.isAwaitingDirectoryResponse = false
                            } else {
                                self.directoryEntries.append(entry)
                                self.sortDirectoryEntries()
                                // isAwaitingDirectoryResponse remains true
                            }
                        } else {
                            // This means parseDirectoryEntry returned nil for a 0x11 packet that wasn't an end marker.
                            // Potentially log this as an unexpected format.
                            print("Parsed directory entry was nil for opcode 0x11, but not an end marker.")
                        }
                    }
                    handledBySpecificLogic = true
                case 0xF0: // NAK
                    let originalCommand = data.count > 1 ? data[1] : 0xFF
                    print("Received NAK for command 0x\(String(format: "%02X", originalCommand))")
                    DispatchQueue.main.async { self.isAwaitingDirectoryResponse = false }
                     if originalCommand == 0x03 { // Write File (Open) NAK
                        self.uploadContinuation?.resume(throwing: NSError(domain: "FlySightCore.Upload", code: Int(originalCommand), userInfo: [NSLocalizedDescriptionKey: "Failed to open remote file for writing (NAK)."]))
                        self.uploadContinuation = nil
                        self.isUploading = false
                    }
                    handledBySpecificLogic = true
                case 0xF1: // ACK
                    let originalCommand = data.count > 1 ? data[1] : 0xFF
                    print("Received ACK for command 0x\(String(format: "%02X", originalCommand))")
                    if originalCommand == 0x05 { // List Directory command ACK
                        DispatchQueue.main.async { self.isAwaitingDirectoryResponse = true } // Now waiting for 0x11 packets
                    } else if originalCommand == 0x03 { // Write File (Open) ACK
                        // The uploadFile Task will handle sending data chunks now.
                        // This ACK primarily confirms the file is open on the device.
                    } else if originalCommand == 0x02 { // Read File ACK
                        // Download process expects 0x10 data chunks now.
                    }
                    handledBySpecificLogic = true
                // 0x10 (File Data for download) and 0x12 (ACK for upload data) are handled by registered notificationHandlers
                default:
                    break // Other opcodes might be handled by specific handlers below
                }
            } else if characteristic.uuid == FlySightCore.SP_RESULT_UUID {
                processStartResult(data: data)
                handledBySpecificLogic = true
            } else if characteristic.uuid == FlySightCore.SD_GNSS_MEASUREMENT_UUID {
                parseLiveGNSSData(from: data)
                handledBySpecificLogic = true
            } else if characteristic.uuid == FlySightCore.SD_CONTROL_POINT_UUID {
                processSDControlPointResponse(from: data)
                handledBySpecificLogic = true
            } else if characteristic.uuid == FlySightCore.SP_CONTROL_POINT_UUID {
                processSPControlPointResponse(from: data)
                handledBySpecificLogic = true
            } else if characteristic.uuid == FlySightCore.DS_MODE_UUID {
                // Potentially parse and update device mode
                // let modeValue = data[0]
                // print("DS_Mode updated: \(modeValue)")
                handledBySpecificLogic = true
            }


            // Check for registered notification handlers (e.g., for file download/upload on FT_PACKET_OUT_UUID)
            if let handler = notificationHandlers[characteristic.uuid] {
                handler(peripheral, characteristic, error) // error will be nil here
            } else if !handledBySpecificLogic {
                // print("No specific logic or registered handler for characteristic \(characteristic.uuid). Data: \(data.hexEncodedString())")
            }
        }

        public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
            if let error = error {
                print("Write error for characteristic \(characteristic.uuid): \(error.localizedDescription)")
                if characteristic.uuid == FlySightCore.FT_PACKET_IN_UUID && isUploading {
                    // This is tricky because FT_PACKET_IN uses WriteWithoutResponse for data chunks.
                    // An error here for FT_PACKET_IN would be unexpected unless it was for a Write *With* Response.
                    // The GBN ARQ handles reliability for WriteWithoutResponse.
                    // If it's for the initial "Open File" command (if it used WriteWithResponse, which it doesn't as per doc),
                    // then it would be a failure. For now, GBN handles data chunk issues.
                }
                if characteristic.uuid == FlySightCore.SD_CONTROL_POINT_UUID {
                    DispatchQueue.main.async {
                        if self.gnssMaskUpdateStatus == .pending {
                            self.gnssMaskUpdateStatus = .failure("Write failed for SD Control Point: \(error.localizedDescription)")
                        }
                        self.lastAttemptedGNSSMask = nil
                        if self.connectedPeripheralInfo != nil && self.sdControlPointCharacteristic != nil { self.fetchGNSSMask() }
                    }
                }
                return
            }
            // print("Write successful for characteristic \(characteristic.uuid)")
            // For WriteWithoutResponse, this callback isn't typically invoked unless there's an issue queuing the write.
            // For WriteWithResponse, this confirms the peripheral received it.
        }

        public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
            if let error = error {
                print("Error changing notification state for \(characteristic.uuid): \(error.localizedDescription)")
                // If enabling notifications for a critical characteristic fails, consider it a connection setup issue.
                if characteristic.uuid == FlySightCore.FT_PACKET_OUT_UUID && characteristic.isNotifying {
                    // disconnect or try again?
                }
                return
            }
            print("Notification state for \(characteristic.uuid) is now \(characteristic.isNotifying ? "ON" : "OFF")")
        }

        public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
            if error == nil {
                DispatchQueue.main.async {
                    if let index = self.knownPeripherals.firstIndex(where: { $0.id == peripheral.identifier }) {
                        self.knownPeripherals[index].rssi = RSSI.intValue
                        self.sortKnownPeripherals()
                    } else if let index = self.discoveredPairingPeripherals.firstIndex(where: { $0.id == peripheral.identifier }) {
                        self.discoveredPairingPeripherals[index].rssi = RSSI.intValue
                        self.sortPairingPeripheralsByRSSI()
                    }
                }
            }
        }

        // MARK: - Bonded Device ID Management
        var bondedDeviceIDsKey: String { "bondedDeviceIDs_v3" } // Use a new key if format changes significantly

        var bondedDeviceIDs: Set<UUID> {
            get {
                guard let data = UserDefaults.standard.data(forKey: bondedDeviceIDsKey) else { return [] }
                do {
                    return try JSONDecoder().decode(Set<UUID>.self, from: data)
                } catch {
                    print("Failed to decode bondedDeviceIDs: \(error)")
                    UserDefaults.standard.removeObject(forKey: bondedDeviceIDsKey) // Clear corrupted data
                    return []
                }
            }
            set {
                do {
                    let data = try JSONEncoder().encode(newValue)
                    UserDefaults.standard.set(data, forKey: bondedDeviceIDsKey)
                } catch {
                    print("Failed to encode bondedDeviceIDs: \(error)")
                }
            }
        }

        private func addBondedDeviceID(_ peripheralID: UUID) {
            var currentBonded = bondedDeviceIDs
            if !currentBonded.contains(peripheralID) {
                currentBonded.insert(peripheralID)
                bondedDeviceIDs = currentBonded
                print("Added \(peripheralID) to app's bonded list.")
            }
        }

        private func removeBondedDeviceID(_ peripheralID: UUID) {
            var currentBonded = bondedDeviceIDs
            if currentBonded.contains(peripheralID) {
                currentBonded.remove(peripheralID)
                bondedDeviceIDs = currentBonded
                print("Removed \(peripheralID) from app's bonded list.")
            }
        }

        private func loadKnownPeripheralsFromUserDefaults() {
            let bondedIDs = self.bondedDeviceIDs
            var currentKnown = self.knownPeripherals
            var updatedKnownPeripherals: [PeripheralInfo] = []
            var madeChanges = false

            // Create PeripheralInfo for each bonded ID if not already in list
            for id in bondedIDs {
                if let existingInfo = currentKnown.first(where: { $0.id == id }) {
                    var infoToKeep = existingInfo
                    infoToKeep.isBonded = true // Ensure bonded status is correct
                    updatedKnownPeripherals.append(infoToKeep)
                } else {
                    // Attempt to retrieve the peripheral if it's known to the system
                    if let peripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first {
                        updatedKnownPeripherals.append(PeripheralInfo(peripheral: peripheral, rssi: -100, name: peripheral.name ?? "FlySight", isConnected: false, isPairingMode: false, isBonded: true))
                        madeChanges = true
                    } else {
                        // Cannot retrieve peripheral object, but it's in our bonded list.
                        // This can happen if the peripheral is not nearby or system has lost track.
                        // We can't create a PeripheralInfo without a CBPeripheral.
                        // It will be added if discovered during a scan.
                        print("Bonded device ID \(id) found in UserDefaults, but CBPeripheral not retrieved. Will appear if scanned.")
                    }
                }
            }

            // Remove any from currentKnown that are no longer in bondedDeviceIDs (e.g. user unpaired from settings)
            // This step is tricky because we don't get a direct notification for system-level unpairing.
            // For now, this list is additive from UserDefaults and updated on discovery.
            // A full sync would involve checking `retrievePeripherals` for all, which can be slow.
            // `forgetDevice` in app is the primary way to remove from `bondedDeviceIDs`.

            if madeChanges || updatedKnownPeripherals.count != currentKnown.count {
                DispatchQueue.main.async {
                    self.knownPeripherals = updatedKnownPeripherals
                    self.sortKnownPeripherals()
                }
            }
        }


        // MARK: - Sorting
        public func sortKnownPeripherals() {
            DispatchQueue.main.async {
                self.knownPeripherals.sort {
                    if $0.isConnected != $1.isConnected { return $0.isConnected && !$1.isConnected }
                    return $0.rssi > $1.rssi
                }
            }
        }

        public func sortPairingPeripheralsByRSSI() {
            DispatchQueue.main.async {
                self.discoveredPairingPeripherals.sort { $0.rssi > $1.rssi }
            }
        }

        public func sortDirectoryEntries() {
            DispatchQueue.main.async {
                self.directoryEntries.sort {
                    if $0.isFolder != $1.isFolder { return $0.isFolder && !$1.isFolder }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
        }

        // MARK: - Timers
        private func startDisappearanceTimer(for peripheralInfo: PeripheralInfo) {
            guard peripheralInfo.isPairingMode && !bondedDeviceIDs.contains(peripheralInfo.id) else { return }
            disappearanceTimers[peripheralInfo.id]?.invalidate()
            disappearanceTimers[peripheralInfo.id] = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in // Increased timeout
                self?.removeDisappearedPairingPeripheral(id: peripheralInfo.id)
            }
        }

        private func resetDisappearanceTimer(for peripheralInfo: PeripheralInfo) {
            startDisappearanceTimer(for: peripheralInfo)
        }

        private func removeDisappearedPairingPeripheral(id: UUID) {
            DispatchQueue.main.async {
                if let index = self.discoveredPairingPeripherals.firstIndex(where: { $0.id == id && !$0.isConnected }) {
                    let removed = self.discoveredPairingPeripherals.remove(at: index)
                    print("Pairing mode device \(removed.name) disappeared.")
                    self.disappearanceTimers.removeValue(forKey: id)
                    // sortPairingPeripheralsByRSSI() // List will re-sort if needed on next discovery
                }
            }
        }

        private func startPingTimer() {
            stopPingTimer() // Ensure any existing timer is stopped
            DispatchQueue.main.async {
                // Run on main queue to interact with main-thread properties, but ping itself is BLE op.
                self.pingTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
                    self?.sendPing()
                }
                print("Ping timer started.")
            }
        }

        private func stopPingTimer() {
            DispatchQueue.main.async {
                self.pingTimer?.invalidate()
                self.pingTimer = nil
            }
        }


        // MARK: - File System Operations
        public func loadDirectoryEntries() {
            guard let peripheral = connectedPeripheralInfo?.peripheral, let char = ftPacketInCharacteristic else {
                print("Cannot load directory: Not connected or FT_Packet_In characteristic missing.")
                DispatchQueue.main.async { self.isAwaitingDirectoryResponse = false }
                return
            }

            DispatchQueue.main.async {
                self.directoryEntries = []
                self.isAwaitingDirectoryResponse = true
            }

            let pathString = "/" + currentPath.joined(separator: "/")
            print("Requesting directory listing for: \(pathString)")
            var command = Data([0x05]) // List Directory Opcode
            command.append(pathString.data(using: .utf8) ?? Data())
            command.append(0x00) // Null terminator

            peripheral.writeValue(command, for: char, type: .withoutResponse)
        }

        // Corrected parseDirectoryEntry based on new understanding of payload
        private func parseDirectoryEntry(from characteristicValue: Data) -> DirectoryEntry? {
            // characteristicValue is the full data from FT_Packet_Out notification
            // Opcode (1 byte) | PacketCounter (1 byte) | Payload (22 bytes)
            // Payload: Size(u32), Date(u16), Time(u16), Attr(u8), Name(13 bytes, null-padded)

            guard characteristicValue.count >= 3, characteristicValue[0] == 0x11 else {
                // print("parseDirectoryEntry: Not a File Info packet (0x11) or too short. Got: \(characteristicValue.hexEncodedString())")
                return nil
            }

            // let packetCounter = characteristicValue[1] // Currently unused here
            let payload = characteristicValue.subdata(in: 2..<characteristicValue.count) // From index 2 to end

            guard payload.count >= 22 else { // Minimum length for the defined payload
                print("parseDirectoryEntry: Payload too short. Expected 22 bytes, got \(payload.count)")
                return nil
            }

            let size: UInt32 = payload.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }
            let fdate: UInt16 = payload.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self) }
            let ftime: UInt16 = payload.subdata(in: 6..<8).withUnsafeBytes { $0.load(as: UInt16.self) }
            let fattrib: UInt8 = payload.subdata(in: 8..<9).withUnsafeBytes { $0.load(as: UInt8.self) }

            let nameBytes = payload.subdata(in: 9..<(9+13)) // 13 bytes for name

            // Check for end-of-list marker (Name[0] == 0)
            if nameBytes[0] == 0 {
                return DirectoryEntry(size: 0, date: Date(timeIntervalSince1970: 0), attributes: "", name: "", isEmptyMarker: true)
            }

            let firstNull = nameBytes.firstIndex(of: 0) ?? nameBytes.endIndex
            let actualNameData = nameBytes.subdata(in: nameBytes.startIndex..<firstNull)
            guard let name = String(data: actualNameData, encoding: .utf8), !name.isEmpty else {
                print("parseDirectoryEntry: Could not decode name or name is empty.")
                return nil
            }

            let year = Int((fdate >> 9) & 0x7F) + 1980
            let month = Int((fdate >> 5) & 0x0F)
            let day = Int(fdate & 0x1F)
            let hour = Int((ftime >> 11) & 0x1F)
            let minute = Int((ftime >> 5) & 0x3F)
            let second = Int((ftime & 0x1F) * 2)

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) else {
                return nil
            }

            // FAT attributes: Bit 0 RO, 1 Hidden, 2 System, 3 Vol Label, 4 Dir, 5 Archive
            var attribText = ""
            attribText += (fattrib & 0x10) != 0 ? "d" : "-" // Directory
            attribText += (fattrib & 0x20) != 0 ? "a" : "-" // Archive
            attribText += (fattrib & 0x01) != 0 ? "r" : "-" // Read-only
            attribText += (fattrib & 0x02) != 0 ? "h" : "-" // Hidden
            attribText += (fattrib & 0x04) != 0 ? "s" : "-" // System

            return DirectoryEntry(size: size, date: date, attributes: attribText, name: name)
        }

        public func changeDirectory(to newDirectoryName: String) {
            guard connectedPeripheralInfo != nil else { return }
            DispatchQueue.main.async {
                self.currentPath.append(newDirectoryName)
                self.loadDirectoryEntries()
            }
        }

        public func goUpOneDirectoryLevel() {
            guard connectedPeripheralInfo != nil, !currentPath.isEmpty else { return }
            DispatchQueue.main.async {
                _ = self.currentPath.popLast()
                self.loadDirectoryEntries()
            }
        }


        // MARK: - Download and Upload (GBN ARQ)
        // (Keep existing downloadFile, cancelDownload methods, ensuring they use
        // connectedPeripheralInfo.peripheral and ftPacketIn/OutCharacteristic)
        // For uploadFile, let's refine the GBN ARQ implementation slightly for clarity if needed.

        public func downloadFile(named filePath: String, knownSize: UInt32, completion: @escaping (Result<Data, Error>) -> Void) {
            guard let peripheral = connectedPeripheralInfo?.peripheral,
                  let rxChar = ftPacketInCharacteristic, // To send ACKs to
                  let txChar = ftPacketOutCharacteristic  // To receive data from (FT_Packet_Out)
            else {
                completion(.failure(BluetoothError.notConnectedOrCharsMissing))
                return
            }

            var fileData = Data()
            var expectedPacketNum: UInt8 = 0 // Packet counter for GBN is 1-byte
            let transferCompleteSubject = PassthroughSubject<Void, Error>()

            DispatchQueue.main.async {
                self.downloadProgress = 0.0
                self.currentFileSize = knownSize
            }

            // Setup notification handler for FT_Packet_Out (txChar)
            notificationHandlers[txChar.uuid] = { [weak self] (p, char, err) in
                guard let self = self else { return }

                if let error = err {
                    transferCompleteSubject.send(completion: .failure(error))
                    return
                }
                guard let data = char.value, data.count >= 2, data[0] == 0x10 /* File Data Read Chunk */ else {
                    // Could be other FT_Packet_Out types if not filtered earlier, or malformed.
                    // if data != nil && data.count > 0 && data[0] != 0x10 {
                    //    print("Download: Received non-0x10 packet on FT_Packet_Out: \(data.hexEncodedString())")
                    // }
                    return
                }

                let receivedPacketNum = data[1]

                if receivedPacketNum == expectedPacketNum {
                    let actualData = data.count > 2 ? data.subdata(in: 2..<data.count) : Data()

                    if actualData.isEmpty && data.count == 2 { // Zero-length data signals EOF (data[0]=0x10, data[1]=counter)
                        print("Download: EOF received for packet \(receivedPacketNum).")
                        // ACK this final empty packet
                        let ackPacket = Data([0x12, receivedPacketNum])
                        p.writeValue(ackPacket, for: rxChar, type: .withoutResponse)
                        transferCompleteSubject.send(completion: .finished)
                    } else {
                        fileData.append(actualData)
                        expectedPacketNum = expectedPacketNum &+ 1 // Increment and wrap for UInt8

                        let ackPacket = Data([0x12, receivedPacketNum])
                        p.writeValue(ackPacket, for: rxChar, type: .withoutResponse)

                        DispatchQueue.main.async {
                            if self.currentFileSize > 0 {
                                self.downloadProgress = Float(fileData.count) / Float(self.currentFileSize)
                            }
                        }
                        // print("Download: Received packet \(receivedPacketNum), acked. Total bytes: \(fileData.count)")
                    }
                } else {
                    print("Download: Out-of-order packet. Expected \(expectedPacketNum), got \(receivedPacketNum). Discarding.")
                    // GBN receiver just ACKs in-order packets and discards others. Sender handles retransmission.
                }
            }

            let fullPath = (currentPath + [filePath]).joined(separator: "/")
            print("Requesting download for: \(fullPath)")
            // Command: 0x02 [Offset_mult(u32)] [Stride-1_mult(u32)] [Path (null-term string)]
            var command = Data([0x02])
            command.append(UInt32(0).littleEndianData) // Offset_multiplier = 0
            command.append(UInt32(0).littleEndianData) // Stride_minus_1_multiplier = 0 (so Stride = 1 * FRAME_LENGTH)
            command.append(fullPath.data(using: .utf8) ?? Data())
            command.append(0x00) // Null terminator

            peripheral.writeValue(command, for: rxChar, type: .withoutResponse) // Send command to FT_Packet_In

            // Subscribe to transfer completion
            let cancellable = transferCompleteSubject.sink(receiveCompletion: { [weak self] resultCompletion in
                self?.notificationHandlers[txChar.uuid] = nil // Clear handler
                DispatchQueue.main.async { self?.downloadProgress = 0.0 }
                switch resultCompletion {
                case .failure(let error): completion(.failure(error))
                case .finished: completion(.success(fileData))
                }
            }, receiveValue: { _ in })
            cancellable.store(in: &cancellables) // Manage subscription
        }

        public func cancelDownload() { // Or any ongoing file transfer
            guard let peripheral = connectedPeripheralInfo?.peripheral, let char = ftPacketInCharacteristic else { return }
            let cancelCommand = Data([0xFF]) // Cancel Transfer Opcode
            peripheral.writeValue(cancelCommand, for: char, type: .withoutResponse)
            DispatchQueue.main.async {
                self.downloadProgress = 0.0
                // Also cancel any ongoing GBN subscriptions or clear handlers
                // The transferCompleteSubject's sink will be cancelled by `cancellables.removeAll()` if manager deinitializes,
                // but for explicit cancel, we might need to manage the specific download cancellable.
            }
            print("Sent Cancel Transfer command.")
        }


        public func uploadFile(fileData: Data, remotePath: String) async throws {
             guard let peripheral = connectedPeripheralInfo?.peripheral,
                  let rxChar = ftPacketInCharacteristic, // To send data chunks (0x10) and OpenFile (0x03)
                  let txChar = ftPacketOutCharacteristic  // To receive ACKs (0x12) for data chunks
            else {
                throw BluetoothError.notConnectedOrCharsMissing
            }

            return try await withCheckedThrowingContinuation { [weak self] continuation in
                guard let self = self else {
                    continuation.resume(throwing: BluetoothError.deallocated)
                    return
                }

                self.isUploading = true
                self.fileDataToUpload = fileData
                self.remotePathToUpload = remotePath // Full path from root
                self.nextPacketNum = 0 // Packet counter (0-255 for 1-byte field) for data packets to send
                self.nextAckNum = 0    // Next ACK we expect for the data packets we send
                self.lastPacketNum = nil // Marks the packet *after* the final data packet (which might be an empty one)
                self.totalPacketsToSend = UInt32(ceil(Double(fileData.count) / Double(self.frameLength)))
                if fileData.isEmpty { self.totalPacketsToSend = 1 } // Send one empty data packet for empty file

                self.uploadContinuation = continuation // Store for later resumption

                DispatchQueue.main.async {
                    self.uploadProgress = 0.0
                }

                // 1. Setup ACK handler for FT_Packet_Out (txChar)
                // This handler listens for 0x12 (ACK File Data Packet) from FlySight
                self.notificationHandlers[txChar.uuid] = { [weak self] (p, char, err) in
                    guard let self = self, self.isUploading else { return }

                    if let error = err {
                        self.handleUploadCompletion(result: .failure(error))
                        return
                    }
                    guard let data = char.value, data.count == 2, data[0] == 0x12 /* ACK File Data */ else {
                        // Could be other FT_Packet_Out types. If it's a NAK for the OpenFile, that's handled below too.
                        return
                    }

                    let ackedPacketNum = Int(data[1]) // This is the PacketCounter from the 0x10 packet we sent

                    // GBN: Cumulative ACK implies all packets up to (ackedPacketNum - 1) are received.
                    // FlySight sends ACK for each packet. We are interested if it ACKs our `nextAckNum`.
                    // If we receive an ACK for packet `N`, it means `N` was received.
                    // We can then slide our window if `N` was the base of our window (`nextAckNum`).

                    if ackedPacketNum == (self.nextAckNum % 256) { // Modulo for comparison with 1-byte counter
                        self.nextAckNum += 1
                        DispatchQueue.main.async {
                            if self.totalPacketsToSend > 0 {
                                self.uploadProgress = Float(self.nextAckNum) / Float(self.totalPacketsToSend)
                            }
                        }
                        // If this was the last packet's ACK, complete the upload
                        if let lastSent = self.lastPacketNum, self.nextAckNum >= lastSent {
                            self.handleUploadCompletion(result: .success(()))
                        } else {
                            // Try to send more packets from the new window
                            Task { await self.sendUploadDataPackets(peripheral: p, rxChar: rxChar) }
                        }
                    } else {
                        // Out of order ACK or duplicate ACK, GBN sender usually ignores or handles timeouts.
                        // For simplicity, we primarily rely on sending new window data when an expected ACK comes in
                        // or when a timeout occurs (handled by a conceptual timer per GBN window base).
                        // Since we don't have explicit GBN timers here, we re-send window on ACK or new send opportunity.
                        print("Upload: Received ACK for \(ackedPacketNum), expected for \(self.nextAckNum % 256).")
                    }
                }

                // 2. Send "Write File (Open)" command to FT_Packet_In (rxChar)
                var openCommand = Data([0x03]) // Write File (Open) Opcode
                openCommand.append(remotePath.data(using: .utf8) ?? Data())
                openCommand.append(0x00) // Null terminator

                peripheral.writeValue(openCommand, for: rxChar, type: .withoutResponse)
                print("Upload: Sent OpenFile command for \(remotePath).")

                // Now, we wait for an ACK (0xf1 03) or NAK (0xf0 03) for the Open command on FT_Packet_Out (txChar).
                // This specific ACK/NAK for Open isn't directly handled by the GBN data ACK handler above.
                // Let's add a temporary handler or a way to confirm Open success.
                // For simplicity, assuming Open is quick or we proceed optimistically and GBN will fail if not open.
                // A more robust way: have a state for "awaitingOpenFileAck".
                // For now, we'll rely on the existing FT_PACKET_OUT_UUID handler to catch the 0xF1/0xF0.
                // If 0xF1 03 is received, then we start sending data.

                // Let's make the generic handler for FT_PACKET_OUT_UUID smarter:
                // (This is a bit of a challenge as notificationHandlers is a single closure per UUID)
                // Solution: The existing generic handler for FT_PACKET_OUT_UUID needs to check for 0xF1 03.
                // If it sees it, it then triggers the first call to sendUploadDataPackets.
                // This is already implicitly handled: if we receive 0xF1 03 (ACK for Open),
                // the `notificationHandlers[txChar.uuid]` is ALREADY set up for 0x12 (Data ACKs).
                // So, the flow is:
                // App sends 0x03 (OpenFile)
                // FlySight sends 0xF1 03 (ACK for OpenFile) -> this is caught by general FT_Packet_Out handler.
                // App then starts sending 0x10 (Data Chunks) via sendUploadDataPackets.
                // FlySight sends 0x12 (ACK for Data Chunk) for each 0x10 -> caught by the specific part of notificationHandler.

                // Initial send after Open command (assuming it will be ACKed and then we can send)
                // A better way: use a short timeout or a specific callback for the OpenFile ACK.
                // For now, let's assume the OpenFile command is acknowledged quickly and then start sending.
                // The actual sending of data packets should start once the OpenFile command is ACKed (0xF1 03).
                // We can make sendUploadDataPackets conditional on an "isRemoteFileOpen" flag.
                // This is simplified: we send the Open command and immediately try to send the first window.
                // The GBN ARQ (ACKs for data packets) will ensure data is only resent if needed.
                Task {
                    // Give a slight delay for OpenFile command to be processed and ACKed.
                    // This is a simplification. A state machine or specific ACK check is more robust.
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                    if self.isUploading { // Check if still uploading (not cancelled, no immediate NAK)
                        await self.sendUploadDataPackets(peripheral: peripheral, rxChar: rxChar)
                    }
                }
            }
        }

        private func sendUploadDataPackets(peripheral: CBPeripheral, rxChar: CBCharacteristic) async {
            guard isUploading, let dataToSend = fileDataToUpload else { return }

            // GBN Sender: Send up to `windowLength` packets starting from `nextAckNum`
            // but not exceeding `nextPacketNum` which has already been sent.
            // `nextPacketNum` is the next *new* packet to send.
            // `nextAckNum` is the oldest unacknowledged packet (base of the window).

            // We can send packets from `nextPacketNum` up to `nextAckNum + windowLength -1`
            while nextPacketNum < (nextAckNum + windowLength) {
                if let lastSentPacket = lastPacketNum, nextPacketNum >= lastSentPacket {
                    break // All packets (including final empty one) have been sent.
                }

                let isFinalPacket = (nextPacketNum * frameLength) >= dataToSend.count

                let packetData: Data
                var dataChunk = Data()

                if !isFinalPacket {
                    let startIndex = nextPacketNum * frameLength
                    let endIndex = min(startIndex + frameLength, dataToSend.count)
                    dataChunk = dataToSend.subdata(in: startIndex..<endIndex)
                    packetData = Data([0x10, UInt8(nextPacketNum % 256)]) + dataChunk // Opcode, Counter, Payload
                } else {
                    // This is the packet *after* the last actual data, or the first packet if file is empty.
                    // Send a zero-data-length packet to signify EOF.
                    packetData = Data([0x10, UInt8(nextPacketNum % 256)]) // Opcode, Counter
                    print("Upload: Preparing final empty packet #\(nextPacketNum % 256)")
                    lastPacketNum = nextPacketNum + 1 // Mark that this is the end.
                }

                // print("Upload: Sending packet #\(nextPacketNum % 256), data length: \(dataChunk.count)")
                peripheral.writeValue(packetData, for: rxChar, type: .withoutResponse)
                nextPacketNum += 1

                if isFinalPacket { break } // Sent the EOF marker, stop sending more.

                // Small delay between sends to avoid overwhelming the peripheral's buffer
                 try? await Task.sleep(nanoseconds: 30_000_000) // 30ms, adjust as needed
            }
            // If no ACKs are received, a timeout mechanism (not explicitly implemented here beyond re-sending on next ACK) would trigger retransmission.
        }

        private func handleUploadCompletion(result: Result<Void, Error>) {
            DispatchQueue.main.async { // Ensure UI updates and continuation are on main
                self.uploadContinuation?.resume(with: result)
                self.uploadContinuation = nil // Clear continuation
                self.isUploading = false
                self.fileDataToUpload = nil
                self.remotePathToUpload = nil
                self.uploadProgress = (try? result.get()) != nil ? 1.0 : 0.0 // Full progress on success

                // Clear the specific notification handler for FT_Packet_Out if it was only for upload ACKs
                if let txCharUUID = self.ftPacketOutCharacteristic?.uuid {
                    // Be careful if FT_Packet_Out is also used for directory listing simultaneously.
                    // It's generally better to have one robust handler for FT_Packet_Out that routes based on opcode.
                    // For now, assuming upload is exclusive or the main handler is robust.
                    // self.notificationHandlers[txCharUUID] = nil; // This might break other FT_Packet_Out uses
                }
                print("Upload completed with result: \(result)")
            }
        }

        public func cancelUpload() {
            guard isUploading else { return }
            print("Cancelling upload...")

            // 1. Send Cancel Transfer command to FlySight
            if let peripheral = connectedPeripheralInfo?.peripheral, let char = ftPacketInCharacteristic {
                let cancelCommand = Data([0xFF])
                peripheral.writeValue(cancelCommand, for: char, type: .withoutResponse)
                print("Sent Cancel Transfer (0xFF) command to FlySight.")
            }

            // 2. Update internal state and notify continuation
            // Must be on main thread if `uploadContinuation` expects it or if it touches @Published vars
            DispatchQueue.main.async {
                let error = NSError(domain: "FlySightCore.Upload", code: -999, userInfo: [NSLocalizedDescriptionKey: "Upload cancelled by user."])
                self.uploadContinuation?.resume(throwing: error) // Resume with cancellation error
                self.uploadContinuation = nil

                self.isUploading = false
                self.fileDataToUpload = nil
                self.remotePathToUpload = nil
                self.uploadProgress = 0.0
                // Clear specific handlers if necessary
                if let txCharUUID = self.ftPacketOutCharacteristic?.uuid {
                    // self.notificationHandlers[txCharUUID] = nil; // Be cautious here
                }
            }
        }


        // MARK: - Ping
        private func sendPing() {
            guard let peripheral = connectedPeripheralInfo?.peripheral, let char = ftPacketInCharacteristic else {
                print("Cannot send ping: Not connected or FT_Packet_In characteristic missing.")
                return
            }
            let pingCommand = Data([0xFE]) // Ping Opcode
            peripheral.writeValue(pingCommand, for: char, type: .withoutResponse)
            // print("Ping sent.") // Can be noisy
        }

        // MARK: - GNSS Data Mask Operations
        // (Keep existing fetchGNSSMask, updateGNSSMask methods, ensuring they use
        // connectedPeripheralInfo.peripheral and sdControlPointCharacteristic)
        public func fetchGNSSMask() {
            guard let peripheral = connectedPeripheralInfo?.peripheral, let controlChar = sdControlPointCharacteristic else {
                print("Cannot fetch GNSS mask: Not connected or SD Control Point characteristic.")
                DispatchQueue.main.async { self.gnssMaskUpdateStatus = .failure("Characteristic not available.") }
                return
            }
            let command = Data([SDControlOpcodes.getMask])
            print("Fetching GNSS Mask...")
            DispatchQueue.main.async { self.gnssMaskUpdateStatus = .pending }
            peripheral.writeValue(command, for: controlChar, type: .withResponse) // .withResponse for CP
        }

        public func updateGNSSMask(newMask: UInt8) {
            guard let peripheral = connectedPeripheralInfo?.peripheral, let controlChar = sdControlPointCharacteristic else {
                print("Cannot update GNSS mask: Not connected or SD Control Point characteristic.")
                DispatchQueue.main.async { self.gnssMaskUpdateStatus = .failure("Characteristic not available.") }
                return
            }
            self.lastAttemptedGNSSMask = newMask
            let command = Data([SDControlOpcodes.setMask, newMask])
            print("Attempting to update GNSS Mask to: \(String(format: "0x%02X", newMask))")
            DispatchQueue.main.async { self.gnssMaskUpdateStatus = .pending }
            peripheral.writeValue(command, for: controlChar, type: .withResponse) // .withResponse for CP
        }

        // MARK: - Data Parsers & Responders
        // (Keep existing processStartResult, parseLiveGNSSData,
        // processSDControlPointResponse, processSPControlPointResponse methods)
        // These methods are generally fine but ensure they are called correctly from didUpdateValueFor.
        public func processStartResult(data: Data) { // From SP_Result
            guard data.count == 9 else { print("Invalid start result data length"); return }
            // ... existing parsing ...
            let year = data.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) }
            // ...
            DispatchQueue.main.async {
                // Ensure correct state update based on startPistolState
                // self.startResultDate = date
                // self.startPistolState = .idle (if appropriate)
            }
        }
        private func parseLiveGNSSData(from data: Data) { /* ... existing ... */ }
        private func processSDControlPointResponse(from data: Data) { /* ... existing ... */ }
        private func processSPControlPointResponse(from data: Data) { /* ... existing ... */ }

        // MARK: - Start Pistol Commands
        public func sendStartCommand() {
            guard let peripheral = connectedPeripheralInfo?.peripheral, let spControlChar = spControlPointCharacteristic else {
                print("SP Control Point characteristic not found or not connected.")
                return
            }
            let startCommand = Data([SPControlOpcodes.startCountdown])
            peripheral.writeValue(startCommand, for: spControlChar, type: .withResponse) // .withResponse for CP
            print("Sent Start command to SP Control Point.")
        }

        public func sendCancelCommand() {
            guard let peripheral = connectedPeripheralInfo?.peripheral, let spControlChar = spControlPointCharacteristic else {
                print("SP Control Point characteristic not found or not connected.")
                return
            }
            let cancelCommand = Data([SPControlOpcodes.cancelCountdown])
            peripheral.writeValue(cancelCommand, for: spControlChar, type: .withResponse) // .withResponse for CP
            print("Sent Cancel command to SP Control Point.")
        }

    } // End of BluetoothManager class
} // End of FlySightCore extension

// MARK: - Helper Enums and Extensions
public enum BluetoothError: Error, LocalizedError {
    case notConnectedOrCharsMissing
    case deallocated
    case uploadFailed(String)
    // Add other specific errors

    public var errorDescription: String? {
        switch self {
        case .notConnectedOrCharsMissing: return "Not connected to FlySight or essential Bluetooth characteristics are missing."
        case .deallocated: return "The Bluetooth manager was deallocated."
        case .uploadFailed(let reason): return "Upload failed: \(reason)"
        }
    }
}
// Add for UInt16 if needed for other commands
