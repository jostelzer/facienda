import Foundation

/// Hindsight's text-only inference contract. Memory always uses hidden Luna threads.
public struct MemoryInferenceRequest: Sendable {
    public static let model = "gpt-6-luna"
    public static let reasoningEffort = "high"
    public let request: JSONValue
    public init(_ request: JSONValue) throws {
        guard let messages = request["messages"].array, !messages.isEmpty,
              request["stream"].bool != true, request["tools"] == .null,
              request.json.utf8.count <= 2_000_000 else {
            throw StoreError.invalid("Memory inference accepts bounded, non-streaming text messages without tools.")
        }
        for message in messages {
            guard ["system", "developer", "user", "assistant"].contains(message["role"].string ?? ""), message["content"].string != nil else {
                throw StoreError.invalid("Memory inference requires text-only messages.")
            }
        }
        self.request = request
    }
    public var outputSchema: JSONValue { request["response_format"]["json_schema"]["schema"] }
    public func validate(_ content: String) throws {
        guard !content.isEmpty else { throw StoreError.invalid("Luna returned no memory response.") }
        if ["json_object", "json_schema"].contains(request["response_format"]["type"].string ?? "") {
            _ = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
        }
    }
}
