import SwiftUI

@main
struct MarginaliaApp: App {
    @StateObject private var engine = InferenceEngine()
    @StateObject private var server = LocalServer()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine, server: server)
                .task {
                    await engine.loadModels()
                    server.engine = engine
                    server.start()
                }
        }
    }
}

struct ContentView: View {
    @ObservedObject var engine: InferenceEngine
    @ObservedObject var server: LocalServer

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Status header
                VStack(spacing: 8) {
                    Text("MARGINALIA")
                        .font(.system(size: 28, weight: .ultraLight))
                        .tracking(8)

                    Text("On-Device Voice Intelligence")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)

                Divider()

                // Model status
                GroupBox("Inference Engine") {
                    VStack(alignment: .leading, spacing: 8) {
                        StatusRow(label: "STT Model", status: engine.sttLoaded ? "Ready" : engine.loading ? "Loading..." : "Not loaded", ok: engine.sttLoaded)
                        StatusRow(label: "LLM Model", status: engine.llmLoaded ? "Ready" : engine.loading ? "Loading..." : "Not loaded", ok: engine.llmLoaded)
                        StatusRow(label: "RAM", status: engine.ramUsage, ok: true)
                    }
                    .padding(.vertical, 4)
                }

                // Server status
                GroupBox("Local Server") {
                    VStack(alignment: .leading, spacing: 8) {
                        StatusRow(label: "HTTP", status: server.running ? "http://localhost:\(server.port)" : "Stopped", ok: server.running)
                        StatusRow(label: "Glasses App", status: server.running ? "http://localhost:\(server.port)/glasses/" : "—", ok: server.running)
                        StatusRow(label: "Calendar", status: server.running ? "http://localhost:\(server.port)/static/calendar.html" : "—", ok: server.running)
                    }
                    .padding(.vertical, 4)
                }

                // Recent activity
                GroupBox("Activity") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(engine.logs.suffix(20).reversed(), id: \.self) { log in
                                Text(log)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }

                Spacer()

                // Manual test button
                Button("Test Inference (Dummy)") {
                    Task { await engine.testInference() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!engine.llmLoaded && !engine.dummyMode)
            }
            .padding()
            .navigationTitle("")
        }
    }
}

struct StatusRow: View {
    let label: String
    let status: String
    let ok: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(status)
                .font(.caption2.monospaced())
                .foregroundColor(.primary)
            Spacer()
        }
    }
}
