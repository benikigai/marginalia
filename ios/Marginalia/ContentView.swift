import SwiftUI

struct ContentView: View {
    @ObservedObject var engine: InferenceEngine
    @ObservedObject var server: LocalServer
    @ObservedObject var downloader: ModelDownloader
    @StateObject private var g2 = G2BluetoothManager()
    @State private var inputText = ""
    @State private var isProcessing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 16) {
                    // A: Status capsules
                    StatusBarSection(engine: engine, server: server, g2: g2)

                    // B: Model download (conditional)
                    if !downloader.llmReady || !downloader.sttReady {
                        ModelDownloadSection(downloader: downloader)
                    }

                    // C: Pipeline + Lens mirror
                    LensMirrorSection(engine: engine, g2: g2)

                    // D: Activity log
                    ActivityLogSection(engine: engine)

                    // E: Debug tools (collapsed)
                    DebugToolsSection(engine: engine, server: server, g2: g2)

                    Spacer().frame(height: 80) // space for floating bar
                }
                .padding()
            }

            // F: Floating bottom bar
            PipelineTestBar(
                inputText: $inputText,
                isProcessing: $isProcessing,
                engine: engine,
                disabled: engine.isWarming || engine.llmStatus == "Not loaded"
            )
        }
        .onChange(of: engine.lastOptions) { (_: [ResponseOption]?) in
            if let options = engine.lastOptions, g2.connectionState == .connected {
                g2.sendOptions(options)
            }
        }
    }
}

// MARK: - A: Status Bar

struct StatusBarSection: View {
    @ObservedObject var engine: InferenceEngine
    @ObservedObject var server: LocalServer
    @ObservedObject var g2: G2BluetoothManager

    private var g2Color: Color {
        switch g2.connectionState {
        case .connected: return .green
        case .scanning, .connecting, .found: return .orange
        case .disconnected, .error: return .red
        }
    }

    private var llmColor: Color {
        if engine.llmStatus == "Ready" { return .green }
        if engine.llmStatus.contains("Loading") || engine.llmStatus.contains("Warming") { return .orange }
        return .red
    }

    var body: some View {
        HStack(spacing: 12) {
            StatusCapsule(label: "G2", color: g2Color) {
                switch g2.connectionState {
                case .connected: g2.disconnect()
                case .scanning: g2.stopScan()
                default: g2.startScan()
                }
            }

            StatusCapsule(label: "LLM", color: llmColor) {}

            StatusCapsule(
                label: server.isRunning ? ":8080" : "Server",
                color: server.isRunning ? .green : .red
            ) {}

            Spacer()
        }
    }
}

// MARK: - B: Model Download

struct ModelDownloadSection: View {
    @ObservedObject var downloader: ModelDownloader

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                readyDot(label: "VAD", ready: downloader.vadReady)
                readyDot(label: "STT", ready: downloader.sttReady)
                readyDot(label: "LLM", ready: downloader.llmReady)
                Spacer()
            }

            if downloader.isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    Text(downloader.currentModel)
                        .font(.system(size: 12, weight: .medium))
                    Text("\(downloader.currentFile) \(downloader.fileProgress)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    ProgressView(value: downloader.progress)
                }
            } else {
                Button(action: {
                    Task { await downloader.downloadAll() }
                }) {
                    Label("Download Weights", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if let error = downloader.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func readyDot(label: String, ready: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ready ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
    }
}

// MARK: - C: Lens Mirror

struct LensMirrorSection: View {
    @ObservedObject var engine: InferenceEngine
    @ObservedObject var g2: G2BluetoothManager

    var body: some View {
        VStack(spacing: 8) {
            // Pipeline stage indicator
            HStack(spacing: 4) {
                pipelineDot("VAD", active: engine.pipelineStage == .listening)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                pipelineDot("STT", active: engine.pipelineStage == .stt)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                pipelineDot("LLM", active: engine.pipelineStage == .llm)
                Spacer()
                if let stats = engine.lastStats {
                    Text("\(stats.totalMs)ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // Black mirror box
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)
                    .frame(minHeight: 120)

                if engine.pipelineStage == .stt || engine.pipelineStage == .llm {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(.green)
                        Text(engine.pipelineStage.rawValue)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.green)
                    }
                } else if !g2.lensText.isEmpty {
                    Text(g2.lensText)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.green)
                        .padding()
                } else if let options = engine.lastOptions {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                            Text("\(i == 0 ? "\u{25C9}" : "\u{25CB}") \(opt.label)")
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(.green)
                        }
                    }
                    .padding()
                } else {
                    Text(engine.displayText)
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundColor(.green)
                }
            }
        }
    }

    private func pipelineDot(_ label: String, active: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(active ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: active ? .bold : .regular, design: .monospaced))
                .foregroundColor(active ? .green : .secondary)
        }
    }
}

// MARK: - D: Activity Log

struct ActivityLogSection: View {
    @ObservedObject var engine: InferenceEngine
    @State private var expandedId: UUID?

    var body: some View {
        if !engine.activityLog.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Activity")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(min(engine.activityLog.count, 10)) runs")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                ForEach(engine.activityLog.prefix(10)) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(entry.timestamp, style: .time)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)

                            Text("[\(entry.source.rawValue)]")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(entry.source == .glasses ? .blue : .purple)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    (entry.source == .glasses ? Color.blue : Color.purple)
                                        .opacity(0.15)
                                )
                                .cornerRadius(3)

                            Text(entry.transcript)
                                .font(.system(size: 12))
                                .lineLimit(expandedId == entry.id ? nil : 1)
                                .foregroundColor(.primary)

                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedId = expandedId == entry.id ? nil : entry.id
                            }
                        }

                        if let stats = entry.stats {
                            HStack(spacing: 8) {
                                Spacer().frame(width: 56)
                                if stats.sttMs > 0 {
                                    Text("STT \(stats.sttMs)ms")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Text("LLM \(stats.llmMs)ms")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }

                        if expandedId == entry.id {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(entry.options.enumerated()), id: \.offset) { i, opt in
                                    Text("\(i == 0 ? "\u{25C9}" : "\u{25CB}") \(opt.label)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.primary)
                                }
                            }
                            .padding(.leading, 60)
                        }
                    }
                    Divider()
                }
            }
        }
    }
}

// MARK: - E: Debug Tools

struct DebugToolsSection: View {
    @ObservedObject var engine: InferenceEngine
    @ObservedObject var server: LocalServer
    @ObservedObject var g2: G2BluetoothManager
    @State private var chatInput = ""
    @State private var chatResponse = ""
    @State private var isChatLoading = false

    var body: some View {
        DisclosureGroup("Debug Tools") {
            VStack(spacing: 16) {
                // Raw Chat
                GroupBox("Raw Chat") {
                    VStack(spacing: 8) {
                        if !chatResponse.isEmpty {
                            Text(chatResponse)
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 8) {
                            TextField("Type a message...", text: $chatInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                                .disabled(isChatLoading)
                            Button(action: sendChat) {
                                if isChatLoading {
                                    ProgressView().scaleEffect(0.7)
                                } else {
                                    Image(systemName: "arrow.up.circle.fill")
                                }
                            }
                            .disabled(chatInput.trimmingCharacters(in: .whitespaces).isEmpty || isChatLoading)
                        }
                    }
                }

                // Model Details
                GroupBox("Model Details") {
                    VStack(alignment: .leading, spacing: 6) {
                        StatusRow(label: "VAD", status: engine.vadStatus)
                        StatusRow(label: "STT Model", status: engine.sttStatus)
                        StatusRow(label: "LLM Model", status: engine.llmStatus)
                        StatusRow(label: "Server", status: server.isRunning ? "Running on :8080" : "Stopped")
                        if engine.isWarming {
                            StatusRow(label: "Warm-up", status: "Warming...")
                        }
                        if let conf = engine.lastConfidence {
                            StatusRow(label: "Confidence", status: String(format: "%.1f%%", conf * 100))
                        }
                        if engine.usedCloudHandoff {
                            StatusRow(label: "Cloud", status: "Handoff used")
                        }
                    }
                }

                // G2 Connection
                GroupBox("G2 Connection") {
                    VStack(alignment: .leading, spacing: 8) {
                        StatusRow(label: "BLE Status", status: g2.connectionState.rawValue)

                        if g2.connectionState == .disconnected || g2.connectionState == .error {
                            Button(action: { g2.startScan() }) {
                                Label("Scan for G2", systemImage: "antenna.radiowaves.left.and.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                        }

                        if g2.connectionState == .scanning {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text("Scanning...")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Stop") { g2.stopScan() }
                                    .font(.system(size: 12))
                            }
                        }

                        ForEach(Array(g2.discoveredPairs.keys.sorted()), id: \.self) { key in
                            if let pair = g2.discoveredPairs[key], pair.isComplete {
                                Button(action: { g2.connect(pairKey: key) }) {
                                    HStack {
                                        Image(systemName: "eyeglasses")
                                        VStack(alignment: .leading) {
                                            Text(key)
                                                .font(.system(size: 13, weight: .medium))
                                            Text("L: \(pair.leftName ?? "?") | R: \(pair.rightName ?? "?")")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.right.circle")
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        if g2.connectionState == .connected {
                            HStack {
                                Button(action: {
                                    if let options = engine.lastOptions {
                                        g2.sendOptions(options)
                                    } else {
                                        g2.sendText("Marginalia ready\nWaiting for input...")
                                    }
                                }) {
                                    Label("Send to Lens", systemImage: "arrow.up.right")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)

                                Button(action: { g2.clearDisplay() }) {
                                    Label("Clear", systemImage: "xmark.circle")
                                }
                                .buttonStyle(.bordered)

                                Spacer()

                                Button(action: { g2.disconnect() }) {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                        }
                    }
                }

                // Calendar Events
                if !engine.calendarEvents.isEmpty {
                    GroupBox("Calendar Events") {
                        ForEach(engine.calendarEvents, id: \.title) { event in
                            HStack {
                                Image(systemName: "calendar.badge.plus")
                                Text("\(event.title) (\(event.startDate))")
                                    .font(.system(size: 12))
                            }
                        }
                    }
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
    }

    private func sendChat() {
        let prompt = chatInput.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return }
        chatInput = ""
        isChatLoading = true
        chatResponse = ""
        Task {
            chatResponse = await engine.chat(prompt: prompt)
            isChatLoading = false
        }
    }
}

// MARK: - F: Pipeline Test Bar

struct PipelineTestBar: View {
    @Binding var inputText: String
    @Binding var isProcessing: Bool
    var engine: InferenceEngine
    var disabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Type what someone said...", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .disabled(disabled || isProcessing)

            Button(action: runTextInference) {
                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.title3)
                }
            }
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || disabled || isProcessing)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func runTextInference() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        isProcessing = true
        Task {
            await engine.runTextInference(text: text)
            isProcessing = false
        }
    }
}

// MARK: - Components

struct StatusCapsule: View {
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.systemGray6))
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

struct StatusRow: View {
    let label: String
    let status: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Text(status)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(status.contains("Ready") || status.contains("Running") || status.contains("Connected") ? .green : .orange)
        }
    }
}
