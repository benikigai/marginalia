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

                    // C: Glasses HUD
                    LensMirrorSection(engine: engine, g2: g2)

                    // D: Activity log
                    ActivityLogSection(engine: engine)

                    // E: G2 Connection
                    G2ConnectionSection(engine: engine, g2: g2)

                    // F: Debug tools (collapsed)
                    DebugToolsSection(engine: engine, server: server)

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
        .onChange(of: engine.lastOptions) { _, newOptions in
            if let options = newOptions, (g2.connectionState == .connected || g2.connectionState == .ready) {
                g2.sendOptions(options)
            }
        }
        .onAppear {
            // Wire G2 audio to inference engine
            g2.onAudioData = { [weak engine] audioData in
                Task { @MainActor in
                    guard let engine = engine else { return }
                    let _ = await engine.runInference(audioData: audioData)
                }
            }
        }
    }
}

// MARK: - A: Status Bar

struct StatusBarSection: View {
    @ObservedObject var engine: InferenceEngine
    @ObservedObject var server: LocalServer
    @ObservedObject var g2: G2BluetoothManager

    var body: some View {
        HStack(spacing: 12) {
            StatusCapsule(
                label: "G2",
                color: g2.connectionState == .connected || g2.connectionState == .ready ? .green :
                       g2.connectionState == .scanning || g2.connectionState == .connecting || g2.connectionState == .authenticating ? .orange : .red
            ) {
                if g2.connectionState == .connected || g2.connectionState == .ready {
                    g2.disconnect()
                } else if g2.connectionState == .scanning {
                    g2.stopScan()
                } else {
                    g2.startScan()
                }
            }

            StatusCapsule(
                label: "LLM",
                color: engine.llmStatus == "Ready" ? .green :
                       engine.llmStatus.contains("Loading") || engine.llmStatus.contains("Warming") ? .orange : .red
            ) {}

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

// MARK: - C: Glasses HUD

struct LensMirrorSection: View {
    @ObservedObject var engine: InferenceEngine
    @ObservedObject var g2: G2BluetoothManager

    var body: some View {
        VStack(spacing: 0) {
            // Header — glasses frame bar
            HStack {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 12))
                    .foregroundColor(.green.opacity(0.7))
                Text("GLASSES HUD")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.green.opacity(0.7))
                    .tracking(2)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(g2.connectionState == .connected || g2.connectionState == .ready ? Color.green : Color.red.opacity(0.6))
                        .frame(width: 6, height: 6)
                    Text(g2.connectionState == .connected || g2.connectionState == .ready ? "LIVE" : "OFF")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(g2.connectionState == .connected || g2.connectionState == .ready ? .green.opacity(0.7) : .red.opacity(0.6))
                }
                if let stats = engine.lastStats {
                    Text("\(stats.totalMs)ms")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.green.opacity(0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black)

            // Lens display
            ZStack {
                RoundedRectangle(cornerRadius: 0)
                    .fill(Color.black)
                    .frame(minHeight: 140)

                if engine.pipelineStage == .stt || engine.pipelineStage == .llm {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.green)
                        Text(engine.pipelineStage.rawValue)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.green.opacity(0.8))
                    }
                } else if !g2.lensText.isEmpty {
                    Text(g2.lensText)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.green)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let options = engine.lastOptions {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                            HStack(spacing: 8) {
                                Text(i == 0 ? "\u{25B6}" : "\u{25CB}")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(i == 0 ? .green : .green.opacity(0.5))
                                Text(opt.label)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(i == 0 ? .green : .green.opacity(0.6))
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "eye")
                            .font(.system(size: 20))
                            .foregroundColor(.green.opacity(0.2))
                        Text("Waiting for input...")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.green.opacity(0.3))
                    }
                }
            }

            // Pipeline bar
            HStack(spacing: 4) {
                pipelineDot("VAD", active: engine.pipelineStage == .listening)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7))
                    .foregroundColor(.green.opacity(0.3))
                pipelineDot("STT", active: engine.pipelineStage == .stt)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7))
                    .foregroundColor(.green.opacity(0.3))
                pipelineDot("LLM", active: engine.pipelineStage == .llm)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.green.opacity(0.2), lineWidth: 1)
        )
    }

    private func pipelineDot(_ label: String, active: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(active ? Color.green : Color.green.opacity(0.15))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9, weight: active ? .bold : .regular, design: .monospaced))
                .foregroundColor(active ? .green : .green.opacity(0.3))
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

// MARK: - E: G2 Connection

struct G2ConnectionSection: View {
    @ObservedObject var engine: InferenceEngine
    @ObservedObject var g2: G2BluetoothManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 14))
                Text("G2 Glasses")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

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
                if let pair = g2.discoveredPairs[key] {
                    Button(action: { g2.connect(pairKey: key) }) {
                        HStack {
                            Image(systemName: "eyeglasses")
                            VStack(alignment: .leading) {
                                Text(key)
                                    .font(.system(size: 13, weight: .medium))
                                HStack(spacing: 4) {
                                    Text("L: \(pair.left != nil ? "\u{2713}" : "\u{2014}")")
                                    Text("R: \(pair.right != nil ? "\u{2713}" : "\u{2014}")")
                                }
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            }
                            Spacer()
                            if pair.isComplete {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundColor(.green)
                            } else {
                                Image(systemName: "arrow.right.circle")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if g2.connectionState == .connected || g2.connectionState == .ready {
                VStack(spacing: 8) {
                    HStack {
                        Button(action: { g2.sendText("TEST 123") }) {
                            Label("Test Lens", systemImage: "eye")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button(action: {
                            if let options = engine.lastOptions {
                                g2.sendOptions(options)
                            } else {
                                g2.sendText("Marginalia ready")
                            }
                        }) {
                            Label("Send to Lens", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        Button(action: { g2.sendText("") }) {
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

                    HStack {
                        Toggle(isOn: Binding(
                            get: { g2.isAudioStreaming },
                            set: { g2.setAudioStreaming($0) }
                        )) {
                            Label("G2 Mic Audio", systemImage: "mic.fill")
                                .font(.system(size: 12))
                        }
                        .toggleStyle(.switch)

                        if g2.audioFrameCount > 0 {
                            Text("\(g2.audioFrameCount) frames")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    if g2.isAuthenticated {
                        StatusRow(label: "Auth", status: "Authenticated")
                    }
                    if let error = g2.lastError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - F: Debug Tools

struct DebugToolsSection: View {
    @ObservedObject var engine: InferenceEngine
    @ObservedObject var server: LocalServer
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
