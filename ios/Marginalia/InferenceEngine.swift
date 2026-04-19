import Foundation
import Combine

struct ResponseOption: Codable {
    let label: String
    let action: String?
    let args: [String: String]?
}

struct InferenceStats {
    let sttMs: Int
    let llmMs: Int
    let totalMs: Int
}

struct CalendarEvent {
    let title: String
    let startDate: String
    let endDate: String
}

@MainActor
class InferenceEngine: ObservableObject {
    @Published var vadStatus = "Not loaded"
    @Published var sttStatus = "Not loaded"
    @Published var llmStatus = "Not loaded"
    @Published var displayText = "Listening..."
    @Published var lastOptions: [ResponseOption]?
    @Published var lastStats: InferenceStats?
    @Published var calendarEvents: [CalendarEvent] = []

    private var vadModel: UnsafeMutableRawPointer?
    private var sttModel: UnsafeMutableRawPointer?
    private var llmModel: UnsafeMutableRawPointer?
    private var dummyMode = false

    /// Cloud handoff: if on-device confidence drops below this, Cactus routes to cloud.
    /// Set to 0 to disable (pure on-device for demo). Set to 0.8 for production.
    var cloudHandoffThreshold: Double = 0.0
    @Published var lastConfidence: Double?
    @Published var usedCloudHandoff = false

    private let systemPrompt = """
    You are Marginalia, a private real-time commentary layer for high-stakes \
    conversations. You listen to what the other person just said and produce \
    exactly 3 tactical response options for the wearer.

    Rules:
    - Return ONLY valid JSON, no markdown, no explanation.
    - The JSON schema is: {"options": [<option>, <option>, <option>]}
    - Each option has: "label" (short, ≤40 chars), "action" (tool name or null), "args" (object or null)
    - Available tools: createCalendarHold(title, startDate, endDate)
    - First option should be the most direct/affirmative response.
    - Second option should be an alternative or counter.
    - Third option should be a deferral or conservative choice.

    Context: Manager in executive 1:1. Direct report discussing workload/time off.
    """

    private let dummyResponse: [ResponseOption] = [
        ResponseOption(label: "Approve \u{2014} block Mar 10-14", action: "createCalendarHold",
                      args: ["title": "PTO - Direct Report", "startDate": "2026-03-10", "endDate": "2026-03-14"]),
        ResponseOption(label: "Counter \u{2014} ask about workload", action: nil, args: nil),
        ResponseOption(label: "Defer \u{2014} send calendar hold", action: "createCalendarHold",
                      args: ["title": "Follow-up: PTO", "startDate": "2026-03-10", "endDate": "2026-03-10"]),
    ]

    private let tools = """
    [{"name":"createCalendarHold","description":"Create a calendar hold/event","parameters":{"type":"object","properties":{"title":{"type":"string"},"startDate":{"type":"string"},"endDate":{"type":"string"}},"required":["title","startDate","endDate"]}}]
    """

    func loadModels() async {
        let weightsDir = Self.weightsDirectory()
        let vadPath = weightsDir.appendingPathComponent("silero-vad").path
        let sttPath = weightsDir.appendingPathComponent("parakeet-tdt-0.6b-v3").path
        let llmPath = weightsDir.appendingPathComponent("gemma-4-e2b-it").path

        // Load VAD model (small, fast)
        vadStatus = "Loading..."
        if FileManager.default.fileExists(atPath: vadPath) {
            do {
                vadModel = try cactusInit(vadPath, nil, false)
                vadStatus = "Ready"
                print("[Marginalia] VAD model loaded")
            } catch {
                vadStatus = "Error: \(error.localizedDescription)"
                print("[Marginalia] VAD load failed: \(error)")
            }
        } else {
            vadStatus = "Not available"
            print("[Marginalia] VAD weights not found — using fixed buffer")
        }

        // Load STT model
        sttStatus = "Loading..."
        if FileManager.default.fileExists(atPath: sttPath) {
            do {
                sttModel = try cactusInit(sttPath, nil, false)
                sttStatus = "Ready"
                print("[Marginalia] STT model loaded from \(sttPath)")
            } catch {
                sttStatus = "Error: \(error.localizedDescription)"
                print("[Marginalia] STT load failed: \(error)")
            }
        } else {
            sttStatus = "Weights missing"
            print("[Marginalia] STT weights not found at \(sttPath)")
        }

        // Load LLM model
        llmStatus = "Loading..."
        if FileManager.default.fileExists(atPath: llmPath) {
            do {
                llmModel = try cactusInit(llmPath, nil, false)
                llmStatus = "Ready"
                print("[Marginalia] LLM model loaded from \(llmPath)")

                // Warm the model
                llmStatus = "Warming..."
                let warmMsg = #"[{"role":"user","content":"Hi"}]"#
                let _ = try? cactusComplete(llmModel!, warmMsg, #"{"max_tokens":1}"#, nil, nil)
                llmStatus = "Ready"
                print("[Marginalia] LLM warm done")
            } catch {
                llmStatus = "Error: \(error.localizedDescription)"
                print("[Marginalia] LLM load failed: \(error)")
            }
        } else {
            llmStatus = "Weights missing"
            print("[Marginalia] LLM weights not found at \(llmPath)")
            dummyMode = true
            llmStatus = "Dummy mode"
        }
    }

    /// Run VAD on a chunk of audio. Returns true if speech ended (silence detected after speech).
    func detectSpeechEnd(pcmData: Data) -> Bool {
        guard let vadModel = vadModel else { return false }
        do {
            let resultJson = try cactusVad(vadModel, nil, nil, pcmData)
            if let data = resultJson.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let segments = obj["segments"] as? [[String: Any]] {
                // VAD returns speech segments. If we had speech and now don't, speech ended.
                let hasSpeech = !segments.isEmpty
                if hasSpeech {
                    let lastEnd = segments.last?["end"] as? Double ?? 0
                    let audioLengthSec = Double(pcmData.count) / (16000.0 * 2.0) // 16kHz 16-bit
                    // Speech ended if last segment ends >0.5s before audio end
                    return (audioLengthSec - lastEnd) > 0.5
                }
            }
        } catch {
            print("[Marginalia] VAD error: \(error)")
        }
        return false
    }

    func runInference(audioData: Data) async -> [String: Any] {
        let t0 = Date()

        if dummyMode || llmModel == nil {
            let options = dummyResponse.map { opt -> [String: Any?] in
                ["label": opt.label, "action": opt.action, "args": opt.args]
            }
            lastOptions = dummyResponse
            displayText = "3 options ready"
            return ["options": options]
        }

        var sttMs = 0
        var transcript = ""

        // Step 1: STT with Parakeet
        if let sttModel = sttModel {
            let sttStart = Date()
            do {
                let resultJson = try cactusTranscribe(sttModel, nil, nil, nil, nil, audioData)
                sttMs = Int(Date().timeIntervalSince(sttStart) * 1000)
                if let data = resultJson.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let response = obj["response"] as? String {
                    transcript = response
                } else {
                    transcript = resultJson
                }
                print("[Marginalia] STT (\(sttMs)ms): \(transcript)")
            } catch {
                print("[Marginalia] STT failed: \(error), using fallback")
                transcript = "I've been feeling burned out. I think I need to take next week off."
            }
        } else {
            transcript = "I've been feeling burned out. I think I need to take next week off."
        }

        // Step 2: LLM completion
        let llmStart = Date()
        let messages = """
        [{"role":"system","content":"\(systemPrompt.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n"))"},{"role":"user","content":"The other person just said: \\"\(transcript.replacingOccurrences(of: "\"", with: "\\\""))\\" — provide 3 tactical response options."}]
        """

        // Cloud handoff: set confidence_threshold so Cactus can route to cloud if needed
        let optionsDict: [String: Any] = cloudHandoffThreshold > 0
            ? ["max_tokens": 512, "confidence_threshold": cloudHandoffThreshold]
            : ["max_tokens": 512]
        let optionsJson = String(data: try! JSONSerialization.data(withJSONObject: optionsDict), encoding: .utf8)!

        do {
            cactusReset(llmModel!)
            let raw = try cactusComplete(llmModel!, messages, optionsJson, tools, nil)
            let llmMs = Int(Date().timeIntervalSince(llmStart) * 1000)
            let totalMs = Int(Date().timeIntervalSince(t0) * 1000)

            print("[Marginalia] LLM (\(llmMs)ms): \(String(raw.prefix(300)))")

            // Parse envelope for confidence and cloud_handoff
            if let data = raw.data(using: .utf8),
               let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                lastConfidence = envelope["confidence"] as? Double
                usedCloudHandoff = envelope["cloud_handoff"] as? Bool ?? false
                if usedCloudHandoff {
                    print("[Marginalia] Cloud handoff triggered (confidence: \(lastConfidence ?? 0))")
                }
            }

            let parsed = parseResponse(raw)
            lastOptions = parsed
            lastStats = InferenceStats(sttMs: sttMs, llmMs: llmMs, totalMs: totalMs)
            displayText = "3 options ready"

            let optionDicts = parsed.map { opt -> [String: Any?] in
                ["label": opt.label, "action": opt.action, "args": opt.args]
            }
            return [
                "options": optionDicts,
                "transcript": transcript,
                "inference_time_ms": totalMs,
                "confidence": lastConfidence as Any,
                "cloud_handoff": usedCloudHandoff,
            ]
        } catch {
            print("[Marginalia] LLM failed: \(error)")
            lastOptions = dummyResponse
            let optionDicts = dummyResponse.map { opt -> [String: Any?] in
                ["label": opt.label, "action": opt.action, "args": opt.args]
            }
            return ["options": optionDicts, "fallback": true]
        }
    }

    func executeTool(name: String, args: [String: String]) -> [String: Any] {
        if name == "createCalendarHold" {
            let event = CalendarEvent(
                title: args["title"] ?? "Untitled",
                startDate: args["startDate"] ?? "",
                endDate: args["endDate"] ?? ""
            )
            calendarEvents.append(event)
            return [
                "status": "created",
                "event": [
                    "id": calendarEvents.count,
                    "title": event.title,
                    "startDate": event.startDate,
                    "endDate": event.endDate,
                ]
            ]
        }
        return ["status": "error", "message": "Unknown tool: \(name)"]
    }

    private func parseResponse(_ raw: String) -> [ResponseOption] {
        // Unwrap Cactus envelope
        var text = raw
        if let data = raw.data(using: .utf8),
           let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let response = envelope["response"] as? String {
            text = response
        }

        // Strip markdown fences
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            let lines = text.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            text = lines.joined(separator: "\n")
        }

        // Find JSON object
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            return dummyResponse
        }

        let jsonStr = String(text[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let optionsArray = obj["options"] as? [[String: Any]] else {
            return dummyResponse
        }

        return optionsArray.prefix(3).map { opt in
            ResponseOption(
                label: opt["label"] as? String ?? "Option",
                action: opt["action"] as? String,
                args: opt["args"] as? [String: String]
            )
        }
    }

    static func weightsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let weights = docs.appendingPathComponent("weights")
        try? FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        return weights
    }
}
