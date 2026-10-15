import Foundation
import Testing
@testable import FaciendaCore

/// Reference outputs from the original Hugging Face tokenizer and PyTorch models (scripts/convert_memory_models.py).
private struct ModelFixture: Decodable {
    struct Tokens: Decodable { let text: String; let ids: [Int32] }
    struct Embedding: Decodable { let text: String; let vector: [Float] }
    struct Pair: Decodable { let query: String; let document: String; let ids: [Int32]; let typeIds: [Int32]; let score: Float }
    let tokens: [Tokens]
    let embeddings: [Embedding]
    let pairs: [Pair]

    static func load() throws -> ModelFixture {
        let url = try #require(Bundle.module.url(forResource: "memory-models", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(ModelFixture.self, from: Data(contentsOf: url))
    }
}

private func models() throws -> MemoryModels {
    MemoryModels(cache: FileManager.default.temporaryDirectory.appending(path: "FaciendaMemoryModels-\(getpid())"))
}

@Test func tokenizerMatchesHuggingFace() async throws {
    let fixture = try ModelFixture.load(), tokenizer = try await models().tokenizer()
    for sample in fixture.tokens {
        #expect(tokenizer.encode(sample.text) == sample.ids, "\(sample.text)")
    }
    for pair in fixture.pairs {
        let encoded = tokenizer.encodePair(pair.query, pair.document)
        #expect(encoded.ids == pair.ids)
        #expect(encoded.types == pair.typeIds)
    }
    let long = tokenizer.encode(String(repeating: "word ", count: 2_000))
    #expect(long.count == MemoryTokenizer.maxTokens && long.first == 101 && long.last == 102)
}

@Test func embeddingsAndRerankingMatchTheOriginalModels() async throws {
    let fixture = try ModelFixture.load(), models = try models()
    let vectors = try await models.embed(fixture.embeddings.map(\.text))
    for (vector, expected) in zip(vectors, fixture.embeddings) {
        #expect(vector.count == MemoryModels.dimensions)
        let cosine = zip(vector, expected.vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        #expect(cosine > 0.995, "\(expected.text): \(cosine)")
    }
    let query = fixture.pairs[0].query
    let scores = try await models.rerank(query, fixture.pairs.map(\.document))
    for (score, pair) in zip(scores, fixture.pairs) {
        #expect(abs(score - pair.score) < 0.3, "\(pair.document): \(score) vs \(pair.score)")
    }
    #expect(scores.dropFirst().allSatisfy { scores[0] > $0 })
}
