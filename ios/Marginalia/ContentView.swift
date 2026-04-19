import SwiftUI

struct ContentView: View {
    @ObservedObject var engine: InferenceEngine
    @ObservedObject var server: LocalServer

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Status header
                VStack(spacing: 8) {
                    Text("MARGINALIA")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                    Text("On-Device Voice Agent")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Model status
                GroupBox("Inference Engine") {
                    VStack(alignment: .leading, spacing: 8) {
                        StatusRow(label: "STT Model", status: engine.sttStatus)
                        StatusRow(label: "LLM Model", status: engine.llmStatus)
                        StatusRow(label: "Server", status: server.isRunning ? "Running on :8080" : "Stopped")
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

                Spacer()

                // Instructions
                Text("Even Realities app → Load: http://localhost:8080")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .navigationBarHidden(true)
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
