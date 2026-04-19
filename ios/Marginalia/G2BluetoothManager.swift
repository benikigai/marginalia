import Foundation
import CoreBluetooth
import Combine

/// Manages BLE connection to Even Realities G2 glasses.
/// Ported from EvenDemoApp's BluetoothManager.swift (Flutter bridge removed).
@MainActor
class G2BluetoothManager: NSObject, ObservableObject {
    // MARK: - Published State

    @Published var connectionState: ConnectionState = .disconnected
    @Published var discoveredPairs: [String: GlassesPair] = [:]  // keyed by channel number
    @Published var lensText: String = ""

    enum ConnectionState: String {
        case disconnected = "Disconnected"
        case scanning = "Scanning..."
        case found = "Found glasses"
        case connecting = "Connecting..."
        case connected = "Connected"
        case error = "Error"
    }

    struct GlassesPair {
        var left: CBPeripheral?
        var right: CBPeripheral?
        var channelNumber: String
        var leftName: String?
        var rightName: String?
        var isComplete: Bool { left != nil && right != nil }
    }

    // MARK: - Nordic UART UUIDs

    private let uartServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let uartTXUUID      = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // Phone -> Glasses (Write)
    private let uartRXUUID      = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // Glasses -> Phone (Notify)

    // MARK: - BLE State

    private var centralManager: CBCentralManager!
    private var leftPeripheral: CBPeripheral?
    private var rightPeripheral: CBPeripheral?
    private var leftUUID: String?
    private var rightUUID: String?
    private var leftWriteChar: CBCharacteristic?
    private var rightWriteChar: CBCharacteristic?
    private var leftReadChar: CBCharacteristic?
    private var rightReadChar: CBCharacteristic?

    private var heartbeatTimer: Timer?
    private var heartbeatSeq: UInt8 = 0
    private var textSeq: UInt8 = 0

    private var connectingPairKey: String?

    // Response tracking for request/response protocol
    private var pendingResponse: CheckedContinuation<Data?, Never>?
    private var responseTimer: Timer?

    // MARK: - Init

    override init() {
        super.init()
        // CBCentralManager must be created on main queue for delegate callbacks
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    func startScan() {
        guard centralManager.state == .poweredOn else {
            connectionState = .error
            print("[G2] Bluetooth not powered on (state: \(centralManager.state.rawValue))")
            return
        }
        discoveredPairs.removeAll()
        connectionState = .scanning
        // Scan with nil services — G2 glasses may not advertise UART service in scan response
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        print("[G2] Scanning...")
    }

    func stopScan() {
        centralManager.stopScan()
        if connectionState == .scanning {
            connectionState = discoveredPairs.isEmpty ? .disconnected : .found
        }
    }

    func connect(pairKey: String) {
        guard let pair = discoveredPairs[pairKey],
              let left = pair.left,
              let right = pair.right else {
            print("[G2] Pair not complete for key: \(pairKey)")
            return
        }

        stopScan()
        connectingPairKey = pairKey
        connectionState = .connecting

        centralManager.connect(left, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
        centralManager.connect(right, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
        print("[G2] Connecting to pair \(pairKey)...")
    }

    func disconnect() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        if let l = leftPeripheral { centralManager.cancelPeripheralConnection(l) }
        if let r = rightPeripheral { centralManager.cancelPeripheralConnection(r) }

        leftPeripheral = nil
        rightPeripheral = nil
        leftWriteChar = nil
        rightWriteChar = nil
        leftReadChar = nil
        rightReadChar = nil
        leftUUID = nil
        rightUUID = nil

        connectionState = .disconnected
        print("[G2] Disconnected")
    }

    /// Send text to G2 lenses using the 0x4E EvenAI display command.
    /// Sends to Left first, then Right (required protocol).
    func sendText(_ text: String, screenStatus: UInt8 = 0x71, page: UInt8 = 1, totalPages: UInt8 = 1) {
        guard connectionState == .connected else {
            print("[G2] Not connected, can't send text")
            return
        }

        let textBytes = Array(text.utf8)
        let syncSeq = textSeq
        textSeq &+= 1

        // Build packet chunks (max 191 bytes of text per chunk)
        let chunkSize = 191
        var chunks: [Data] = []
        let totalChunks = max(1, (textBytes.count + chunkSize - 1) / chunkSize)

        for seq in 0..<totalChunks {
            let start = seq * chunkSize
            let end = min(start + chunkSize, textBytes.count)
            let chunkData = Array(textBytes[start..<end])

            var packet = Data()
            packet.append(0x4E)                          // Command
            packet.append(syncSeq)                       // Sync sequence
            packet.append(UInt8(totalChunks))             // Total sub-packets
            packet.append(UInt8(seq))                     // Current sub-packet index
            packet.append(screenStatus)                  // Screen status (teleprompter mode)
            packet.append(0x00)                          // Position high byte
            packet.append(0x00)                          // Position low byte
            packet.append(page)                          // Current page
            packet.append(totalPages)                    // Total pages
            packet.append(contentsOf: chunkData)
            chunks.append(packet)
        }

        // Send L then R
        for chunk in chunks {
            writeToLeft(chunk)
        }
        for chunk in chunks {
            writeToRight(chunk)
        }

        lensText = text
        print("[G2] Sent text (\(textBytes.count) bytes, \(totalChunks) chunks)")
    }

    /// Send the Marginalia options formatted for lens display
    func sendOptions(_ options: [ResponseOption]) {
        var lines: [String] = []
        for (i, opt) in options.prefix(3).enumerated() {
            let glyph = i == 0 ? "\u{25C9}" : "\u{25CB}"
            lines.append("\(glyph) \(opt.label)")
        }
        let text = lines.joined(separator: "\n")
        sendText(text)
    }

    /// Clear the G2 display / exit to dashboard
    func clearDisplay() {
        let exitCmd = Data([0x18])
        writeToLeft(exitCmd)
        writeToRight(exitCmd)
        lensText = ""
        print("[G2] Display cleared")
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendHeartbeat()
            }
        }
        print("[G2] Heartbeat started (8s interval)")
    }

    private func sendHeartbeat() {
        let seq = heartbeatSeq
        heartbeatSeq &+= 1
        let data = Data([0x25, 0x06, 0x00, seq, 0x04, seq])
        writeToLeft(data)
        writeToRight(data)
    }

    // MARK: - Write Helpers

    private func writeToLeft(_ data: Data) {
        guard let peripheral = leftPeripheral, let char = leftWriteChar else { return }
        peripheral.writeValue(data, for: char, type: .withoutResponse)
    }

    private func writeToRight(_ data: Data) {
        guard let peripheral = rightPeripheral, let char = rightWriteChar else { return }
        peripheral.writeValue(data, for: char, type: .withoutResponse)
    }
}

// MARK: - CBCentralManagerDelegate

extension G2BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                print("[G2] Bluetooth powered on")
            case .poweredOff:
                print("[G2] Bluetooth powered off")
                connectionState = .error
            default:
                print("[G2] Bluetooth state: \(central.state.rawValue)")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            guard let name = peripheral.name else { return }

            // G2 glasses advertise as "Even G2_XX_L_YYYYYY" / "Even G2_XX_R_YYYYYY"
            let components = name.components(separatedBy: "_")
            guard components.count > 1 else { return }
            guard let channelNumber = components.count > 1 ? components[1] : nil else { return }
            guard name.contains("_L_") || name.contains("_R_") else { return }

            let pairKey = "Pair_\(channelNumber)"

            if discoveredPairs[pairKey] == nil {
                discoveredPairs[pairKey] = GlassesPair(channelNumber: channelNumber)
            }

            if name.contains("_L_") {
                discoveredPairs[pairKey]?.left = peripheral
                discoveredPairs[pairKey]?.leftName = name
            } else if name.contains("_R_") {
                discoveredPairs[pairKey]?.right = peripheral
                discoveredPairs[pairKey]?.rightName = name
            }

            if discoveredPairs[pairKey]?.isComplete == true {
                connectionState = .found
                print("[G2] Found complete pair: \(pairKey) (L: \(discoveredPairs[pairKey]?.leftName ?? "?"), R: \(discoveredPairs[pairKey]?.rightName ?? "?"))")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard let pairKey = connectingPairKey,
                  let pair = discoveredPairs[pairKey] else { return }

            if pair.left === peripheral {
                leftPeripheral = peripheral
                leftUUID = peripheral.identifier.uuidString
                peripheral.delegate = self
                peripheral.discoverServices([uartServiceUUID])
                print("[G2] Left connected, discovering services...")
            } else if pair.right === peripheral {
                rightPeripheral = peripheral
                rightUUID = peripheral.identifier.uuidString
                peripheral.delegate = self
                peripheral.discoverServices([uartServiceUUID])
                print("[G2] Right connected, discovering services...")
            }

            // Check if both are connected
            if leftPeripheral != nil && rightPeripheral != nil {
                connectionState = .connected
                connectingPairKey = nil
                startHeartbeat()
                print("[G2] Both arms connected!")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            print("[G2] Failed to connect: \(error?.localizedDescription ?? "unknown")")
            connectionState = .error
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            print("[G2] Disconnected: \(peripheral.name ?? "unknown") — reconnecting...")
            // Auto-reconnect
            central.connect(peripheral, options: nil)
            connectionState = .connecting
        }
    }
}

// MARK: - CBPeripheralDelegate

extension G2BluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let services = peripheral.services else { return }
            for service in services {
                if service.uuid == uartServiceUUID {
                    peripheral.discoverCharacteristics(nil, for: service)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard let characteristics = service.characteristics else { return }

            let isLeft = peripheral.identifier.uuidString == leftUUID

            for char in characteristics {
                if char.uuid == uartRXUUID {
                    // Notify characteristic (glasses -> phone)
                    if isLeft {
                        leftReadChar = char
                    } else {
                        rightReadChar = char
                    }
                    peripheral.setNotifyValue(true, for: char)
                } else if char.uuid == uartTXUUID {
                    // Write characteristic (phone -> glasses)
                    if isLeft {
                        leftWriteChar = char
                    } else {
                        rightWriteChar = char
                    }
                }
            }

            // Send init command 0x4D 0x01 once both chars are found
            if isLeft && leftReadChar != nil && leftWriteChar != nil {
                writeToLeft(Data([0x4D, 0x01]))
                print("[G2] Left arm initialized (0x4D 0x01)")
            } else if !isLeft && rightReadChar != nil && rightWriteChar != nil {
                writeToRight(Data([0x4D, 0x01]))
                print("[G2] Right arm initialized (0x4D 0x01)")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard let data = characteristic.value, !data.isEmpty else { return }

            let cmd = data[0]
            let isLeft = peripheral.identifier.uuidString == leftUUID
            let side = isLeft ? "L" : "R"

            switch cmd {
            case 0xF5:
                // Device notification — touchpad events
                guard data.count > 1 else { return }
                let event = data[1]
                switch event {
                case 0: print("[G2] \(side): Exit event")
                case 1: print("[G2] \(side): Page turn (\(isLeft ? "prev" : "next"))")
                case 23: print("[G2] \(side): EvenAI start triggered")
                case 24: print("[G2] \(side): Recording finished")
                default: print("[G2] \(side): Unknown event \(event)")
                }

            case 0x25:
                // Heartbeat response — good
                break

            default:
                let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                print("[G2] \(side) received: \(hex)")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error = error {
                print("[G2] Notification subscription failed: \(error.localizedDescription)")
            } else if characteristic.isNotifying {
                print("[G2] Notification subscription active for \(characteristic.uuid)")
            }
        }
    }
}
