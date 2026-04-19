import Foundation
import Network

/// Lightweight HTTP server using NWListener (no third-party dependencies).
/// Serves the glasses web app + inference API on localhost:8080.
@MainActor
class LocalServer: ObservableObject {
    @Published var isRunning = false
    var engine: InferenceEngine?

    private var listener: NWListener?
    private let port: UInt16 = 8080
    private let queue = DispatchQueue(label: "marginalia.server", qos: .userInitiated)

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("[Server] Failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isRunning = true
                    print("[Server] Listening on port \(self?.port ?? 0)")
                case .failed(let error):
                    self?.isRunning = false
                    print("[Server] Failed: \(error)")
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        isRunning = false
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }

            guard let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            self.route(request: request, rawData: data, connection: connection)
        }
    }

    private func route(request: String, rawData: Data, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendResponse(connection: connection, status: 400, body: #"{"error":"Bad request"}"#)
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: 400, body: #"{"error":"Bad request"}"#)
            return
        }

        let method = parts[0]
        let path = parts[1].components(separatedBy: "?").first ?? parts[1]

        print("[Server] \(method) \(path)")

        switch (method, path) {
        case ("GET", "/health"):
            handleHealth(connection: connection)

        case ("GET", "/events"):
            handleEvents(connection: connection)

        case ("POST", "/inference"):
            handleInference(request: request, rawData: rawData, connection: connection)

        case ("POST", "/tool-call-json"):
            handleToolCall(request: request, rawData: rawData, connection: connection)

        case ("GET", "/"):
            serveStaticFile("index.html", contentType: "text/html", connection: connection)

        case ("GET", _) where path.hasSuffix(".js"):
            serveStaticFile(String(path.dropFirst()), contentType: "application/javascript", connection: connection)

        case ("GET", _) where path.hasSuffix(".css"):
            serveStaticFile(String(path.dropFirst()), contentType: "text/css", connection: connection)

        case ("OPTIONS", _):
            sendResponse(connection: connection, status: 200, body: "", extraHeaders: corsHeaders())

        default:
            sendResponse(connection: connection, status: 404, body: #"{"error":"Not found"}"#)
        }
    }

    private func handleHealth(connection: NWConnection) {
        let engineReady = engine != nil
        let body = """
        {"status":"ok","model_loaded":\(engineReady),"server":"ios"}
        """
        sendResponse(connection: connection, status: 200, body: body)
    }

    private func handleEvents(connection: NWConnection) {
        guard let engine = engine else {
            sendResponse(connection: connection, status: 200, body: #"{"events":[]}"#)
            return
        }

        DispatchQueue.main.sync {
            let events = engine.calendarEvents.enumerated().map { i, e in
                #"{"id":\#(i+1),"title":"\#(e.title)","startDate":"\#(e.startDate)","endDate":"\#(e.endDate)"}"#
            }
            let body = #"{"events":[\#(events.joined(separator: ","))]}"#
            self.sendResponse(connection: connection, status: 200, body: body)
        }
    }

    private func handleInference(request: String, rawData: Data, connection: NWConnection) {
        // Extract body from HTTP request
        let bodyData = extractBody(from: rawData)

        Task { @MainActor in
            guard let engine = self.engine else {
                self.sendResponse(connection: connection, status: 503, body: #"{"error":"Engine not ready"}"#)
                return
            }

            let result = await engine.runInference(audioData: bodyData ?? Data())

            if let jsonData = try? JSONSerialization.data(withJSONObject: result),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: jsonStr)
            } else {
                self.sendResponse(connection: connection, status: 500, body: #"{"error":"Serialization failed"}"#)
            }
        }
    }

    private func handleToolCall(request: String, rawData: Data, connection: NWConnection) {
        guard let bodyData = extractBody(from: rawData),
              let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let toolName = (body["tool_name"] as? String) ?? (body["action"] as? String) else {
            sendResponse(connection: connection, status: 400, body: #"{"error":"Missing tool_name/action"}"#)
            return
        }

        let args = body["args"] as? [String: String] ?? [:]

        DispatchQueue.main.async {
            guard let engine = self.engine else {
                self.sendResponse(connection: connection, status: 503, body: #"{"error":"Engine not ready"}"#)
                return
            }

            let result = engine.executeTool(name: toolName, args: args)
            if let jsonData = try? JSONSerialization.data(withJSONObject: result),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: jsonStr)
            }
        }
    }

    private func serveStaticFile(_ filename: String, contentType: String, connection: NWConnection) {
        if let path = Bundle.main.path(forResource: filename, ofType: nil, inDirectory: "WebApp"),
           let data = FileManager.default.contents(atPath: path) {
            let header = """
            HTTP/1.1 200 OK\r
            Content-Type: \(contentType)\r
            Content-Length: \(data.count)\r
            \(corsHeaders())\r
            Connection: close\r
            \r

            """
            var response = header.data(using: .utf8)!
            response.append(data)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            sendResponse(connection: connection, status: 404, body: #"{"error":"File not found: \#(filename)"}"#)
        }
    }

    private func extractBody(from data: Data) -> Data? {
        guard let str = String(data: data, encoding: .utf8),
              let range = str.range(of: "\r\n\r\n") else { return nil }
        let bodyStart = str.distance(from: str.startIndex, to: range.upperBound)
        guard bodyStart < data.count else { return nil }
        return data.subdata(in: bodyStart..<data.count)
    }

    private func corsHeaders() -> String {
        return """
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type
        """
    }

    private func sendResponse(connection: NWConnection, status: Int, body: String, extraHeaders: String = "") {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        case 503: statusText = "Service Unavailable"
        default: statusText = "Unknown"
        }

        let response = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        \(corsHeaders())\r
        \(extraHeaders)\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
