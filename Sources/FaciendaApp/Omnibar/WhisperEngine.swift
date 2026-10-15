import Foundation
import WhisperKit

/// Whisper on this Mac: the model is downloaded once, then loaded on first use and kept warm.
/// Calls are serialized; Whisper is not safe to run twice at once.
actor WhisperEngine {
    static let shared = WhisperEngine()
    /// Large v3 turbo, quantized: close to the full model's accuracy at a third of the size.
    static let variant = "large-v3-v20240930_turbo_632MB"
    static let sampleRate = 16_000

    private nonisolated(unsafe) var kit: WhisperKit?
    private var loading: Task<Void, Error>?

    private static var storage: URL {
        URL.applicationSupportDirectory.appending(path: "Facienda/Speech", directoryHint: .isDirectory)
    }
    private static let readyKey = "whisperModelFolder"

    /// The downloaded model, if a download finished before.
    private static var modelFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: readyKey),
              FileManager.default.fileExists(atPath: URL(filePath: path).appending(path: "AudioEncoder.mlmodelc").path) else { return nil }
        return URL(filePath: path)
    }
    nonisolated static var isDownloaded: Bool { modelFolder != nil }

    /// Downloads the model and its tokenizer if needed, one file at a time. Progress runs from 0 to 1.
    /// Files already complete from an earlier attempt are kept.
    /// (WhisperKit's own downloader fails on the model's nested folders.)
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard Self.modelFolder == nil else { return }
        let modelName = "openai_whisper-" + Self.variant
        let folder = Self.storage.appending(path: "models/argmaxinc/whisperkit-coreml/" + modelName, directoryHint: .isDirectory)
        var files = try await Self.files(in: "argmaxinc/whisperkit-coreml", under: modelName).map { file in
            (file, folder.appending(path: String(file.path.dropFirst(modelName.count + 1))))
        }
        files += try await Self.files(in: "openai/whisper-large-v3", under: nil)
            .filter { ["tokenizer.json", "tokenizer_config.json"].contains($0.path) }
            .map { ($0, Self.storage.appending(path: $0.path)) }
        let total = max(files.reduce(0) { $0 + $1.0.size }, 1)
        func missing() -> [(RemoteFile, URL)] {
            files.filter { file, destination in
                (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) != file.size
            }
        }
        // Each pass fetches what is not complete yet, then checks everything again.
        for _ in 0..<3 {
            let needed = missing()
            if needed.isEmpty { break }
            var done = total - needed.reduce(0) { $0 + $1.0.size }
            for (file, destination) in needed {
                let before = done
                try await Self.fetch(file.url, to: destination) { received in progress(Double(before + received) / Double(total)) }
                done += file.size
                progress(Double(done) / Double(total))
            }
        }
        guard missing().isEmpty else { throw DownloadFailed() }
        UserDefaults.standard.set(folder.path, forKey: Self.readyKey)
    }

    private struct RemoteFile: Decodable {
        let type: String
        let path: String
        let size: Int64
        var repo = ""
        var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)")! }
        private enum CodingKeys: String, CodingKey { case type, path, size }
    }

    /// The files of a Hugging Face model repository, below a folder or at its top.
    private static func files(in repo: String, under folder: String?) async throws -> [RemoteFile] {
        var address = "https://huggingface.co/api/models/\(repo)/tree/main"
        if let folder { address += "/\(folder)?recursive=true" }
        let (data, response) = try await URLSession.shared.data(from: URL(string: address)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadFailed() }
        return try JSONDecoder().decode([RemoteFile].self, from: data).filter { $0.type == "file" }.map { var file = $0; file.repo = repo; return file }
    }

    /// Downloads one file into place, reporting bytes received as it goes.
    private static func fetch(_ url: URL, to destination: URL, received: @escaping @Sendable (Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outcome = DownloadOutcome()
        let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
            outcome.finish {
                if let error { throw error }
                guard let temporary, (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadFailed() }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        }
        task.resume()
        while !outcome.isDone {
            received(task.countOfBytesReceived)
            do { try await Task.sleep(for: .milliseconds(250)) } catch { task.cancel(); throw error }
        }
        try outcome.check()
    }

    /// Loads the model into memory. The first load after an OS update can take a minute while Core ML compiles it.
    func load() async throws {
        if kit != nil { return }
        if let loading { return try await loading.value }
        guard let folder = Self.modelFolder else { throw WhisperUnavailable() }
        let task = Task {
            let config = WhisperKitConfig(model: Self.variant, modelFolder: folder.path, tokenizerFolder: Self.storage,
                                          verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
            let kit = try await WhisperKit(config)
            try await kit.loadTokenizerIfNeeded()
            self.kit = kit
        }
        loading = task
        defer { loading = nil }
        do { try await task.value } catch {
            // Damaged files: the next start checks every file again and fetches what is wrong.
            UserDefaults.standard.removeObject(forKey: Self.readyKey)
            throw error
        }
    }

    /// Transcribes 16 kHz mono samples. `language` is a code such as "en", or nil to detect it.
    /// `prompt` primes Whisper with names and words it would otherwise guess at.
    func transcribe(_ samples: [Float], language: String?, prompt: String) async throws -> String {
        try await load()
        guard let kit else { throw WhisperUnavailable() }
        var promptTokens: [Int]?
        if let tokenizer = kit.tokenizer, !prompt.isEmpty {
            let tokens = tokenizer.encode(text: " " + prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            promptTokens = Array(tokens.suffix(120))
        }
        let options = DecodingOptions(task: .transcribe, language: language, temperatureFallbackCount: 2,
                                      usePrefillPrompt: true, detectLanguage: language == nil,
                                      skipSpecialTokens: true, withoutTimestamps: true, promptTokens: promptTokens)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The end of a download, set from URLSession's queue and read by the waiting task.
private final class DownloadOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var failure: Error?

    var isDone: Bool { lock.withLock { done } }

    func finish(_ work: () throws -> Void) {
        let error: Error?
        do { try work(); error = nil } catch let caught { error = caught }
        lock.withLock { failure = error; done = true }
    }

    func check() throws { if let failure = lock.withLock({ failure }) { throw failure } }
}

struct DownloadFailed: LocalizedError {
    var errorDescription: String? { "The speech model could not be downloaded. Check your connection and try again." }
}

struct WhisperUnavailable: LocalizedError {
    var errorDescription: String? { "The speech model is not ready yet." }
}
