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


    public class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
        private var centralManager: CBCentralManager!
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
        @Published public var connectedPeripheralInfo: PeripheralInfo?
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
        private let frameLength: Int = 242
        private let txTimeoutInterval: TimeInterval = 0.2
        private var totalPacketsToSend: UInt32 = 0
        private var uploadContinuation: CheckedContinuation<Void, Error>?

        private var pingTimer: Timer?

        // Live GNSS
        @Published public var liveGNSSData: FlySightCore.LiveGNSSData?
        @Published public var currentGNSSMask: UInt8 = GNSSLiveMaskBits.timeOfWeek | GNSSLiveMaskBits.position | GNSSLiveMaskBits.velocity
        @Published public var gnssMaskUpdateStatus: GNSSMaskUpdateStatus = .idle
        private var lastAttemptedGNSSMask: UInt8?

        // MARK: - Internal State
        public enum ScanMode { case none, knownDevices, pairingMode }
        public private(set) var currentScanMode: ScanMode = .none
        private var disappearanceTimers: [UUID: Timer] = [:]
        private var peripheralBeingConnected: CBPeripheral?

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
            case idle
            case scanningKnown
            case scanningPairing
            case connecting(to: PeripheralInfo)
            case discoveringServices(for: CBPeripheral)
            case discoveringCharacteristics(for: CBPeripheral)
            case connected(to: PeripheralInfo)
            case disconnecting(from: PeripheralInfo)

            public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
                switch (lhs, rhs) {
                case (.idle, .idle):
                    return true
                case (.scanningKnown, .scanningKnown):
                    return true
                case (.scanningPairing, .scanningPairing):
                    return true
                case (.connecting(let lInfo), .connecting(let rInfo)):
                    return lInfo == rInfo
                case (.discoveringServices(let lPeripheral), .discoveringServices(let rPeripheral)):
                    return lPeripheral.identifier == rPeripheral.identifier
                case (.discoveringCharacteristics(let lPeripheral), .discoveringCharacteristics(let rPeripheral)):
                    return lPeripheral.identifier == rPeripheral.identifier
                case (.connected(let lInfo), .connected(let rInfo)):
                    return lInfo == rInfo
                case (.disconnecting(let lInfo), .disconnecting(let rInfo)):
                    return lInfo == rInfo
                default:
                    return false
                }
            }
        }

        // MARK: - Initialization
        public override init() {
            super.init()
            self.centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .userInitiated))
            print("BluetoothManager initialized.")
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
                self.discoveredPairingPeripherals = []
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

            if case .connecting(let currentTarget) = connectionState, currentTarget.id == peripheralInfo.id {
                print("Already attempting to connect to \(peripheralInfo.name).")
                return
            }

            if let currentlyConnected = connectedPeripheralInfo, currentlyConnected.id != peripheralInfo.id {
                print("Disconnecting from \(currentlyConnected.name) to connect to \(peripheralInfo.name).")
                disconnect(from: currentlyConnected)
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
                  case .idle = connectionState else {
                return
            }

            if let lastID = lastConnectedPeripheralID {
                print("Attempting to auto-connect to last peripheral: \(lastID)")
                if let peripheral = centralManager.retrievePeripherals(withIdentifiers: [lastID]).first {
                    let pInfo = PeripheralInfo(peripheral: peripheral, rssi: -100, name: peripheral.name ?? "FlySight", isConnected: false, isPairingMode: false, isBonded: self.bondedDeviceIDs.contains(peripheral.identifier))
                    self.updateKnownPeripheralsList(with: pInfo)
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
            DispatchQueue.main.async {
                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let rootViewController = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                    print("Could not find root view controller to present alert.")
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
            DispatchQueue.main.async {
                switch central.state {
                case .poweredOn:
                    print("Bluetooth Powered On.")
                    self.loadKnownPeripheralsFromUserDefaults()
                    if self.connectionState == .idle {
                         self.attemptAutoConnect()
                    } else if self.currentScanMode == .knownDevices {
                        self.startScanningForKnownDevices()
                    } else if self.currentScanMode == .pairingMode {
                        self.startScanningForPairingModeDevices()
                    }
                case .poweredOff:
                    print("Bluetooth Powered Off.")
                    self.resetPeripheralState()
                    self.knownPeripherals.indices.forEach { self.knownPeripherals[$0].isConnected = false }
                    self.discoveredPairingPeripherals = []
                    self.connectionState = .idle
                    let alert = UIAlertController(title: "Bluetooth Off", message: "Please turn on Bluetooth to use FlySight features.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
                    self.presentAlert(alert)
                case .resetting:
                    print("Bluetooth is resetting.")
                case .unauthorized:
                    print("Bluetooth use unauthorized.")
                    self.connectionState = .idle
                     let alert = UIAlertController(title: "Bluetooth Unauthorized", message: "This app needs Bluetooth permission. Please enable it in Settings.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Settings", style: .default) { _ in
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    })
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
                    self.presentAlert(alert)
                case .unsupported:
                    print("Bluetooth is unsupported on this device.")
                    self.connectionState = .idle
                    let alert = UIAlertController(title: "Bluetooth Unsupported", message: "This device does not support Bluetooth Low Energy.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
                    self.presentAlert(alert)
                default:
                    print("Bluetooth state unknown or new: \(central.state)")
                }
            }
        }

        public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
            var isRelevantByName = false
            if let name = peripheral.name, name.contains("FlySight") {
                isRelevantByName = true
            }

            var isRelevantByManufData = false
            var isPairingModeAdvertised = false // Default to false

            if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
                if manufacturerData.count >= 2 { // Manufacturer ID is 2 bytes
                    let manufID = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8) // LSB first
                    if manufID == 0x09DB { // Bionic Avionics
                        isRelevantByManufData = true
                        if manufacturerData.count >= 3 { // Status byte is present (3rd byte)
                            isPairingModeAdvertised = (manufacturerData[2] & 0x01) != 0
                        }
                    }
                }
            }

            // If not relevant by name AND not relevant by manufacturer data, then ignore.
            guard isRelevantByName || isRelevantByManufData else {
                return
            }

            let isBondedToApp = bondedDeviceIDs.contains(peripheral.identifier)

            // Apply scan mode specific filtering
            switch currentScanMode {
            case .knownDevices:
                // For known devices scan, we only care about devices bonded to our app.
                guard isBondedToApp else {
                    return
                }
            case .pairingMode:
                // For pairing mode scan, the device must be advertising pairing mode.
                guard isPairingModeAdvertised else {
                    return
                }
            case .none:
                // If not actively scanning for a specific purpose (known or pairing),
                // we typically don't add/update peripherals from general discovery.
                // However, if a device is already known and connected, its RSSI might be updated by other means (peripheral.readRSSI).
                // For general discovery processing, if scan mode is .none, we'll ignore it here.
                return
            }

            let discoveredInfo = PeripheralInfo(
                peripheral: peripheral,
                rssi: RSSI.intValue,
                name: peripheral.name ?? "FlySight",
                isConnected: false,
                isPairingMode: isPairingModeAdvertised,
                isBonded: isBondedToApp
            )

            DispatchQueue.main.async {
                // The switch here is now simpler due to earlier guards.
                switch self.currentScanMode {
                case .knownDevices:
                    // At this point, discoveredInfo.isBonded is true.
                    self.updateKnownPeripheralsList(with: discoveredInfo)
                case .pairingMode:
                    // At this point, discoveredInfo.isPairingMode is true.
                    self.updateDiscoveredPairingPeripheralsList(with: discoveredInfo)
                case .none:
                    // Should not be reached if the earlier return for .none is active,
                    // but if it is, do nothing.
                    break
                }
            }
        }

        private func updateKnownPeripheralsList(with discoveredInfo: PeripheralInfo) {
            if let index = knownPeripherals.firstIndex(where: { $0.id == discoveredInfo.id }) {
                knownPeripherals[index].rssi = discoveredInfo.rssi
                knownPeripherals[index].name = discoveredInfo.name
                knownPeripherals[index].peripheral = discoveredInfo.peripheral
                knownPeripherals[index].isBonded = discoveredInfo.isBonded
            } else if discoveredInfo.isBonded {
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

            let connectingTargetInfo: PeripheralInfo?
            if case .connecting(let target) = connectionState, target.id == peripheral.identifier {
                connectingTargetInfo = target
            } else {
                connectingTargetInfo = knownPeripherals.first(where: {$0.id == peripheral.identifier}) ??
                                       discoveredPairingPeripherals.first(where: {$0.id == peripheral.identifier})
            }

            let pInfo = connectingTargetInfo ?? PeripheralInfo(peripheral: peripheral, rssi: -100, name: peripheral.name ?? "FlySight", isConnected: true, isPairingMode: false, isBonded: bondedDeviceIDs.contains(peripheral.identifier))

            DispatchQueue.main.async {
                self.peripheralBeingConnected = peripheral
                self.connectionState = .discoveringServices(for: peripheral)

                if self.connectedPeripheralInfo == nil || self.connectedPeripheralInfo?.id == peripheral.identifier {
                    self.connectedPeripheralInfo = pInfo
                }

                if let index = self.knownPeripherals.firstIndex(where: { $0.id == peripheral.identifier }) {
                    self.knownPeripherals[index].isConnected = true
                    self.knownPeripherals[index].peripheral = peripheral
                    self.knownPeripherals[index].isBonded = pInfo.isBonded
                } else if pInfo.isBonded {
                    var newKnown = pInfo
                    newKnown.isConnected = true
                    self.knownPeripherals.append(newKnown)
                }
                self.sortKnownPeripherals()
            }

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
                if case .connecting(let targetInfo) = self.connectionState, targetInfo.id == peripheral.identifier {
                     self.connectionState = .idle
                }

                if self.connectedPeripheralInfo?.id == peripheral.identifier {
                    self.connectedPeripheralInfo = nil
                }
                if let index = self.knownPeripherals.firstIndex(where: { $0.id == peripheral.identifier }) {
                    self.knownPeripherals[index].isConnected = false
                }
                self.sortKnownPeripherals()

                if self.lastConnectedPeripheralID == peripheral.identifier {
                    self.startScanningForKnownDevices()
                }
            }
        }

        public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
            let peripheralName = peripheral.name ?? peripheral.identifier.uuidString
            print("Disconnected from \(peripheralName). Reason: \(error?.localizedDescription ?? "None")")

            DispatchQueue.main.async {
                let previouslyConnectedInfo = self.connectedPeripheralInfo
                self.resetPeripheralState()

                if let pInfo = previouslyConnectedInfo {
                    if let index = self.knownPeripherals.firstIndex(where: { $0.id == pInfo.id }) {
                        self.knownPeripherals[index].isConnected = false
                    }
                }
                self.connectionState = .idle
                self.sortKnownPeripherals()

                if error != nil {
                    print("Unexpected disconnection, attempting to restore or scan.")
                    self.attemptAutoConnect()
                }
            }
        }

        // MARK: - CBPeripheralDelegate
        public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
            guard error == nil else {
                print("Error discovering services on \(peripheral.identifier): \(error!.localizedDescription)")
                if peripheral.identifier == peripheralBeingConnected?.identifier || peripheral.identifier == connectedPeripheralInfo?.id {
                    disconnect(from: PeripheralInfo(peripheral: peripheral, rssi: 0, name: peripheral.name ?? "Unknown", isConnected: false, isPairingMode: false, isBonded: bondedDeviceIDs.contains(peripheral.identifier)))
                }
                return
            }

            guard let services = peripheral.services, !services.isEmpty else {
                print("No services found for \(peripheral.identifier). This is unexpected.")
                return
            }

            DispatchQueue.main.async {
                if case .discoveringServices(let p) = self.connectionState, p.identifier == peripheral.identifier {
                    self.connectionState = .discoveringCharacteristics(for: peripheral)
                }
            }

            for service in services {
                print("Discovered service: \(service.uuid.uuidString) on \(peripheral.identifier)")
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }

        public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
            guard error == nil else {
                print("Error discovering characteristics for service \(service.uuid) on \(peripheral.identifier): \(error!.localizedDescription)")
                return
            }
            guard let characteristics = service.characteristics else { return }

            for characteristic in characteristics {
                print("Discovered characteristic: \(characteristic.uuid.uuidString) in service: \(service.uuid.uuidString)")
                switch characteristic.uuid {
                case FlySightCore.FT_PACKET_IN_UUID:
                    ftPacketInCharacteristic = characteristic
                    if !bondedDeviceIDs.contains(peripheral.identifier) {
                        print("Device \(peripheral.identifier) not bonded. Reading FT_Packet_In to trigger pairing...")
                        peripheral.readValue(for: characteristic)
                    } else {
                        print("FT_Packet_In found, device already bonded.")
                    }
                case FlySightCore.FT_PACKET_OUT_UUID:
                    ftPacketOutCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case FlySightCore.SD_GNSS_MEASUREMENT_UUID:
                    sdGNSSMeasurementCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case FlySightCore.SD_CONTROL_POINT_UUID:
                    sdControlPointCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case FlySightCore.SP_CONTROL_POINT_UUID:
                    spControlPointCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case FlySightCore.SP_RESULT_UUID:
                    spResultCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case FlySightCore.DS_MODE_UUID:
                    dsModeCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case FlySightCore.DS_CONTROL_POINT_UUID:
                    dsControlPointCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case FlySightCore.FIRMWARE_REVISION_STRING_UUID:
                    firmwareRevisionCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                default:
                    break
                }
            }

            if ftPacketInCharacteristic != nil && ftPacketOutCharacteristic != nil {
                if bondedDeviceIDs.contains(peripheral.identifier) {
                    if case .discoveringCharacteristics = connectionState {
                         handlePostBondingSetup(for: peripheral)
                    }
                }
            }
        }

        private func handlePostBondingSetup(for peripheral: CBPeripheral) {
            // Corrected Guard: Ensure connectedPeripheralInfo is valid and matches the peripheral.
            guard let currentTargetInfo = connectedPeripheralInfo, currentTargetInfo.id == peripheral.identifier else {
                 print("Error: handlePostBondingSetup called for peripheral \(peripheral.identifier.uuidString) but current connected target is \(connectedPeripheralInfo?.id.uuidString ?? "nil"). Aborting setup for this peripheral.")
                 return // Always exit if the guard condition fails.
            }

            print("Device \(peripheral.identifier) is bonded and essential characteristics found. Finalizing setup for \(currentTargetInfo.name).")
            addBondedDeviceID(peripheral.identifier)
            self.lastConnectedPeripheralID = peripheral.identifier

            DispatchQueue.main.async {
                var finalInfo = self.connectedPeripheralInfo! // Safe due to the guard
                finalInfo.isBonded = true
                finalInfo.isConnected = true
                finalInfo.isPairingMode = false
                finalInfo.peripheral = peripheral

                self.connectedPeripheralInfo = finalInfo

                if let index = self.knownPeripherals.firstIndex(where: { $0.id == peripheral.identifier }) {
                    self.knownPeripherals[index] = finalInfo
                } else {
                    self.knownPeripherals.append(finalInfo)
                    print("Added new bonded peripheral \(finalInfo.name) to known list during post-bonding setup.")
                }
                self.discoveredPairingPeripherals.removeAll { $0.id == peripheral.identifier }

                self.sortKnownPeripherals()
                self.connectionState = .connected(to: finalInfo)

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
            if characteristic.uuid == FlySightCore.FT_PACKET_IN_UUID {
                if error == nil {
                    print("Successfully read FT_Packet_In.")

                    // Determine if we are in the process of initial connection and discovery for *this* peripheral.
                    var isInitialSetupPhaseForThisPeripheral = false
                    if case .discoveringCharacteristics(let p) = connectionState, p.identifier == peripheral.identifier {
                        isInitialSetupPhaseForThisPeripheral = true
                    } else if case .connecting(let targetInfo) = connectionState, targetInfo.id == peripheral.identifier {
                        // This might occur if characteristics are discovered very quickly after connection.
                        isInitialSetupPhaseForThisPeripheral = true
                    }

                    if isInitialSetupPhaseForThisPeripheral {
                        // This successful read was likely the one that triggered OS pairing, or confirms it just completed.
                        // It's time to finalize the app-level setup.
                        print("FT_Packet_In read successful during discovery/connection phase for \(peripheral.identifier). Proceeding to post-bonding setup.")
                        handlePostBondingSetup(for: peripheral)
                    } else if bondedDeviceIDs.contains(peripheral.identifier) {
                        // Device is already bonded and not in the initial setup phase.
                        // This read might be for other purposes or a confirmation on a reconnect.
                        print("FT_Packet_In read successful for an already bonded device outside initial setup.")
                        // If already fully connected, ensure critical characteristics are still notifying.
                        if case .connected = connectionState {
                            if let ftOut = ftPacketOutCharacteristic, !ftOut.isNotifying {
                                peripheral.setNotifyValue(true, for: ftOut)
                                print("Ensured FT_Packet_Out is notifying for already connected device.")
                            }
                            // Potentially add other checks here if needed for a fully connected device.
                        } else {
                            // It's bonded, but we are not in .connected state.
                            // This could be a reconnect scenario where we haven't reached .connected yet.
                            // Try calling handlePostBondingSetup to ensure full setup.
                            print("FT_Packet_In read for bonded device, but not in .connected state. Attempting post-bonding setup.")
                            handlePostBondingSetup(for: peripheral)
                        }
                    } else {
                        // Read was successful, BUT we are not in an initial setup phase for this peripheral,
                        // AND the device is NOT in our bondedDeviceIDs list.
                        // This is an unusual state. It implies a successful secure read happened without the app
                        // being in a clear state to recognize it as the completion of pairing.
                        // As a best effort, attempt to finalize setup.
                        print("FT_Packet_In read successful, but in an unexpected state (not initial setup, not yet in bondedDeviceIDs). Attempting post-bonding setup as a fallback.")
                        handlePostBondingSetup(for: peripheral)
                    }
                } else {
                    print("Error reading FT_Packet_In (pairing trigger): \(error!.localizedDescription)")
                    if let bleErrorDetails = error!.asBLEError, (bleErrorDetails.isInsufficientAuthentication || bleErrorDetails.isInsufficientEncryption) {
                        print("Pairing process likely initiated by OS due to insufficient authentication/encryption on FT_Packet_In read.")
                    } else {
                        disconnect(from: PeripheralInfo(peripheral: peripheral, rssi: 0, name: peripheral.name ?? "Unknown", isConnected: false, isPairingMode: false, isBonded: bondedDeviceIDs.contains(peripheral.identifier)))
                    }
                    return
                }
            }

            if characteristic.uuid == FlySightCore.FIRMWARE_REVISION_STRING_UUID, error == nil, let data = characteristic.value {
                if let fwVersion = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.flysightFirmwareVersion = fwVersion
                        print("FlySight Firmware Version: \(fwVersion)")
                    }
                }
            }

            guard error == nil else {
                print("Error updating value for \(characteristic.uuid): \(error!.localizedDescription)")
                DispatchQueue.main.async {
                    if characteristic.uuid == FlySightCore.SD_CONTROL_POINT_UUID {
                        self.gnssMaskUpdateStatus = .failure(" Characteristic update error: \(error!.localizedDescription)")
                    }
                    if characteristic.uuid == FlySightCore.FT_PACKET_OUT_UUID {
                        self.isAwaitingDirectoryResponse = false
                    }
                }
                if let handler = notificationHandlers[characteristic.uuid] {
                    handler(peripheral, characteristic, error)
                }
                return
            }

            guard let data = characteristic.value else {
                print("No data in characteristic update for \(characteristic.uuid)")
                return
            }

            var handledBySpecificLogic = false
            if characteristic.uuid == FlySightCore.FT_PACKET_OUT_UUID {
                let opcode = data[0]
                switch opcode {
                case 0x11:
                    DispatchQueue.main.async {
                        if let entry = self.parseDirectoryEntry(from: data) {
                            if entry.isEmptyMarker {
                                print("End of directory listing received (marker).")
                                self.isAwaitingDirectoryResponse = false
                            } else {
                                self.directoryEntries.append(entry)
                                self.sortDirectoryEntries()
                            }
                        } else {
                            print("Parsed directory entry was nil for opcode 0x11, but not an end marker.")
                        }
                    }
                    handledBySpecificLogic = true
                case 0xF0:
                    let originalCommand = data.count > 1 ? data[1] : 0xFF
                    print("Received NAK for command 0x\(String(format: "%02X", originalCommand))")
                    DispatchQueue.main.async { self.isAwaitingDirectoryResponse = false }
                     if originalCommand == 0x03 {
                        self.uploadContinuation?.resume(throwing: NSError(domain: "FlySightCore.Upload", code: Int(originalCommand), userInfo: [NSLocalizedDescriptionKey: "Failed to open remote file for writing (NAK)."]))
                        self.uploadContinuation = nil
                        self.isUploading = false
                    }
                    handledBySpecificLogic = true
                case 0xF1:
                    let originalCommand = data.count > 1 ? data[1] : 0xFF
                    print("Received ACK for command 0x\(String(format: "%02X", originalCommand))")
                    if originalCommand == 0x05 {
                        DispatchQueue.main.async { self.isAwaitingDirectoryResponse = true }
                    } else if originalCommand == 0x03 {
                    } else if originalCommand == 0x02 {
                    }
                    handledBySpecificLogic = true
                default:
                    break
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
                handledBySpecificLogic = true
            }

            if let handler = notificationHandlers[characteristic.uuid] {
                handler(peripheral, characteristic, error)
            } else if !handledBySpecificLogic {
                // print("No specific logic or registered handler for characteristic \(characteristic.uuid). Data: \(data.hexEncodedString())")
            }
        }

        public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
            if let error = error {
                print("Write error for characteristic \(characteristic.uuid): \(error.localizedDescription)")
                if characteristic.uuid == FlySightCore.FT_PACKET_IN_UUID && isUploading {
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
        }

        public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
            if let error = error {
                print("Error changing notification state for \(characteristic.uuid): \(error.localizedDescription)")
                if characteristic.uuid == FlySightCore.FT_PACKET_OUT_UUID && characteristic.isNotifying {
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
        var bondedDeviceIDsKey: String { "bondedDeviceIDs_v3" }

        var bondedDeviceIDs: Set<UUID> {
            get {
                guard let data = UserDefaults.standard.data(forKey: bondedDeviceIDsKey) else { return [] }
                do {
                    return try JSONDecoder().decode(Set<UUID>.self, from: data)
                } catch {
                    print("Failed to decode bondedDeviceIDs: \(error)")
                    UserDefaults.standard.removeObject(forKey: bondedDeviceIDsKey)
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

        public func loadKnownPeripheralsFromUserDefaults() {
            let bondedIDs = self.bondedDeviceIDs
            var currentKnown = self.knownPeripherals
            var updatedKnownPeripherals: [PeripheralInfo] = []
            var madeChanges = false

            for id in bondedIDs {
                if let existingInfo = currentKnown.first(where: { $0.id == id }) {
                    var infoToKeep = existingInfo
                    infoToKeep.isBonded = true
                    updatedKnownPeripherals.append(infoToKeep)
                } else {
                    if let peripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first {
                        updatedKnownPeripherals.append(PeripheralInfo(peripheral: peripheral, rssi: -100, name: peripheral.name ?? "FlySight", isConnected: false, isPairingMode: false, isBonded: true))
                        madeChanges = true
                    } else {
                        print("Bonded device ID \(id) found in UserDefaults, but CBPeripheral not retrieved. Will appear if scanned.")
                    }
                }
            }

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
            disappearanceTimers[peripheralInfo.id] = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
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
                }
            }
        }

        private func startPingTimer() {
            stopPingTimer()
            DispatchQueue.main.async {
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
            var command = Data([0x05])
            command.append(pathString.data(using: .utf8) ?? Data())
            command.append(0x00)

            peripheral.writeValue(command, for: char, type: .withoutResponse)
        }

        private func parseDirectoryEntry(from characteristicValue: Data) -> DirectoryEntry? {
            guard characteristicValue.count >= 3, characteristicValue[0] == 0x11 else {
                return nil
            }

            let payload = characteristicValue.subdata(in: 2..<characteristicValue.count)

            guard payload.count >= 22 else {
                print("parseDirectoryEntry: Payload too short. Expected 22 bytes, got \(payload.count)")
                return nil
            }

            let size: UInt32 = payload.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }
            let fdate: UInt16 = payload.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self) }
            let ftime: UInt16 = payload.subdata(in: 6..<8).withUnsafeBytes { $0.load(as: UInt16.self) }
            let fattrib: UInt8 = payload.subdata(in: 8..<9).withUnsafeBytes { $0.load(as: UInt8.self) }

            let nameBytes = payload.subdata(in: 9..<(9+13))

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

            var attribText = ""
            attribText += (fattrib & 0x10) != 0 ? "d" : "-"
            attribText += (fattrib & 0x20) != 0 ? "a" : "-"
            attribText += (fattrib & 0x01) != 0 ? "r" : "-"
            attribText += (fattrib & 0x02) != 0 ? "h" : "-"
            attribText += (fattrib & 0x04) != 0 ? "s" : "-"

            return DirectoryEntry(size: size, date: date, attributes: attribText, name: name, isEmptyMarker: false)
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
        public func downloadFile(named filePath: String, knownSize: UInt32, completion: @escaping (Result<Data, Error>) -> Void) {
            guard let peripheral = connectedPeripheralInfo?.peripheral,
                  let rxChar = ftPacketInCharacteristic,
                  let txChar = ftPacketOutCharacteristic
            else {
                completion(.failure(BluetoothError.notConnectedOrCharsMissing))
                return
            }

            var fileData = Data()
            var expectedPacketNum: UInt8 = 0
            let transferCompleteSubject = PassthroughSubject<Void, Error>()

            DispatchQueue.main.async {
                self.downloadProgress = 0.0
                self.currentFileSize = knownSize
            }

            notificationHandlers[txChar.uuid] = { [weak self] (p, char, err) in
                guard let self = self else { return }

                if let error = err {
                    transferCompleteSubject.send(completion: .failure(error))
                    return
                }
                guard let data = char.value, data.count >= 2, data[0] == 0x10 else {
                    return
                }

                let receivedPacketNum = data[1]

                if receivedPacketNum == expectedPacketNum {
                    let actualData = data.count > 2 ? data.subdata(in: 2..<data.count) : Data()

                    if actualData.isEmpty && data.count == 2 {
                        let ackPacket = Data([0x12, receivedPacketNum])
                        p.writeValue(ackPacket, for: rxChar, type: .withoutResponse)
                        transferCompleteSubject.send(completion: .finished)
                    } else {
                        fileData.append(actualData)
                        expectedPacketNum = expectedPacketNum &+ 1

                        let ackPacket = Data([0x12, receivedPacketNum])
                        p.writeValue(ackPacket, for: rxChar, type: .withoutResponse)

                        DispatchQueue.main.async {
                            if self.currentFileSize > 0 {
                                self.downloadProgress = Float(fileData.count) / Float(self.currentFileSize)
                            }
                        }
                    }
                } else {
                    print("Download: Out-of-order packet. Expected \(expectedPacketNum), got \(receivedPacketNum). Discarding.")
                }
            }

            let fullPath = (currentPath + [filePath]).joined(separator: "/")
            print("Requesting download for: \(fullPath)")
            var command = Data([0x02])
            command.append(UInt32(0).littleEndianData)
            command.append(UInt32(0).littleEndianData)
            command.append(fullPath.data(using: .utf8) ?? Data())
            command.append(0x00)

            peripheral.writeValue(command, for: rxChar, type: .withoutResponse)

            let cancellable = transferCompleteSubject.sink(receiveCompletion: { [weak self] resultCompletion in
                self?.notificationHandlers[txChar.uuid] = nil
                DispatchQueue.main.async { self?.downloadProgress = 0.0 }
                switch resultCompletion {
                case .failure(let error): completion(.failure(error))
                case .finished: completion(.success(fileData))
                }
            }, receiveValue: { _ in })
            cancellable.store(in: &cancellables)
        }

        public func cancelDownload() {
            guard let peripheral = connectedPeripheralInfo?.peripheral, let char = ftPacketInCharacteristic else { return }
            let cancelCommand = Data([0xFF])
            peripheral.writeValue(cancelCommand, for: char, type: .withoutResponse)
            DispatchQueue.main.async {
                self.downloadProgress = 0.0
            }
            print("Sent Cancel Transfer command.")
        }


        public func uploadFile(fileData: Data, remotePath: String) async throws {
             guard let peripheral = connectedPeripheralInfo?.peripheral,
                  let rxChar = ftPacketInCharacteristic,
                  let txChar = ftPacketOutCharacteristic
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
                self.remotePathToUpload = remotePath
                self.nextPacketNum = 0
                self.nextAckNum = 0
                self.lastPacketNum = nil
                self.totalPacketsToSend = UInt32(ceil(Double(fileData.count) / Double(self.frameLength)))
                if fileData.isEmpty { self.totalPacketsToSend = 1 }

                self.uploadContinuation = continuation

                DispatchQueue.main.async {
                    self.uploadProgress = 0.0
                }

                self.notificationHandlers[txChar.uuid] = { [weak self] (p, char, err) in
                    guard let self = self, self.isUploading else { return }

                    if let error = err {
                        self.handleUploadCompletion(result: .failure(error))
                        return
                    }
                    guard let data = char.value, data.count == 2, data[0] == 0x12 else {
                        return
                    }

                    let ackedPacketNum = Int(data[1])

                    if ackedPacketNum == (self.nextAckNum % 256) {
                        self.nextAckNum += 1
                        DispatchQueue.main.async {
                            if self.totalPacketsToSend > 0 {
                                self.uploadProgress = Float(self.nextAckNum) / Float(self.totalPacketsToSend)
                            }
                        }
                        if let lastSent = self.lastPacketNum, self.nextAckNum >= lastSent {
                            self.handleUploadCompletion(result: .success(()))
                        } else {
                            Task { await self.sendUploadDataPackets(peripheral: p, rxChar: rxChar) }
                        }
                    } else {
                        print("Upload: Received ACK for \(ackedPacketNum), expected for \(self.nextAckNum % 256).")
                    }
                }

                var openCommand = Data([0x03])
                openCommand.append(remotePath.data(using: .utf8) ?? Data())
                openCommand.append(0x00)

                peripheral.writeValue(openCommand, for: rxChar, type: .withoutResponse)
                print("Upload: Sent OpenFile command for \(remotePath).")

                Task {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if self.isUploading {
                        await self.sendUploadDataPackets(peripheral: peripheral, rxChar: rxChar)
                    }
                }
            }
        }

        private func sendUploadDataPackets(peripheral: CBPeripheral, rxChar: CBCharacteristic) async {
            guard isUploading, let dataToSend = fileDataToUpload else { return }

            while nextPacketNum < (nextAckNum + windowLength) {
                if let lastSentPacket = lastPacketNum, nextPacketNum >= lastSentPacket {
                    break
                }

                let isFinalPacket = (nextPacketNum * frameLength) >= dataToSend.count

                let packetData: Data
                var dataChunk = Data()

                if !isFinalPacket {
                    let startIndex = nextPacketNum * frameLength
                    let endIndex = min(startIndex + frameLength, dataToSend.count)
                    dataChunk = dataToSend.subdata(in: startIndex..<endIndex)
                    packetData = Data([0x10, UInt8(nextPacketNum % 256)]) + dataChunk
                } else {
                    packetData = Data([0x10, UInt8(nextPacketNum % 256)])
                    print("Upload: Preparing final empty packet #\(nextPacketNum % 256)")
                    lastPacketNum = nextPacketNum + 1
                }

                peripheral.writeValue(packetData, for: rxChar, type: .withoutResponse)
                nextPacketNum += 1

                if isFinalPacket { break }

                 try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }

        private func handleUploadCompletion(result: Result<Void, Error>) {
            DispatchQueue.main.async {
                self.uploadContinuation?.resume(with: result)
                self.uploadContinuation = nil
                self.isUploading = false
                self.fileDataToUpload = nil
                self.remotePathToUpload = nil
                self.uploadProgress = (try? result.get()) != nil ? 1.0 : 0.0

                print("Upload completed with result: \(result)")
            }
        }

        public func cancelUpload() {
            guard isUploading else { return }
            print("Cancelling upload...")

            if let peripheral = connectedPeripheralInfo?.peripheral, let char = ftPacketInCharacteristic {
                let cancelCommand = Data([0xFF])
                peripheral.writeValue(cancelCommand, for: char, type: .withoutResponse)
                print("Sent Cancel Transfer (0xFF) command to FlySight.")
            }

            DispatchQueue.main.async {
                let error = NSError(domain: "FlySightCore.Upload", code: -999, userInfo: [NSLocalizedDescriptionKey: "Upload cancelled by user."])
                self.uploadContinuation?.resume(throwing: error)
                self.uploadContinuation = nil

                self.isUploading = false
                self.fileDataToUpload = nil
                self.remotePathToUpload = nil
                self.uploadProgress = 0.0
            }
        }


        // MARK: - Ping
        private func sendPing() {
            guard let peripheral = connectedPeripheralInfo?.peripheral, let char = ftPacketInCharacteristic else {
                print("Cannot send ping: Not connected or FT_Packet_In characteristic missing.")
                return
            }
            let pingCommand = Data([0xFE])
            peripheral.writeValue(pingCommand, for: char, type: .withoutResponse)
        }

        // MARK: - GNSS Data Mask Operations
        public func fetchGNSSMask() {
            guard let peripheral = connectedPeripheralInfo?.peripheral, let controlChar = sdControlPointCharacteristic else {
                print("Cannot fetch GNSS mask: Not connected or SD Control Point characteristic.")
                DispatchQueue.main.async { self.gnssMaskUpdateStatus = .failure("Characteristic not available.") }
                return
            }
            let command = Data([SDControlOpcodes.getMask])
            print("Fetching GNSS Mask...")
            DispatchQueue.main.async { self.gnssMaskUpdateStatus = .pending }
            peripheral.writeValue(command, for: controlChar, type: .withResponse)
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
            peripheral.writeValue(command, for: controlChar, type: .withResponse)
        }

        // MARK: - Data Parsers & Responders
        public func processStartResult(data: Data) { // From SP_Result UUID (00000004-8e22-4541-9d4c-21edae82ed19)
            guard data.count == 9 else {
                print("SP_Result: Invalid data length. Expected 9, got \(data.count). Data: \(data.hexEncodedString())")
                return
            }

            // Data structure: Year(u16), Mon(u8), Day(u8), Hour(u8), Min(u8), Sec(u8), Hund(u8), TZ(u8)
            // All fields are Little Endian if multi-byte. Year is u16.
            // FlySight documentation for SP_RESULT_UUID implies all times are UTC (TZ field is 0 or unused).

            let year: UInt16 = data.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) }
            let month: UInt8 = data[2]
            let day: UInt8 = data[3]
            let hour: UInt8 = data[4]
            let minute: UInt8 = data[5]
            let second: UInt8 = data[6]
            let hundredths: UInt8 = data[7]
            // let timezoneOffset: Int8 = data.subdata(in: 8..<9).withUnsafeBytes { $0.load(as: Int8.self) } // Currently unused by FlySight firmware (0)

            var dateComponents = DateComponents()
            dateComponents.year = Int(year)
            dateComponents.month = Int(month)
            dateComponents.day = Int(day)
            dateComponents.hour = Int(hour)
            dateComponents.minute = Int(minute)
            dateComponents.second = Int(second)
            dateComponents.nanosecond = Int(hundredths) * 10_000_000 // Convert hundredths to nanoseconds
            dateComponents.timeZone = TimeZone(secondsFromGMT: 0)   // Explicitly UTC

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)! // Ensure calendar also uses UTC

            if let date = calendar.date(from: dateComponents) {
                DispatchQueue.main.async {
                    self.startResultDate = date
                    self.startPistolState = .idle // Result received, so countdown is over.
                    print("SP_Result: Parsed start time (UTC): \(date)")
                }
            } else {
                print("SP_Result: Failed to construct date from components: \(dateComponents)")
            }
        }

        private func parseLiveGNSSData(from data: Data) { // From SD_GNSS_MEASUREMENT_UUID (00000000-8e22-4541-9d4c-21edae82ed19)
            guard !data.isEmpty else {
                print("Live GNSS: Received empty data packet.")
                return
            }

            let mask = data[0]
            var offset = 1 // Start reading data after the mask byte

            var tow: UInt32?
            // var week: UInt16? // Week number not currently sent by firmware as per docs/observation
            var lon, lat, hMSL: Int32?
            var velN, velE, velD: Int32?
            var hAcc, vAcc, sAcc: UInt32?
            var numSV: UInt8?

            // Time of Week (ms)
            if (mask & GNSSLiveMaskBits.timeOfWeek) != 0 && data.count >= offset + 4 {
                tow = data.subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.load(as: UInt32.self) }
                offset += 4
            }

            // Week Number - Placeholder, FlySight firmware doesn't seem to send this in the live packet.
            // if (mask & GNSSLiveMaskBits.weekNumber) != 0 && data.count >= offset + 2 {
            //     week = data.subdata(in: offset..<(offset+2)).withUnsafeBytes { $0.load(as: UInt16.self) }
            //     offset += 2
            // }

            // Position (Longitude, Latitude, Height MSL)
            if (mask & GNSSLiveMaskBits.position) != 0 && data.count >= offset + 12 {
                lon = data.subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.load(as: Int32.self) }
                offset += 4
                lat = data.subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.load(as: Int32.self) }
                offset += 4
                hMSL = data.subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.load(as: Int32.self) }
                offset += 4
            }

            // Velocity (North, East, Down)
            if (mask & GNSSLiveMaskBits.velocity) != 0 && data.count >= offset + 12 {
                velN = data.subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.load(as: Int32.self) }
                offset += 4
                velE = data.subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.load(as: Int32.self) }
                offset += 4
                velD = data.subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.load(as: Int32.self) }
                offset += 4
            }

            // Accuracy (Horizontal, Vertical, Speed)
            if (mask & GNSSLiveMaskBits.accuracy) != 0 && data.count >= offset + 12 {
                hAcc = data.subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.load(as: UInt32.self) }
                offset += 4
                vAcc = data.subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.load(as: UInt32.self) }
                offset += 4
                sAcc = data.subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.load(as: UInt32.self) }
                offset += 4
            }

            // Number of Satellites in Solution
            if (mask & GNSSLiveMaskBits.numSV) != 0 && data.count >= offset + 1 {
                numSV = data[offset]
                offset += 1
            }

            // Create the LiveGNSSData struct and publish it
            let gnssData = LiveGNSSData(mask: mask,
                                        timeOfWeek: tow,
                                        longitude: lon,
                                        latitude: lat,
                                        heightMSL: hMSL,
                                        velocityNorth: velN,
                                        velocityEast: velE,
                                        velocityDown: velD,
                                        horizontalAccuracy: hAcc,
                                        verticalAccuracy: vAcc,
                                        speedAccuracy: sAcc,
                                        numSV: numSV)

            DispatchQueue.main.async {
                self.liveGNSSData = gnssData
            }
        }

        private func processSDControlPointResponse(from data: Data) { // From SD_CONTROL_POINT_UUID (00000006-8e22-4541-9d4c-21edae82ed19)
            guard data.count >= 3 else {
                print("SD Control Point Response: Data too short. \(data.hexEncodedString())")
                DispatchQueue.main.async {
                    if self.gnssMaskUpdateStatus == .pending {
                        self.gnssMaskUpdateStatus = .failure("Invalid response length.")
                    }
                }
                return
            }

            let responseID = data[0]
            let originalOpcode = data[1]
            let status = data[2]

            guard responseID == FlySightCore.CP_RESPONSE_ID else {
                print("SD Control Point Response: Incorrect response ID. Expected 0xF0, Got \(String(format: "%02X", responseID))")
                DispatchQueue.main.async {
                    if self.gnssMaskUpdateStatus == .pending {
                        self.gnssMaskUpdateStatus = .failure("Invalid response ID.")
                    }
                }
                return
            }

            DispatchQueue.main.async {
                if status == FlySightCore.CP_STATUS.success {
                    print("SD Control Point: Command 0x\(String(format: "%02X", originalOpcode)) successful.")
                    if originalOpcode == SDControlOpcodes.getMask {
                        if data.count >= 4 {
                            let newMask = data[3]
                            self.currentGNSSMask = newMask
                            print("SD Control Point: Successfully fetched GNSS Mask: \(String(format: "0x%02X", newMask))")
                            self.gnssMaskUpdateStatus = .idle
                        } else {
                            print("SD Control Point: GetMask response missing mask value.")
                            self.gnssMaskUpdateStatus = .failure("GetMask response incomplete.")
                        }
                    } else if originalOpcode == SDControlOpcodes.setMask {
                        if let attemptedMask = self.lastAttemptedGNSSMask {
                            self.currentGNSSMask = attemptedMask
                            print("SD Control Point: Successfully set GNSS Mask to: \(String(format: "0x%02X", attemptedMask))")
                        } else {
                            print("SD Control Point: SetMask successful, but lastAttemptedGNSSMask was nil. Fetching current mask to confirm.")
                            self.fetchGNSSMask()
                            return // Avoid setting to idle before fetch completes.
                        }
                        self.gnssMaskUpdateStatus = .idle
                    } else {
                        print("SD Control Point: Command 0x\(String(format: "%02X", originalOpcode)) successful (unhandled specific opcode).")
                        self.gnssMaskUpdateStatus = .idle
                    }
                } else {
                    let errorDescription = FlySightCore.CP_STATUS.string(for: status)
                    print("SD Control Point: Command 0x\(String(format: "%02X", originalOpcode)) failed. Status: 0x\(String(format: "%02X", status)) (\(errorDescription))")
                    self.gnssMaskUpdateStatus = .failure("Cmd 0x\(String(format: "%02X", originalOpcode)) fail: \(errorDescription)")
                }
                if originalOpcode == SDControlOpcodes.setMask {
                    self.lastAttemptedGNSSMask = nil
                }
            }
        }

        private func processSPControlPointResponse(from data: Data) { // From SP_CONTROL_POINT_UUID (00000003-8e22-4541-9d4c-21edae82ed19)
            guard data.count >= 3 else {
                print("SP Control Point Response: Data too short. \(data.hexEncodedString())")
                // Potentially update UI if a start/cancel was pending and failed due to bad response
                return
            }

            let responseID = data[0]
            let originalOpcode = data[1]
            let status = data[2]

            guard responseID == FlySightCore.CP_RESPONSE_ID else {
                print("SP Control Point Response: Incorrect response ID. Expected 0xF0, Got \(String(format: "%02X", responseID))")
                return
            }

            DispatchQueue.main.async {
                if status == FlySightCore.CP_STATUS.success {
                    print("SP Control Point: Command 0x\(String(format: "%02X", originalOpcode)) successful.")
                    if originalOpcode == SPControlOpcodes.startCountdown {
                        self.startPistolState = .counting
                    } else if originalOpcode == SPControlOpcodes.cancelCountdown {
                        self.startPistolState = .idle
                    }
                } else {
                    let errorDescription = FlySightCore.CP_STATUS.string(for: status)
                    print("SP Control Point: Command 0x\(String(format: "%02X", originalOpcode)) failed. Status: 0x\(String(format: "%02X", status)) (\(errorDescription))")
                    // If a command failed, typically revert to idle unless the device specifically says it's still busy/counting.
                    // For simplicity, if a start command fails, we remain idle. If a cancel fails, we might still be counting.
                    // However, the FlySight usually confirms state via the SP_Result or other means.
                    // For now, we don't change startPistolState on failure here, relying on other updates or SP_Result.
                }
            }
        }

        // MARK: - Start Pistol Commands
        public func sendStartCommand() {
            guard let peripheral = connectedPeripheralInfo?.peripheral, let spControlChar = spControlPointCharacteristic else {
                print("SP Control Point characteristic not found or not connected.")
                return
            }
            let startCommand = Data([SPControlOpcodes.startCountdown])
            peripheral.writeValue(startCommand, for: spControlChar, type: .withResponse)
            print("Sent Start command to SP Control Point.")
        }

        public func sendCancelCommand() {
            guard let peripheral = connectedPeripheralInfo?.peripheral, let spControlChar = spControlPointCharacteristic else {
                print("SP Control Point characteristic not found or not connected.")
                return
            }
            let cancelCommand = Data([SPControlOpcodes.cancelCountdown])
            peripheral.writeValue(cancelCommand, for: spControlChar, type: .withResponse)
            print("Sent Cancel command to SP Control Point.")
        }
    }
}

public enum BluetoothError: Error, LocalizedError {
    case notConnectedOrCharsMissing
    case deallocated
    case uploadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnectedOrCharsMissing: return "Not connected to FlySight or essential Bluetooth characteristics are missing."
        case .deallocated: return "The Bluetooth manager was deallocated."
        case .uploadFailed(let reason): return "Upload failed: \(reason)"
        }
    }
}
