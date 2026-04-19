import Foundation
import Combine

/// Wraps Cactus SDK for Parakeet STT + Gemma 4 E2B LLM inference.
///
/// Model weights must be pre-loaded into the app's Documents directory:
///   Documents/models/parakeet-tdt-0.6b-v3/
///   Documents/models/gemma-4-e2b-it/
///
/// To pre-load via Xcode: enable "Supports Document Browser" in Info.plist,
/// then drag model folders into the Files app → On My iPhone → Marginalia.
@MainActor
class InferenceEngine: ObservableObject {
    @Published var sttLoaded = false
    @Published var llmLoaded = false
    @Published var loading = false
    @Published var ramUsage = "—"
    @Published var logs: [String] = []
    @Published var dummyMode = false

    private var sttModel: UnsafeMutableRawPointer?
    private var llmModel: UnsafeMutableRawPointer?

    private let documentsDir: String = {
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    }()

    // MARK: - System Prompt

    let systemPrompt = """
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
    - Be context-aware: consider workplace dynamics, urgency, and stakes.

    Context for this session:
    - Role: manager in an executive 1:1
    - Scenario: direct report discussing workload and time off
    - Expected utterance: "I've been feeling burned out. I think I need to take next week off."
    - Guidance: consider workload sustainability, approve if reasonable, defer if HR input needed
    """

    let toolsJson = """
    [{"name":"createCalendarHold","description":"Create a calendar hold/event","parameters":{"type":"object","properties":{"title":{"type":"string"},"startDate":{"type":"string"},"endDate":{"type":"string"}},"required":["title","startDate","endDate"]}}]
    """

    // MARK: - Dummy Response

    static let dummyResponse: [String: Any] = [
        "options": [
            ["label": "Approve — block Apr 21-25", "action": "createCalendarHold",
             "args": ["title": "PTO - Direct Report", "startDate": "2026-04-21", "endDate": "2026-04-25"]],
            ["label": "Counter — ask about workload", "action": NSNull(), "args": NSNull()],
            ["label": "Defer — send calendar hold", "action": "createCalendarHold",
             "args": ["title": "Follow-up: PTO Discussion", "startDate": "2026-04-21", "endDate": "2026-04-21"]],
        ]
    ]

    // MARK: - Model Loading

    func loadModels() async {
        loading = true
        log("Looking for models in \(documentsDir)/models/")

        let sttPath = "\(documentsDir)/models/parakeet-tdt-0.6b-v3"
        let llmPath = "\(documentsDir)/models/gemma-4-e2b-it"

        // Check if models exist
        let fm = FileManager.default
        let sttExists = fm.fileExists(atPath: sttPath)
        let llmExists = fm.fileExists(atPath: llmPath)

        if !sttExists {
            log("WARNING: STT model not found at \(sttPath)")
            log("Copy model weights to Documents/models/ via Files app or Xcode")
        }
        if !llmExists {
            log("WARNING: LLM model not found at \(llmPath)")
            log("Copy model weights to Documents/models/ via Files app or Xcode")
        }

        if !sttExists && !llmExists {
            log("No models found — enabling DUMMY MODE")
            dummyMode = true
            loading = false
            return
        }

        // Load STT model (Parakeet)
        if sttExists {
            await loadModel(path: sttPath, name: "Parakeet STT") { model in
                self.sttModel = model
                self.sttLoaded = true
            }
        }

        // Load LLM model (Gemma 4 E2B)
        if llmExists {
            await loadModel(path: llmPath, name: "Gemma 4 E2B") { model in
                self.llmModel = model
                self.llmLoaded = true
            }
        }

        loading = false
        log("Models loaded. Ready for inference.")
    }

    private func loadModel(path: String, name: String, completion: (UnsafeMutableRawPointer) -> Void) async {
        log("Loading \(name) from \(path)...")
        let t0 = Date()

        // NOTE: cactusInit is from the Cactus Swift SDK (Cactus.swift)
        // You must add Cactus.swift and the cactus XCFramework to the project
        do {
            let model = try cactusInit(path, nil, false)
            let elapsed = Date().timeIntervalSince(t0)
            log("\(name) loaded in \(String(format: "%.1f", elapsed))s")
            completion(model)
        } catch {
            log("ERROR loading \(name): \(error.localizedDescription)")
        }
    }

    // MARK: - Inference

    /// Transcribe audio (PCM S16LE 16kHz mono) to text via Parakeet
    func transcribe(pcmData: Data) async -> String? {
        guard let model = sttModel else {
            log("STT model not loaded")
            return nil
        }

        log("Transcribing \(pcmData.count) bytes of audio...")
        let t0 = Date()

        do {
            let resultJson = try cactusTranscribe(model, nil, nil, nil, nil, pcmData)
            let elapsed = Date().timeIntervalSince(t0)
            log("STT completed in \(String(format: "%.2f", elapsed))s")

            if let data = resultJson.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = obj["response"] as? String {
                log("Transcription: \"\(response)\"")
                return response
            }
        } catch {
            log("STT error: \(error.localizedDescription)")
        }
        return nil
    }

    /// Generate 3 tactical options from text via Gemma 4 E2B
    func generateOptions(text: String) async -> [String: Any] {
        if dummyMode {
            log("DUMMY MODE: returning hardcoded response")
            return Self.dummyResponse
        }

        guard let model = llmModel else {
            log("LLM model not loaded — using dummy response")
            return Self.dummyResponse
        }

        let messages = """
        [{"role":"system","content":\(jsonEscape(systemPrompt))},{"role":"user","content":\(jsonEscape("The other person just said: \\\"" + text + "\\\"\\n\\nProvide 3 tactical response options."))}]
        """

        let options = #"{"max_tokens":512}"#
        log("Running LLM inference...")
        let t0 = Date()

        do {
            cactusReset(model)
            let raw = try cactusComplete(model, messages, options, toolsJson, nil)
            let elapsed = Date().timeIntervalSince(t0)
            log("LLM completed in \(String(format: "%.2f", elapsed))s")

            // Parse Cactus envelope
            if let data = raw.data(using: .utf8),
               let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = envelope["response"] as? String {
                // Parse the model's JSON output
                if let parsed = extractOptionsJson(from: response) {
                    return parsed
                }
            }

            log("Failed to parse LLM response, using dummy")
        } catch {
            log("LLM error: \(error.localizedDescription)")
        }

        return Self.dummyResponse
    }

    /// Full pipeline: audio → STT → LLM → 3 options
    func processAudio(pcmData: Data) async -> [String: Any] {
        // First try direct audio input to Gemma 4 (if NPU mlpackage exists)
        if let model = llmModel, !dummyMode {
            log("Trying direct audio → Gemma 4...")
            let messages = """
            [{"role":"system","content":\(jsonEscape(systemPrompt))},{"role":"user","content":"Listen to this audio and provide 3 tactical response options."}]
            """
            let options = #"{"max_tokens":512}"#
            let t0 = Date()
            do {
                cactusReset(model)
                let raw = try cactusComplete(model, messages, options, toolsJson, nil, pcmData)
                let elapsed = Date().timeIntervalSince(t0)
                log("Direct audio inference in \(String(format: "%.2f", elapsed))s")

                if elapsed < 10.0, // Only use if reasonably fast
                   let data = raw.data(using: .utf8),
                   let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let response = envelope["response"] as? String,
                   let parsed = extractOptionsJson(from: response) {
                    return parsed
                }
                log("Direct audio too slow or failed, falling back to STT pipeline")
            } catch {
                log("Direct audio failed: \(error), using STT pipeline")
            }
        }

        // Fallback: STT → LLM pipeline
        if let text = await transcribe(pcmData: pcmData) {
            return await generateOptions(text: text)
        }

        log("Both audio paths failed — returning dummy")
        return Self.dummyResponse
    }

    func testInference() async {
        log("Running test inference...")
        let result = await generateOptions(text: "I've been feeling burned out. I think I need to take next week off.")
        log("Test result: \(result)")
    }

    // MARK: - Helpers

    private func extractOptionsJson(from raw: String) -> [String: Any]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences
        if text.hasPrefix("```") {
            let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Find JSON object
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        let jsonStr = String(text[start...end])

        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["options"] != nil else { return nil }
        return obj
    }

    private func jsonEscape(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    func log(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(ts)] \(msg)"
        print(entry)
        logs.append(entry)
    }

    deinit {
        if let m = sttModel { cactusDestroy(m) }
        if let m = llmModel { cactusDestroy(m) }
    }
}
