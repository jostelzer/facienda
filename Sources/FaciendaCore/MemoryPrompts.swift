import Foundation

/// One hidden model call: a system prompt, a user message and a JSON schema. Returns the reply text.
public protocol MemoryInference: Sendable {
    func complete(system: String, user: String, schema: JSONValue) async throws -> String
    func complete(system: String, user: String, schema: JSONValue, priority: MemoryInferencePriority) async throws -> String
}

extension MemoryInference {
    public func complete(system: String, user: String, schema: JSONValue, priority: MemoryInferencePriority) async throws -> String {
        try await complete(system: system, user: user, schema: schema)
    }

    /// The request shape the `facienda-memory` helper and the gateway accept.
    public static func request(system: String, user: String, schema: JSONValue) throws -> MemoryInferenceRequest {
        try MemoryInferenceRequest(.object([
            "messages": .array([
                .object(["role": .string("system"), "content": .string(system)]),
                .object(["role": .string("user"), "content": .string(user)])
            ]),
            "response_format": .object(["type": .string("json_schema"), "json_schema": .object([
                "name": .string("memory"), "strict": .bool(true), "schema": schema
            ])])
        ]))
    }
}

/// Runs each call through the bundled `facienda-memory` helper, for processes without a warm Luna (the MCP helper).
public struct HelperMemoryInference: MemoryInference {
    public let executable: URL
    private let pool: MemoryInferencePool
    public init(executable: URL) {
        self.executable = executable
        pool = MemoryInferencePool(workers: (0..<MemoryInferencePool.parallelism).map { _ in MemoryHelperWorker(executable: executable) })
    }

    /// `facienda-memory` next to this binary, or in the installed app's Helpers.
    public static func bundled() -> HelperMemoryInference? {
        let here = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath().deletingLastPathComponent()
        for candidate in [here.appendingPathComponent("facienda-memory"),
                          Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/facienda-memory"),
                          URL(fileURLWithPath: "/Applications/Facienda.app/Contents/Helpers/facienda-memory")]
        where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return HelperMemoryInference(executable: candidate)
        }
        return nil
    }

    public func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        try await complete(system: system, user: user, schema: schema, priority: .background)
    }

    public func complete(system: String, user: String, schema: JSONValue, priority: MemoryInferencePriority) async throws -> String {
        try await pool.complete(system: system, user: user, schema: schema, priority: priority)
    }
}

private struct MemoryHelperWorker: MemoryInference {
    let executable: URL
    func complete(system: String, user: String, schema: JSONValue) async throws -> String {
        let request = try Self.request(system: system, user: user, schema: schema)
        let executable = executable
        let output: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = executable
                let choice = ServiceModelChoice.current
                process.arguments = ["--provider", choice.provider.rawValue, "--model", choice.model]
                process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    input.fileHandleForWriting.write(Data(request.request.json.utf8))
                    try input.fileHandleForWriting.close()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw StoreError.invalid("The background worker could not process this memory request.") }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
        let receipt = try JSONDecoder().decode(JSONValue.self, from: output)
        guard let content = receipt["content"].string else { throw StoreError.invalid("The background worker returned no memory response.") }
        try request.validate(content)
        return content
    }
}
