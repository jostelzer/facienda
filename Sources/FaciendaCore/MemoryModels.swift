import CoreML
import Foundation

/// The two on-device models behind built-in memory: bge-small for embeddings and a MiniLM cross-encoder for reranking.
/// Both ship in FaciendaCore's resources and are compiled once into the user's caches.
public actor MemoryModels {
    public static let dimensions = 384
    public static let shared = MemoryModels()

    private var loaded: (tokenizer: MemoryTokenizer, embedder: MLModel, reranker: MLModel)?
    private let resources: URL?
    private let cache: URL

    public init(resources: URL? = MemoryModels.resourceFolder(), cache: URL = MemoryModels.defaultCache) {
        self.resources = resources
        self.cache = cache
    }

    /// Unit-length embeddings, one per text.
    public func embed(_ texts: [String]) throws -> [[Float]] {
        let (tokenizer, embedder, _) = try models()
        return try texts.map { text in
            let ids = tokenizer.encode(text)
            let output = try embedder.prediction(from: try Self.features(["input_ids": ids, "attention_mask": ids.map { _ in 1 }]))
            guard let array = output.featureValue(for: "embedding")?.multiArrayValue, array.count == Self.dimensions else {
                throw StoreError.invalid("The memory embedder returned no vector.")
            }
            return Self.floats(array)
        }
    }

    /// The reranker scores fixed batches of pairs, padded to the shortest of these lengths that fits.
    static let rerankBatch = 16
    static let rerankLengths = [64, 128, 256, 512]

    /// Relevance logits for each document against the query; higher is more relevant.
    public func rerank(_ query: String, _ documents: [String]) throws -> [Float] {
        let (tokenizer, _, reranker) = try models()
        let pairs = documents.map { tokenizer.encodePair(query, $0) }
        // Similar lengths share a batch, so little padding is computed.
        let order = pairs.indices.sorted { pairs[$0].ids.count < pairs[$1].ids.count }
        var scores = [Float](repeating: 0, count: documents.count)
        for start in stride(from: 0, to: order.count, by: Self.rerankBatch) {
            let members = Array(order[start..<min(start + Self.rerankBatch, order.count)])
            let longest = members.map { pairs[$0].ids.count }.max() ?? 1
            let length = Self.rerankLengths.first { $0 >= longest } ?? Self.rerankLengths.last!
            let shape = [NSNumber(value: Self.rerankBatch), NSNumber(value: length)]
            let ids = try MLMultiArray(shape: shape, dataType: .int32), mask = try MLMultiArray(shape: shape, dataType: .int32)
            let types = try MLMultiArray(shape: shape, dataType: .int32)
            for array in [ids, mask, types] { memset(array.dataPointer, 0, Self.rerankBatch * length * 4) }
            let idp = ids.dataPointer.bindMemory(to: Int32.self, capacity: Self.rerankBatch * length)
            let maskp = mask.dataPointer.bindMemory(to: Int32.self, capacity: Self.rerankBatch * length)
            let typep = types.dataPointer.bindMemory(to: Int32.self, capacity: Self.rerankBatch * length)
            for (row, member) in members.enumerated() {
                let pair = pairs[member]
                for column in 0..<min(length, pair.ids.count) {
                    idp[row * length + column] = pair.ids[column]; maskp[row * length + column] = 1; typep[row * length + column] = pair.types[column]
                }
            }
            let output = try reranker.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: ids), "attention_mask": MLFeatureValue(multiArray: mask), "token_type_ids": MLFeatureValue(multiArray: types),
            ]))
            guard let array = output.featureValue(for: "score")?.multiArrayValue, array.count >= members.count else {
                throw StoreError.invalid("The memory reranker returned no score.")
            }
            for (row, member) in members.enumerated() { scores[member] = array[row].floatValue }
        }
        return scores
    }

    public func tokenizer() throws -> MemoryTokenizer { try models().tokenizer }

    private func models() throws -> (tokenizer: MemoryTokenizer, embedder: MLModel, reranker: MLModel) {
        if let loaded { return loaded }
        guard let resources else { throw StoreError.invalid("Facienda's memory models are missing from this installation.") }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let tokenizer = try MemoryTokenizer(vocabulary: resources.appendingPathComponent("vocab.txt"))
        let embedder = try MLModel(contentsOf: try compiled("MemoryEmbedder", in: resources), configuration: configuration)
        let reranker = try MLModel(contentsOf: try compiled("MemoryReranker", in: resources), configuration: configuration)
        loaded = (tokenizer, embedder, reranker)
        return (tokenizer, embedder, reranker)
    }

    /// Compiles a shipped `.mlpackage` once per model version. A changed package gets a new cache entry.
    private func compiled(_ name: String, in resources: URL) throws -> URL {
        let package = resources.appendingPathComponent(name + ".mlpackage")
        let fm = FileManager.default
        let stamp = try Self.stamp(package)
        let target = cache.appendingPathComponent("\(name)-\(stamp).mlmodelc")
        if fm.fileExists(atPath: target.path) { return target }
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let built = try MLModel.compileModel(at: package)
        let staging = cache.appendingPathComponent(".\(name)-\(UUID().uuidString).mlmodelc")
        try fm.moveItem(at: built, to: staging)
        do { try fm.moveItem(at: staging, to: target) } catch {
            try? fm.removeItem(at: staging)
            guard fm.fileExists(atPath: target.path) else { throw error }
        }
        for old in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? [] where old.hasPrefix(name + "-") && old != target.lastPathComponent {
            try? fm.removeItem(at: cache.appendingPathComponent(old))
        }
        return target
    }

    private static func stamp(_ package: URL) throws -> String {
        let weights = package.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        let model = package.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
        let sizes = try [weights, model].map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int ?? 0 }
        let modelData = try Data(contentsOf: model)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in modelData { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "\(sizes[0])-\(String(hash, radix: 16))"
    }

    private static func features(_ inputs: [String: [Int32]]) throws -> MLDictionaryFeatureProvider {
        var values: [String: MLFeatureValue] = [:]
        for (name, ids) in inputs {
            let array = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
            ids.withUnsafeBufferPointer { source in
                array.dataPointer.bindMemory(to: Int32.self, capacity: ids.count).update(from: source.baseAddress!, count: ids.count)
            }
            values[name] = MLFeatureValue(multiArray: array)
        }
        return try MLDictionaryFeatureProvider(dictionary: values)
    }

    private static func floats(_ array: MLMultiArray) -> [Float] {
        var vector = (0..<array.count).map { array[$0].floatValue }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { vector = vector.map { $0 / norm } }
        return vector
    }

    public static let defaultCache = LibraryHome.cacheDirectory.appendingPathComponent("MemoryModels", isDirectory: true)

    /// FaciendaCore's resource bundle, wherever this binary runs from: the app, a bundled helper, `swift build` or tests.
    public static func resourceFolder() -> URL? {
        let bundleName = "Facienda_FaciendaCore.bundle"
        let home = Bundle(for: MemoryResourceMarker.self).bundleURL
        var candidates = [home.appendingPathComponent(bundleName), home.deletingLastPathComponent().appendingPathComponent(bundleName)]
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent(bundleName)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath().deletingLastPathComponent()
        candidates += [
            executable.appendingPathComponent(bundleName),
            executable.deletingLastPathComponent().appendingPathComponent("Resources/" + bundleName),
        ]
        for bundle in Bundle.allBundles + Bundle.allFrameworks where bundle.bundleURL.lastPathComponent == bundleName {
            candidates.insert(bundle.bundleURL, at: 0)
        }
        for candidate in candidates {
            for folder in [candidate.appendingPathComponent("Memory"), candidate.appendingPathComponent("Contents/Resources/Memory")]
            where FileManager.default.fileExists(atPath: folder.appendingPathComponent("vocab.txt").path) {
                return folder
            }
        }
        return nil
    }
}

private final class MemoryResourceMarker {}
