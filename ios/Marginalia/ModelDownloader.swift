import Foundation
import Compression

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
    @Published var vadReady = false
    @Published var sttReady = false
    @Published var llmReady = false

    struct ModelSpec {
        let name: String
        let hfRepo: String
        let localDir: String
        /// Preferred ZIP filename substring (e.g. "-int4-apple.zip"). First match wins.
        let zipPattern: String
    }

    static let models: [ModelSpec] = [
        ModelSpec(name: "Silero VAD", hfRepo: "Cactus-Compute/silero-vad",
                  localDir: "silero-vad", zipPattern: "-int4.zip"),
        ModelSpec(name: "Parakeet STT", hfRepo: "Cactus-Compute/parakeet-tdt-0.6b-v3",
                  localDir: "parakeet-tdt-0.6b-v3", zipPattern: "-int4-apple.zip"),
        ModelSpec(name: "Gemma 4 E2B", hfRepo: "Cactus-Compute/gemma-4-E2B-it",
                  localDir: "gemma-4-e2b-it", zipPattern: "-int4-apple.zip"),
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
        // Only report ready if config.txt exists (not just the directory)
        vadReady = fm.fileExists(atPath: weightsDir.appendingPathComponent("silero-vad/config.txt").path)
        sttReady = fm.fileExists(atPath: weightsDir.appendingPathComponent("parakeet-tdt-0.6b-v3/config.txt").path)
        llmReady = fm.fileExists(atPath: weightsDir.appendingPathComponent("gemma-4-e2b-it/config.txt").path)
    }

    func downloadAll() async {
        isDownloading = true
        error = nil

        for model in Self.models {
            let destDir = weightsDir.appendingPathComponent(model.localDir)
            let configPath = destDir.appendingPathComponent("config.txt").path

            if FileManager.default.fileExists(atPath: configPath) {
                print("[Download] \(model.name) already exists with config.txt, skipping")
                continue
            }

            currentModel = model.name
            progress = 0

            do {
                // 1. Find the right ZIP from HuggingFace
                currentFile = "fetching file list..."
                let files = try await listFiles(repo: model.hfRepo)
                let zipFiles = files.filter { $0.hasSuffix(".zip") }

                guard let zipFile = zipFiles.first(where: { $0.contains(model.zipPattern) })
                        ?? zipFiles.first else {
                    throw DownloadError.noZipFound(model.hfRepo)
                }

                let zipName = (zipFile as NSString).lastPathComponent
                print("[Download] \(model.name): downloading \(zipName)")

                // 2. Download the ZIP
                currentFile = zipName
                fileProgress = "downloading..."
                let zipURL = URL(string: "https://huggingface.co/\(model.hfRepo)/resolve/main/\(zipFile)")!
                let tempZip = weightsDir.appendingPathComponent("\(model.localDir).zip")
                try? FileManager.default.removeItem(at: tempZip)

                try await downloadFile(from: zipURL, to: tempZip)
                progress = 0.7

                // 3. Extract the ZIP
                currentFile = "extracting..."
                fileProgress = ""
                try? FileManager.default.removeItem(at: destDir)

                let extractDir = weightsDir.appendingPathComponent("\(model.localDir)-extract")
                try? FileManager.default.removeItem(at: extractDir)
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

                try await extractZip(at: tempZip, to: extractDir)
                progress = 0.9

                // 4. Find config.txt and locate model root
                let extractedConfig = try findFile(named: "config.txt", in: extractDir)
                let modelRoot = extractedConfig.deletingLastPathComponent()

                if modelRoot.path == extractDir.path {
                    // config.txt is at root of extraction — rename to final dest
                    try FileManager.default.moveItem(at: extractDir, to: destDir)
                } else {
                    // config.txt is nested — move the subdirectory
                    try FileManager.default.moveItem(at: modelRoot, to: destDir)
                    try? FileManager.default.removeItem(at: extractDir)
                }

                // Clean up ZIP
                try? FileManager.default.removeItem(at: tempZip)

                // 5. Validate
                guard FileManager.default.fileExists(atPath: destDir.appendingPathComponent("config.txt").path) else {
                    throw DownloadError.configMissing
                }

                progress = 1.0
                print("[Download] \(model.name) complete at \(destDir.path)")
            } catch {
                self.error = "\(model.name): \(error.localizedDescription)"
                print("[Download] \(model.name) failed: \(error)")
                isDownloading = false
                checkExisting()
                return
            }
        }

        checkExisting()
        isDownloading = false
        currentModel = "Done"
        currentFile = ""
    }

    // MARK: - Private

    enum DownloadError: LocalizedError {
        case noZipFound(String)
        case configMissing
        case zipCorrupt(String)

        var errorDescription: String? {
            switch self {
            case .noZipFound(let repo): return "No ZIP weights found in \(repo)"
            case .configMissing: return "Extraction succeeded but config.txt not found"
            case .zipCorrupt(let detail): return "ZIP extraction failed: \(detail)"
            }
        }
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

    /// Extract a ZIP file using a minimal pure-Swift ZIP parser + Apple's Compression framework.
    private func extractZip(at zipPath: URL, to destination: URL) async throws {
        try await Task.detached {
            let data = try Data(contentsOf: zipPath, options: .mappedIfSafe)
            try ZipExtractor.extract(data: data, to: destination)
        }.value
    }

    private func findFile(named filename: String, in directory: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw DownloadError.zipCorrupt("Cannot enumerate \(directory.path)")
        }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == filename {
                return fileURL
            }
        }
        throw DownloadError.zipCorrupt("\(filename) not found after extraction")
    }
}

// MARK: - Minimal ZIP Extractor (no external dependencies)

/// Pure-Swift ZIP extractor using Apple's Compression framework.
/// Handles Store (no compression) and Deflate methods — covers all Cactus weight ZIPs.
private enum ZipExtractor {
    static func extract(data: Data, to destination: URL) throws {
        let fm = FileManager.default
        var offset = 0

        while offset + 4 <= data.count {
            // Local file header signature: PK\x03\x04
            let sig = data.subdata(in: offset..<offset+4)
            guard sig == Data([0x50, 0x4B, 0x03, 0x04]) else {
                break  // No more local file headers (reached central directory or end)
            }

            guard offset + 30 <= data.count else {
                throw ModelDownloader.DownloadError.zipCorrupt("Truncated local header")
            }

            let compressionMethod = data.readUInt16(at: offset + 8)
            let compressedSize = Int(data.readUInt32(at: offset + 18))
            let uncompressedSize = Int(data.readUInt32(at: offset + 22))
            let filenameLen = Int(data.readUInt16(at: offset + 26))
            let extraLen = Int(data.readUInt16(at: offset + 28))

            let filenameStart = offset + 30
            guard filenameStart + filenameLen <= data.count else {
                throw ModelDownloader.DownloadError.zipCorrupt("Truncated filename")
            }

            let filenameData = data.subdata(in: filenameStart..<filenameStart + filenameLen)
            let filename = String(data: filenameData, encoding: .utf8) ?? ""

            let dataStart = filenameStart + filenameLen + extraLen

            // Skip macOS resource fork junk
            if filename.contains("__MACOSX") || filename.hasPrefix("._") {
                offset = dataStart + compressedSize
                continue
            }

            let filePath = destination.appendingPathComponent(filename)

            if filename.hasSuffix("/") {
                // Directory entry
                try fm.createDirectory(at: filePath, withIntermediateDirectories: true)
            } else {
                // File entry
                try fm.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)

                guard dataStart + compressedSize <= data.count else {
                    throw ModelDownloader.DownloadError.zipCorrupt("Truncated file data for \(filename)")
                }

                let compressedData = data.subdata(in: dataStart..<dataStart + compressedSize)

                switch compressionMethod {
                case 0:
                    // Store (no compression)
                    try compressedData.write(to: filePath)
                case 8:
                    // Deflate
                    let decompressed = try decompress(compressedData, expectedSize: uncompressedSize)
                    try decompressed.write(to: filePath)
                default:
                    throw ModelDownloader.DownloadError.zipCorrupt("Unsupported compression method \(compressionMethod) for \(filename)")
                }
            }

            offset = dataStart + compressedSize
        }
    }

    /// Decompress raw-deflate data from a ZIP entry using Apple's Compression streaming API.
    /// ZIP uses raw deflate (RFC 1951), so we prepend a minimal zlib header to satisfy
    /// Apple's COMPRESSION_ZLIB which expects zlib-wrapped data.
    private static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
        // Prepend minimal zlib header (CM=8/deflate, CINFO=7/32K window, no dict, FCHECK=1)
        var zlibWrapped = Data([0x78, 0x01])
        zlibWrapped.append(input)

        let outputSize = max(expectedSize, input.count * 4)
        var output = Data(count: outputSize)

        let decodedSize = output.withUnsafeMutableBytes { outputPtr in
            zlibWrapped.withUnsafeBytes { inputPtr in
                compression_decode_buffer(
                    outputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    outputSize,
                    inputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    zlibWrapped.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedSize > 0 else {
            throw ModelDownloader.DownloadError.zipCorrupt("Decompression failed")
        }

        return output.prefix(decodedSize)
    }
}

// MARK: - Data helpers for reading little-endian integers

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { ptr in
            self.copyBytes(to: ptr, from: offset..<offset+2)
        }
        return UInt16(littleEndian: value)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { ptr in
            self.copyBytes(to: ptr, from: offset..<offset+4)
        }
        return UInt32(littleEndian: value)
    }
}
