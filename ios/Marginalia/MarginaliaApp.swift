import SwiftUI

@main
struct MarginaliaApp: App {
    @StateObject private var engine = InferenceEngine()
    @StateObject private var server = LocalServer()
    @StateObject private var downloader = ModelDownloader()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine, server: server, downloader: downloader)
                .onAppear {
                    server.engine = engine
                    if downloader.llmReady {
                        Task {
                            await engine.loadModels()
                            server.start()
                        }
                    }
                }
                .onChange(of: downloader.llmReady) { ready in
                    if ready {
                        Task {
                            await engine.loadModels()
                            server.start()
                        }
                    }
                }
        }
    }
}
