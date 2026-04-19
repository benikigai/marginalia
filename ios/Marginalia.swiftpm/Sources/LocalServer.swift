import Foundation
import Swifter
import Combine

/// Lightweight HTTP server running on iPhone localhost.
/// Serves the glasses web app and handles inference/tool-call API requests.
/// The Even Realities app WebView loads http://localhost:{port}/glasses/
@MainActor
class LocalServer: ObservableObject {
    @Published var running = false
    let port: UInt16 = 8080

    var engine: InferenceEngine?
    private var httpServer: HttpServer?
    private var calendarEvents: [[String: Any]] = []
    private var sseConnections: [HttpResponseBodyWriter] = []

    func start() {
        let server = HttpServer()

        // ── Health ──────────────────────────────────────────
        server.GET["/health"] = { [weak self] _ in
            let response: [String: Any] = [
                "status": "ok",
                "model_loaded": self?.engine?.llmLoaded ?? false,
                "stt_loaded": self?.engine?.sttLoaded ?? false,
                "dummy_mode": self?.engine?.dummyMode ?? true,
                "platform": "iPhone",
                "calendar_events": self?.calendarEvents.count ?? 0,
            ]
            return .ok(.json(response))
        }

        // ── Inference (base64 audio JSON) ──────────────────
        server.POST["/inference-json"] = { [weak self] request in
            guard let self = self, let engine = self.engine else {
                return .internalServerError
            }

            guard let body = self.parseJsonBody(request),
                  let audioB64 = body["audio"] as? String,
                  let audioData = Data(base64Encoded: audioB64) else {
                return .badRequest(.text("Missing or invalid 'audio' field"))
            }

            engine.log("Received \(audioData.count) bytes of audio")

            let result = await engine.processAudio(pcmData: audioData)
            return .ok(.json(result))
        }

        // ── Inference (text only — MacBook mic fallback) ───
        server.POST["/inference-text"] = { [weak self] request in
            guard let self = self, let engine = self.engine else {
                return .internalServerError
            }

            guard let body = self.parseJsonBody(request),
                  let text = body["text"] as? String, !text.isEmpty else {
                return .badRequest(.text("Missing 'text' field"))
            }

            engine.log("Text inference: \"\(text.prefix(80))\"")
            let result = await engine.generateOptions(text: text)
            return .ok(.json(result))
        }

        // ── Tool Call ──────────────────────────────────────
        server.POST["/tool-call-json"] = { [weak self] request in
            guard let self = self else { return .internalServerError }

            guard let body = self.parseJsonBody(request),
                  let toolName = (body["tool"] ?? body["tool_name"] ?? body["action"]) as? String else {
                return .badRequest(.text("Missing tool name"))
            }

            let args = body["args"] as? [String: Any] ?? [:]
            let result = self.executeTool(name: toolName, args: args)
            return .ok(.json(result))
        }

        // ── Calendar Events (REST) ─────────────────────────
        server.GET["/events"] = { [weak self] _ in
            return .ok(.json(["events": self?.calendarEvents ?? []]))
        }

        // ── SSE Stream ─────────────────────────────────────
        server.GET["/events-stream"] = { [weak self] request in
            return .raw(200, "text/event-stream", [
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
            ]) { writer in
                self?.sseConnections.append(writer)
                // Keep connection open — Swifter handles lifecycle
                // SSE events are pushed via broadcastSSE()
                while true {
                    Thread.sleep(forTimeInterval: 30)
                    // Keepalive comment
                    try? writer.write(Data(": keepalive\n\n".utf8))
                }
            }
        }

        // ── Serve glasses web app (built Vite output) ──────
        // The built glasses app should be in the app bundle at GlassesApp/
        if let glassesPath = Bundle.main.path(forResource: "GlassesApp", ofType: nil) {
            server.GET["/glasses/:path"] = directoryBrowser(glassesPath)
            server.GET["/glasses"] = { _ in
                if let indexPath = Bundle.main.path(forResource: "GlassesApp/index.html", ofType: nil),
                   let data = FileManager.default.contents(atPath: indexPath) {
                    return .ok(.data(data, contentType: "text/html"))
                }
                return .notFound
            }
        }

        // ── Serve static files (calendar page) ─────────────
        if let staticPath = Bundle.main.path(forResource: "GlassesApp/static", ofType: nil) {
            server.GET["/static/:path"] = directoryBrowser(staticPath)
        }

        // ── CORS headers for all responses ─────────────────
        // Swifter doesn't have middleware, so we handle CORS via OPTIONS
        server.OPTIONS["/*"] = { _ in
            return .raw(204, "No Content", [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type",
            ], { _ in })
        }

        // Start server
        do {
            try server.start(port, forceIPv4: true)
            httpServer = server
            running = true
            engine?.log("HTTP server started on http://localhost:\(port)")
            engine?.log("Glasses app: http://localhost:\(port)/glasses/?server=localhost:\(port)")
        } catch {
            engine?.log("Server start failed: \(error)")
        }
    }

    // MARK: - Tool Execution

    private func executeTool(name: String, args: [String: Any]) -> [String: Any] {
        engine?.log("Tool call: \(name)(\(args))")

        if name == "createCalendarHold" {
            let event: [String: Any] = [
                "id": calendarEvents.count + 1,
                "title": args["title"] as? String ?? "Untitled",
                "startDate": args["startDate"] as? String ?? "",
                "endDate": args["endDate"] as? String ?? "",
                "createdAt": ISO8601DateFormatter().string(from: Date()),
            ]
            calendarEvents.append(event)
            engine?.log("Calendar event created: \(event)")

            // Broadcast to SSE
            broadcastSSE(["type": "tool_executed", "tool": name, "result": ["status": "created", "event": event]])

            return ["status": "created", "event": event]
        }

        return ["status": "error", "message": "Unknown tool: \(name)"]
    }

    // MARK: - SSE

    private func broadcastSSE(_ event: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let sseMessage = Data("data: \(jsonStr)\n\n".utf8)
        sseConnections = sseConnections.filter { writer in
            do {
                try writer.write(sseMessage)
                return true
            } catch {
                return false // Remove dead connections
            }
        }
    }

    // MARK: - Helpers

    private func parseJsonBody(_ request: HttpRequest) -> [String: Any]? {
        let bodyData = Data(request.body)
        return try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    }

    func stop() {
        httpServer?.stop()
        running = false
    }
}

// MARK: - JSON Response Extension
extension HttpResponse {
    static func json(_ obj: Any) -> HttpResponse {
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let str = String(data: data, encoding: .utf8) {
            return .ok(.text(str))
        }
        return .internalServerError
    }
}
