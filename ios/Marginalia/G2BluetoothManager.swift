import Foundation
import CoreBluetooth
import Combine

/// Native BLE connection to Even Realities G2 glasses.
/// Implements the G2 protocol: auth handshake, text display, and audio streaming.
/// No Even Realities app required.
@MainActor
class G2BluetoothManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var connectionState: ConnectionState = .disconnected
    @Published var discoveredPairs: [String: GlassesPair] = [:]
    @Published var lensText: String = ""
    @Published var isAuthenticated = false
    @Published var isAudioStreaming = false
    @Published var audioFrameCount = 0
    @Published var lastError: String?

    /// Callback for incoming audio PCM data. Set by the app to pipe into InferenceEngine.
    var onAudioData: ((Data) -> Void)?

    enum ConnectionState: String {
        case disconnected = "Disconnected"
        case scanning = "Scanning..."
        case found = "Found G2"
        case connecting = "Connecting..."
        case connected = "Connected"
        case authenticating = "Authenticating..."
        case ready = "Ready"
        case error = "Error"
    }

    struct GlassesPair: Identifiable {
        var id: String { channelNumber }
        var left: CBPeripheral?
        var right: CBPeripheral?
        var channelNumber: String
        var leftName: String?
        var rightName: String?
        var isComplete: Bool { left != nil && right != nil }
    }

    // MARK: - G2 Protocol UUIDs

    // Primary G2 service (custom)
    private let g2ServiceUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E0000")
    // Write: Phone → Glasses
    private let g2WriteUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E5401")
    // Notify: Glasses → Phone
    private let g2NotifyUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E5402")

    // Fallback: Nordic UART (some firmware versions)
    private let uartServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let uartTXUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let uartRXUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    // MARK: - BLE State

    private var centralManager: CBCentralManager!
    private var leftPeripheral: CBPeripheral?
    private var rightPeripheral: CBPeripheral?
    private var leftUUID: String?
    private var rightUUID: String?

    // G2 protocol characteristics
    private var leftWriteChar: CBCharacteristic?
    private var rightWriteChar: CBCharacteristic?
    private var leftNotifyChar: CBCharacteristic?
    private var rightNotifyChar: CBCharacteristic?

    // UART fallback characteristics
    private var leftUartTX: CBCharacteristic?
    private var rightUartTX: CBCharacteristic?

    private var usingUART = false  // tracks which protocol we're using

    private var heartbeatTimer: Timer?
    private var heartbeatSeq: UInt8 = 0
    private var packetSeq: UInt8 = 1
    private var msgId: UInt8 = 0x0C
    private var textSeq: UInt8 = 0

    private var connectingPairKey: String?
    private var leftConnected = false
    private var rightConnected = false
    private var leftServicesDiscovered = false
    private var rightServicesDiscovered = false

    // Audio buffer
    private var audioBuffer = Data()
    private let audioFrameBytes = 320  // 10ms at 16kHz 16-bit mono = 320 bytes

    // MARK: - Init

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    func startScan() {
        guard centralManager.state == .poweredOn else {
            connectionState = .error
            lastError = "Bluetooth not powered on"
            return
        }
        discoveredPairs.removeAll()
        connectionState = .scanning
        lastError = nil
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        print("[G2] Scanning for glasses... (force-close Even app first if glasses are paired)")
        print("[G2] Looking for devices with 'Even', 'G2', '_L_', or '_R_' in name")

        // Auto-stop scan after 15s
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.connectionState == .scanning {
                self?.stopScan()
            }
        }
    }

    func stopScan() {
        centralManager.stopScan()
        if connectionState == .scanning {
            connectionState = discoveredPairs.isEmpty ? .disconnected : .found
        }
    }

    func connect(pairKey: String) {
        guard let pair = discoveredPairs[pairKey] else {
            lastError = "Pair not found"
            print("[G2] ERROR: No pair for key \(pairKey)")
            return
        }

        print("[G2] Pair status — L: \(pair.leftName ?? "nil") R: \(pair.rightName ?? "nil") complete: \(pair.isComplete)")

        stopScan()
        connectingPairKey = pairKey
        connectionState = .connecting
        leftConnected = false
        rightConnected = false
        leftServicesDiscovered = false
        rightServicesDiscovered = false

        // Connect whichever arms we found (don't require both)
        if let left = pair.left {
            centralManager.connect(left, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
            print("[G2] Connecting left: \(pair.leftName ?? "?")")
        }
        if let right = pair.right {
            centralManager.connect(right, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
            print("[G2] Connecting right: \(pair.rightName ?? "?")")
        }

        if pair.left == nil && pair.right == nil {
            lastError = "No peripherals to connect"
            connectionState = .error
        }
    }

    func disconnect() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        if let l = leftPeripheral { centralManager.cancelPeripheralConnection(l) }
        if let r = rightPeripheral { centralManager.cancelPeripheralConnection(r) }
        resetState()
        connectionState = .disconnected
    }

    /// Send text to G2 lens display
    func sendText(_ text: String) {
        if usingUART {
            sendTextUART(text)
        } else {
            sendTextProtocol(text)
        }
        lensText = text
    }

    /// Send Marginalia options formatted for lens
    func sendOptions(_ options: [ResponseOption]) {
        let lines = options.prefix(3).enumerated().map { i, opt in
            "\(i == 0 ? "\u{25C9}" : "\u{25CB}") \(opt.label)"
        }
        sendText(lines.joined(separator: "\n"))
    }

    func sendDone(_ label: String) {
        sendText("\u{2713} Done \u{2014} \(label)")
    }

    /// Enable/disable G2 microphone audio streaming
    func setAudioStreaming(_ enabled: Bool) {
        if usingUART {
            // UART mode: send audio control command
            let cmd = Data([0x0E, enabled ? 0x01 : 0x00])
            writeToLeft(cmd)
        } else {
            // G2 protocol: send audio enable via service 0x0B-20
            let payload: [UInt8] = [0x08, 0x01, 0x10, enabled ? 0x01 : 0x00]
            let packet = buildPacket(service: (0x0B, 0x20), payload: payload)
            writeToLeft(packet)
        }
        isAudioStreaming = enabled
        audioFrameCount = 0
        print("[G2] Audio streaming: \(enabled)")
    }

    // MARK: - Authentication (Fast 3-Packet)

    private func authenticate() {
        connectionState = .authenticating
        print("[G2] Starting auth handshake...")

        // Packet 1: Capability query (service 0x80-00, type 0x04)
        let pkt1Payload: [UInt8] = [0x08, 0x04, 0x10, nextMsgId(), 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04]
        let pkt1 = buildPacket(service: (0x80, 0x00), payload: pkt1Payload)
        writeToLeft(pkt1)
        writeToRight(pkt1)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

            // Packet 2: Fast mode response (service 0x80-20, type 0x05)
            let pkt2Payload: [UInt8] = [0x08, 0x05, 0x10, self.nextMsgId(), 0x22, 0x02, 0x08, 0x02]
            let pkt2 = self.buildPacket(service: (0x80, 0x20), payload: pkt2Payload)
            self.writeToLeft(pkt2)
            self.writeToRight(pkt2)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }

                // Packet 3: Time sync (service 0x80-20, type 0x80)
                let timestamp = UInt32(Date().timeIntervalSince1970)
                var tsVarint = self.encodeVarint(Int(timestamp))
                let txId: [UInt8] = [0xE8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]

                var innerPayload: [UInt8] = [0x08] + tsVarint + [0x18] + txId
                let innerLen = self.encodeVarint(innerPayload.count)
                var pkt3Payload: [UInt8] = [0x08, 0x80, 0x01, 0x10, self.nextMsgId(), 0x82, 0x08] + innerLen + innerPayload
                let pkt3 = self.buildPacket(service: (0x80, 0x20), payload: pkt3Payload)
                self.writeToLeft(pkt3)
                self.writeToRight(pkt3)

                // Mark as authenticated after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.isAuthenticated = true
                    self?.connectionState = .ready
                    self?.startHeartbeat()
                    print("[G2] Auth complete — ready")
                }
            }
        }
    }

    // MARK: - Text Display (UART fallback)

    private func sendTextUART(_ text: String) {
        let textBytes = Array(text.utf8)
        let syncSeq = textSeq
        textSeq &+= 1
        let chunkSize = 191

        let totalChunks = max(1, (textBytes.count + chunkSize - 1) / chunkSize)
        for seq in 0..<totalChunks {
            let start = seq * chunkSize
            let end = min(start + chunkSize, textBytes.count)
            let chunk = Array(textBytes[start..<end])

            var packet = Data()
            packet.append(0x4E)
            packet.append(syncSeq)
            packet.append(UInt8(totalChunks))
            packet.append(UInt8(seq))
            packet.append(0x71)  // teleprompter mode
            packet.append(0x00)
            packet.append(0x00)
            packet.append(0x01)  // page
            packet.append(0x01)  // total pages
            packet.append(contentsOf: chunk)

            writeToLeft(packet)
            writeToRight(packet)
        }
        print("[G2] Sent text via UART (\(textBytes.count) bytes)")
    }

    // MARK: - Text Display (G2 protocol)

    private func sendTextProtocol(_ text: String) {
        // For hackathon: use the simpler 0x4E command via the protocol write char
        // This works on most firmware as a quick path
        sendTextUART(text)
    }

    // MARK: - Packet Building

    private func buildPacket(service: (UInt8, UInt8), payload: [UInt8]) -> Data {
        let seq = nextSeq()
        let len = UInt8(payload.count + 2)  // +2 for CRC

        var header: [UInt8] = [0xAA, 0x21, seq, len, 0x01, 0x01, service.0, service.1]
        let crc = crc16ccitt(payload)

        var packet = Data(header)
        packet.append(contentsOf: payload)
        packet.append(UInt8(crc & 0xFF))
        packet.append(UInt8((crc >> 8) & 0xFF))
        return packet
    }

    private func crc16ccitt(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
                crc &= 0xFFFF
            }
        }
        return crc
    }

    private func encodeVarint(_ value: Int) -> [UInt8] {
        var result: [UInt8] = []
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v > 0 { byte |= 0x80 }
            result.append(byte)
        } while v > 0
        return result
    }

    private func nextSeq() -> UInt8 {
        let s = packetSeq
        packetSeq &+= 1
        return s
    }

    private func nextMsgId() -> UInt8 {
        let m = msgId
        msgId &+= 1
        return m
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendHeartbeat() }
        }
    }

    private func sendHeartbeat() {
        if usingUART {
            let seq = heartbeatSeq
            heartbeatSeq &+= 1
            let data = Data([0x25, 0x06, 0x00, seq, 0x04, seq])
            writeToLeft(data)
            writeToRight(data)
        } else {
            let payload: [UInt8] = [0x08, 0x04, 0x10, nextMsgId(), 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04]
            let pkt = buildPacket(service: (0x80, 0x00), payload: payload)
            writeToLeft(pkt)
            writeToRight(pkt)
        }
    }

    // MARK: - Write Helpers

    private func writeToLeft(_ data: Data) {
        guard let peripheral = leftPeripheral else { return }
        if let char = leftWriteChar {
            peripheral.writeValue(data, for: char, type: .withoutResponse)
        } else if let char = leftUartTX {
            peripheral.writeValue(data, for: char, type: .withoutResponse)
        }
    }

    private func writeToRight(_ data: Data) {
        guard let peripheral = rightPeripheral else { return }
        if let char = rightWriteChar {
            peripheral.writeValue(data, for: char, type: .withoutResponse)
        } else if let char = rightUartTX {
            peripheral.writeValue(data, for: char, type: .withoutResponse)
        }
    }

    private func resetState() {
        leftPeripheral = nil
        rightPeripheral = nil
        leftWriteChar = nil
        rightWriteChar = nil
        leftNotifyChar = nil
        rightNotifyChar = nil
        leftUartTX = nil
        rightUartTX = nil
        leftUUID = nil
        rightUUID = nil
        isAuthenticated = false
        isAudioStreaming = false
        audioFrameCount = 0
        leftConnected = false
        rightConnected = false
        leftServicesDiscovered = false
        rightServicesDiscovered = false
        usingUART = false
    }
}

// MARK: - CBCentralManagerDelegate

extension G2BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn {
                print("[G2] Bluetooth powered on")
            } else {
                print("[G2] Bluetooth state: \(central.state.rawValue)")
                if central.state != .unknown { connectionState = .error }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            let name = peripheral.name ?? "(no name)"

            // Log ALL devices with "Even" or "G2" anywhere, plus any device with signal > -70 dBm
            if name.lowercased().contains("even") || name.lowercased().contains("g2") || name.contains("_L_") || name.contains("_R_") {
                print("[G2] Found: \"\(name)\" RSSI=\(RSSI) id=\(peripheral.identifier.uuidString.prefix(8))")
            }

            // Accept: "Even G2_XX_L_YYYY", "Even G2_XX_R_YYYY", or anything with _L_ / _R_ and "Even"/"G2"
            guard name.contains("_L_") || name.contains("_R_") else { return }
            guard name.lowercased().contains("even") || name.lowercased().contains("g2") else { return }

            let parts = name.components(separatedBy: "_")
            guard parts.count > 1 else { return }
            let channel = parts[1]

            let pairKey = channel

            if discoveredPairs[pairKey] == nil {
                discoveredPairs[pairKey] = GlassesPair(channelNumber: channel)
            }

            if name.contains("_L_") {
                discoveredPairs[pairKey]?.left = peripheral
                discoveredPairs[pairKey]?.leftName = name
            } else {
                discoveredPairs[pairKey]?.right = peripheral
                discoveredPairs[pairKey]?.rightName = name
            }

            if discoveredPairs[pairKey]?.isComplete == true {
                connectionState = .found
                print("[G2] Found complete pair: L=\(discoveredPairs[pairKey]?.leftName ?? "?") R=\(discoveredPairs[pairKey]?.rightName ?? "?")")
                // Auto-connect to first complete pair
                connect(pairKey: pairKey)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            peripheral.delegate = self

            let isLeft = discoveredPairs[connectingPairKey ?? ""]?.left === peripheral
            if isLeft {
                leftPeripheral = peripheral
                leftUUID = peripheral.identifier.uuidString
                leftConnected = true
            } else {
                rightPeripheral = peripheral
                rightUUID = peripheral.identifier.uuidString
                rightConnected = true
            }

            // Discover ONLY the Nordic UART service — this is what the G2 firmware exposes
            // (discovering all services can miss UART on some firmware versions)
            peripheral.discoverServices([uartServiceUUID])
            print("[G2] \(isLeft ? "Left" : "Right") connected, discovering services...")

            checkBothReady()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            lastError = "Connection failed: \(error?.localizedDescription ?? "unknown")"
            connectionState = .error
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            print("[G2] Disconnected: \(peripheral.name ?? "?") — auto-reconnecting")
            connectionState = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    private func checkBothReady() {
        // Proceed when at least one side has discovered services
        // Don't wait for both if only one arm was found
        let pair = discoveredPairs[connectingPairKey ?? ""]
        let needLeft = pair?.left != nil
        let needRight = pair?.right != nil
        let leftDone = !needLeft || leftServicesDiscovered
        let rightDone = !needRight || rightServicesDiscovered

        guard leftDone && rightDone else { return }

        print("[G2] Services discovered — L:\(leftServicesDiscovered) R:\(rightServicesDiscovered)")
        print("[G2] Write chars — g2L:\(leftWriteChar != nil) g2R:\(rightWriteChar != nil) uartL:\(leftUartTX != nil) uartR:\(rightUartTX != nil)")

        // Prefer UART (the protocol the Even app actually uses)
        if leftUartTX != nil || rightUartTX != nil {
            usingUART = true
            let initCmd = Data([0x4D, 0x01])
            writeToLeft(initCmd)
            writeToRight(initCmd)
            isAuthenticated = true
            connectionState = .ready
            startHeartbeat()
            print("[G2] UART mode — initialized, ready")
        } else if leftWriteChar != nil || rightWriteChar != nil {
            authenticate()
        } else {
            lastError = "No write characteristics found — force-close Even app and retry"
            connectionState = .error
            print("[G2] ERROR: No writable characteristics discovered")
            print("[G2] TIP: Force-close the Even Realities app, then scan again")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension G2BluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let services = peripheral.services else { return }
            for service in services {
                print("[G2] Found service: \(service.uuid)")
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard let chars = service.characteristics else { return }
            let isLeft = peripheral.identifier.uuidString == leftUUID

            for char in chars {
                print("[G2] \(isLeft ? "L" : "R") char: \(char.uuid) props=\(char.properties.rawValue)")

                // G2 protocol characteristics
                if char.uuid == g2WriteUUID {
                    if isLeft { leftWriteChar = char } else { rightWriteChar = char }
                }
                if char.uuid == g2NotifyUUID {
                    if isLeft { leftNotifyChar = char } else { rightNotifyChar = char }
                    peripheral.setNotifyValue(true, for: char)
                }

                // UART fallback
                if char.uuid == uartTXUUID {
                    if isLeft { leftUartTX = char } else { rightUartTX = char }
                    usingUART = true
                }
                if char.uuid == uartRXUUID {
                    peripheral.setNotifyValue(true, for: char)
                }

                // Subscribe to any notify characteristic (to catch audio on unknown UUIDs)
                if char.properties.contains(.notify) && char.uuid != g2NotifyUUID && char.uuid != uartRXUUID {
                    peripheral.setNotifyValue(true, for: char)
                }
            }

            if isLeft { leftServicesDiscovered = true } else { rightServicesDiscovered = true }
            checkBothReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard let data = characteristic.value, !data.isEmpty else { return }
            let isLeft = peripheral.identifier.uuidString == leftUUID
            let side = isLeft ? "L" : "R"

            let cmd = data[0]

            // Check for audio data — G2 sends PCM frames (typically 320 bytes = 10ms at 16kHz 16-bit)
            // Audio frames are usually larger payloads without a known command prefix
            if data.count >= 160 && data.count <= 960 && isAudioStreaming {
                audioFrameCount += 1
                onAudioData?(data)
                return
            }

            switch cmd {
            case 0xF5:
                // Touchpad event
                guard data.count > 1 else { return }
                let event = data[1]
                print("[G2] \(side) touch event: \(event)")
                // 0=exit, 1=page turn, 23=EvenAI start, 24=recording done

            case 0x25:
                // Heartbeat ack
                break

            case 0xAA:
                // G2 protocol response
                if data.count > 7 {
                    let svcHi = data[6]
                    let svcLo = data[7]
                    print("[G2] \(side) protocol response: svc=\(String(format: "%02X-%02X", svcHi, svcLo)) len=\(data.count)")
                    // Auth success check: service 0x80-01
                    if svcHi == 0x80 && svcLo == 0x01 {
                        print("[G2] Auth response received")
                    }
                }

            default:
                let hex = data.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " ")
                print("[G2] \(side) data [\(data.count)b]: \(hex)\(data.count > 20 ? "..." : "")")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error = error {
                print("[G2] Notify failed for \(characteristic.uuid): \(error.localizedDescription)")
            } else if characteristic.isNotifying {
                print("[G2] Notify active: \(characteristic.uuid)")
            }
        }
    }
}
