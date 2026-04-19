import SwiftUI

struct ContentView: View {
    @ObservedObject var engine: InferenceEngine
    @ObservedObject var server: LocalServer
    @StateObject private var downloader = ModelDownloader()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Status header
                    VStack(spacing: 8) {
                        Text("MARGINALIA")
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                        Text("On-Device Voice Agent")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Model download section (shown when weights missing)
                    if !downloader.sttReady || !downloader.llmReady {
                        GroupBox("Model Weights") {
                            VStack(alignment: .leading, spacing: 10) {
                                StatusRow(label: "Parakeet STT", status: downloader.sttReady ? "Ready" : "Missing")
                                StatusRow(label: "Gemma 4 E2B", status: downloader.llmReady ? "Ready" : "Missing")

                                if downloader.isDownloading {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(downloader.currentModel)")
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
                                        Label("Download Models (~2 GB)", systemImage: "arrow.down.circle.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Text("Or transfer via Finder (USB) to Documents/weights/")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }

                                if let error = downloader.error {
                                    Text(error)
                                        .font(.system(size: 11))
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }

                    // Model status
                    GroupBox("Inference Engine") {
                        VStack(alignment: .leading, spacing: 8) {
                            StatusRow(label: "VAD", status: engine.vadStatus)
                            StatusRow(label: "STT Model", status: engine.sttStatus)
                            StatusRow(label: "LLM Model", status: engine.llmStatus)
                            StatusRow(label: "Server", status: server.isRunning ? "Running on :8080" : "Stopped")
                            if let conf = engine.lastConfidence {
                                StatusRow(label: "Confidence", status: String(format: "%.1f%%", conf * 100))
                            }
                            if engine.usedCloudHandoff {
                                StatusRow(label: "Cloud", status: "Handoff used")
                            }
                        }
                    }

                    // Mirror display — shows what glasses see
                    GroupBox("G2 Lens Mirror") {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black)
                                .frame(height: 144)

                            if let options = engine.lastOptions {
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

                    // Last inference stats
                    if let stats = engine.lastStats {
                        GroupBox("Last Inference") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("STT: \(stats.sttMs)ms")
                                Text("LLM: \(stats.llmMs)ms")
                                Text("Total: \(stats.totalMs)ms")
                            }
                            .font(.system(size: 12, design: .monospaced))
                        }
                    }

                    // Calendar events
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

                    // Instructions
                    Text("Even Realities app \u{2192} Load: http://localhost:8080")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .padding()
            }
            .navigationBarHidden(true)
            .onChange(of: downloader.sttReady) { ready in
                if ready && downloader.llmReady {
                    Task { await engine.loadModels() }
                }
            }
            .onChange(of: downloader.llmReady) { ready in
                if ready && downloader.sttReady {
                    Task { await engine.loadModels() }
                }
            }
        }
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
                .foregroundColor(status.contains("Ready") || status.contains("Running") ? .green : .orange)
        }
    }
}
