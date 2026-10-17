import CryptoKit
import Foundation
import FaciendaCore

/// Reviewed Hugging Face snapshots. A new revision gets its own cache, including its tokenizer.
enum SpeechModelSnapshot {
    static let variant = "large-v3-v20240930_turbo_632MB"
    static let modelName = "openai_whisper-" + variant
    static let model = Source(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482")
    static let tokenizer = Source(repository: "openai/whisper-large-v3", revision: "06f233fe06e710322aca913c1bc4249a0d71fce1")
    static let storage = LibraryHome.supportDirectory.appending(path: "Speech/\(model.revision)-\(tokenizer.revision)", directoryHint: .isDirectory)
    static let modelFolder = storage.appending(path: modelName, directoryHint: .isDirectory)
    static let readyKey = "whisperModelFolder"

    static func isReady(defaults: UserDefaults = .standard, folder: URL = modelFolder) -> Bool {
        guard defaults.string(forKey: readyKey) == folder.path else { return false }
        return ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc", "config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        } && ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appending(path: $0).path)
        }
    }

    struct Source: Sendable {
        let repository: String
        let revision: String

        func treeURL(under folder: String?) -> URL {
            var url = URL(string: "https://huggingface.co/api/models/\(repository)/tree/\(revision)")!
            if let folder { url.append(path: folder) }
            return url.appending(queryItems: [URLQueryItem(name: "recursive", value: "true")])
        }

        func url(for file: File) -> URL {
            URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)")!.appending(path: file.path)
        }
    }

    struct File: Decodable, Sendable {
        struct LFS: Decodable, Sendable { let oid: String }
        let type: String
        let path: String
        let size: Int64
        let oid: String
        let lfs: LFS?

        /// Reject paths that could escape the snapshot when mapped to disk.
        func relativePath(under folder: String?) throws -> String {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard size >= 0, !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !path.contains("\\"), !path.contains("\0"),
                  folder == nil || path.hasPrefix(folder! + "/") else { throw InvalidManifest() }
            return folder.map { String(path.dropFirst($0.count + 1)) } ?? path
        }

        /// The pinned tree carries SHA-256 for LFS files and Git blob SHA-1 for ordinary files.
        /// Checking the contents also repairs a corrupt download whose byte count happens to match.
        func matches(_ url: URL) -> Bool {
            guard size >= 0, let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            do {
                guard try handle.seekToEnd() == UInt64(size) else { return false }
                try handle.seek(toOffset: 0)
                var sha256 = SHA256(), sha1 = Insecure.SHA1()
                sha1.update(data: Data("blob \(size)\0".utf8))
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    if lfs != nil { sha256.update(data: chunk) } else { sha1.update(data: chunk) }
                }
                let actual = lfs != nil ? sha256.finalize().map { String(format: "%02x", $0) }.joined()
                    : sha1.finalize().map { String(format: "%02x", $0) }.joined()
                return actual == (lfs?.oid ?? oid)
            } catch { return false }
        }
    }

    struct InvalidManifest: LocalizedError {
        var errorDescription: String? { "The speech model file list is invalid. Try again later." }
    }
}
