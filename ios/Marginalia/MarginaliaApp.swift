import SwiftUI

@main
struct MarginaliaApp: App {
    @StateObject private var engine = InferenceEngine()
    @StateObject private var server = LocalServer()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine, server: server)
                .onAppear {
                    Task {
                        await engine.loadModels()
                        server.engine = engine
                        server.start()
                    }
                }
        }
    }
}
