import Foundation
import WhisperKit

/// Whisper on this Mac: the model is downloaded once, then loaded on first use and kept warm.
/// Calls are serialized; Whisper is not safe to run twice at once.
actor WhisperEngine {
    static let shared = WhisperEngine()
    /// Large v3 turbo, quantized: close to the full model's accuracy at a third of the size.
    static let variant = SpeechModelSnapshot.variant
    static let sampleRate = 16_000

    private nonisolated(unsafe) var kit: WhisperKit?
    private var loading: Task<Void, Error>?

    private static var storage: URL { SpeechModelSnapshot.storage }
    private static let readyKey = SpeechModelSnapshot.readyKey

    /// The downloaded model, if a download finished before.
    private static var modelFolder: URL? {
        SpeechModelSnapshot.isReady() ? SpeechModelSnapshot.modelFolder : nil
    }
    nonisolated static var isDownloaded: Bool { modelFolder != nil }

    /// Downloads the model and its tokenizer if needed, one file at a time. Progress runs from 0 to 1.
    /// Files already complete from an earlier attempt are kept.
    /// (WhisperKit's own downloader fails on the model's nested folders.)
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard Self.modelFolder == nil else { return }
        let modelName = SpeechModelSnapshot.modelName, folder = SpeechModelSnapshot.modelFolder
        let model = SpeechModelSnapshot.model, tokenizer = SpeechModelSnapshot.tokenizer
        var files = try await Self.files(in: model, under: modelName).map { file in
            (file, model.url(for: file), folder.appending(path: try file.relativePath(under: modelName)))
        }
        files += try await Self.files(in: tokenizer, under: nil)
            .filter { ["tokenizer.json", "tokenizer_config.json"].contains($0.path) }
            .map { ($0, tokenizer.url(for: $0), Self.storage.appending(path: try $0.relativePath(under: nil))) }
        let total = max(files.reduce(0) { $0 + $1.0.size }, 1)
        func missing() -> [(SpeechModelSnapshot.File, URL, URL)] {
            files.filter { file, _, destination in !file.matches(destination) }
        }
        // Each pass fetches what is not complete yet, then checks everything again.
        for _ in 0..<3 {
            let needed = missing()
            if needed.isEmpty { break }
            var done = total - needed.reduce(0) { $0 + $1.0.size }
            for (file, url, destination) in needed {
                let before = done
                try await Self.fetch(url, to: destination) { received in progress(Double(before + received) / Double(total)) }
                done += file.size
                progress(Double(done) / Double(total))
            }
        }
        guard missing().isEmpty else { throw DownloadFailed() }
        UserDefaults.standard.set(folder.path, forKey: Self.readyKey)
        guard Self.modelFolder != nil else {
            UserDefaults.standard.removeObject(forKey: Self.readyKey)
            throw DownloadFailed()
        }
    }

    /// The files of a Hugging Face model repository, below a folder or at its top.
    private static func files(in source: SpeechModelSnapshot.Source, under folder: String?) async throws -> [SpeechModelSnapshot.File] {
        let (data, response) = try await URLSession.shared.data(from: source.treeURL(under: folder))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") != true else { throw DownloadFailed() }
        let files = try JSONDecoder().decode([SpeechModelSnapshot.File].self, from: data).filter { $0.type == "file" }
        guard !files.isEmpty else { throw DownloadFailed() }
        return files
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
