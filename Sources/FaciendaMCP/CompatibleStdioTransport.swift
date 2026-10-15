import Foundation
import Logging
import MCP

/// MCP Swift SDK 0.12.1 decodes experimental client capabilities as string values,
/// but MCP permits arbitrary JSON (Codex sends `codex/auth-change: {}`). Facienda
/// does not use these extensions. Ignore unsupported values during initialization;
/// delegate framing, lifecycle and every other message to the official transport.
/// Remove this adapter when the SDK accepts arbitrary experimental capability JSON.
actor CompatibleStdioTransport: Transport {
    private let base = StdioTransport()
    nonisolated var logger: Logger { base.logger }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func send(_ data: Data) async throws { try await base.send(data) }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await base.receive() {
                        continuation.yield(try Self.compatibleInitialization(data))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func compatibleInitialization(_ data: Data) throws -> Data {
        guard var message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              message["method"] as? String == "initialize",
              var params = message["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any],
              experimental.values.contains(where: { !($0 is String) }) else { return data }
        capabilities["experimental"] = experimental.filter { $0.value is String }
        params["capabilities"] = capabilities
        message["params"] = params
        return try JSONSerialization.data(withJSONObject: message)
    }
}
