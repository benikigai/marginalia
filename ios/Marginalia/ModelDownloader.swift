import Foundation

struct HFFileInfo: Decodable {
    let rfilename: String
    let size: Int?
}

struct HFSibling: Decodable {
    let rfilename: String
}

struct HFModelInfo: Decodable {
    let siblings: [HFSibling]
}

@MainActor
class ModelDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var currentModel = ""
    @Published var currentFile = ""
    @Published var progress: Double = 0
    @Published var fileProgress: String = ""
    @Published var error: String?
    @Published var sttReady = false
    @Published var llmReady = false

    struct ModelSpec {
        let name: String
        let hfRepo: String
        let localDir: String
        let prefix: String  // only download files starting with this prefix (empty = all)
    }

    static let models: [ModelSpec] = [
        ModelSpec(name: "Parakeet STT", hfRepo: "Cactus-Compute/parakeet-tdt-0.6b-v3",
                  localDir: "parakeet-tdt-0.6b-v3", prefix: ""),
        ModelSpec(name: "Gemma 4 E2B", hfRepo: "Cactus-Compute/gemma-4-E2B-it",
                  localDir: "gemma-4-e2b-it", prefix: ""),
    ]

    let weightsDir: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        weightsDir = docs.appendingPathComponent("weights")
        try? FileManager.default.createDirectory(at: weightsDir, withIntermediateDirectories: true)
        checkExisting()
    }

    func checkExisting() {
        let fm = FileManager.default
        sttReady = fm.fileExists(atPath: weightsDir.appendingPathComponent("parakeet-tdt-0.6b-v3").path)
        llmReady = fm.fileExists(atPath: weightsDir.appendingPathComponent("gemma-4-e2b-it").path)
    }

    func downloadAll() async {
        isDownloading = true
        error = nil

        for (modelIdx, model) in Self.models.enumerated() {
            let destDir = weightsDir.appendingPathComponent(model.localDir)
            if FileManager.default.fileExists(atPath: destDir.path) {
                print("[Download] \(model.name) already exists, skipping")
                continue
            }

            currentModel = model.name
            progress = 0

            do {
                // Get file list from HuggingFace API
                currentFile = "fetching file list..."
                let files = try await listFiles(repo: model.hfRepo)
                let weightFiles = files.filter { f in
                    !f.hasPrefix(".") && f != "README.md" && f != "config.json"
                        && (model.prefix.isEmpty || f.hasPrefix(model.prefix))
                }

                print("[Download] \(model.name): \(weightFiles.count) files")
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

                // Download each file
                for (i, filename) in weightFiles.enumerated() {
                    currentFile = filename
                    fileProgress = "\(i+1)/\(weightFiles.count)"
                    progress = Double(i) / Double(weightFiles.count)

                    let fileURL = URL(string: "https://huggingface.co/\(model.hfRepo)/resolve/main/\(filename)")!
                    let destFile = destDir.appendingPathComponent(filename)

                    // Create subdirectories if needed
                    let destParent = destFile.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: destParent, withIntermediateDirectories: true)

                    if FileManager.default.fileExists(atPath: destFile.path) {
                        continue  // resume support: skip already downloaded files
                    }

                    try await downloadFile(from: fileURL, to: destFile)
                }

                progress = 1.0
                print("[Download] \(model.name) complete")
            } catch {
                self.error = "\(model.name): \(error.localizedDescription)"
                print("[Download] \(model.name) failed: \(error)")
                isDownloading = false
                return
            }
        }

        checkExisting()
        isDownloading = false
        currentModel = "Done"
        currentFile = ""
    }

    private func listFiles(repo: String) async throws -> [String] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let info = try JSONDecoder().decode(HFModelInfo.self, from: data)
        return info.siblings.map(\.rfilename)
    }

    private func downloadFile(from url: URL, to destination: URL) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
}
