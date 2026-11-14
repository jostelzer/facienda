import Foundation
import Logging
import MCP

/// Newline-delimited JSON on stdin and stdout, like the MCP Swift SDK's own stdio transport, with two differences.
///
/// The SDK's transport sets stdin non-blocking and polls it every 10 ms. Every open Claude session and Codex chat that
/// loads Facienda's tools keeps one of these servers alive, often for days, so a few dozen idle servers woke the Mac
/// thousands of times a second. This one reads on its own thread and sleeps until the client writes.
///
/// MCP Swift SDK 0.12.1 also decodes experimental client capabilities as string values, but MCP permits arbitrary JSON
/// (Codex sends `codex/auth-change: {}`). Facienda does not use these extensions, so unsupported values are dropped
/// from `initialize`. Remove that part when the SDK accepts arbitrary experimental capability JSON.
actor CompatibleStdioTransport: Transport {
    nonisolated let logger = Logger(label: "mcp.transport.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
    private let messages: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var connected = false

    init() {
        (messages, continuation) = AsyncThrowingStream.makeStream()
    }

    func connect() async throws {
        guard !connected else { return }
        connected = true
        let continuation = continuation
        Thread.detachNewThread {
            Self.readLines(from: STDIN_FILENO) { continuation.yield((try? Self.compatibleInitialization($0)) ?? $0) }
            continuation.finish()
        }
    }

    func disconnect() async {
        connected = false
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        guard connected else { throw MCPError.connectionClosed }
        do { try FileHandle.standardOutput.write(contentsOf: data + [UInt8(ascii: "\n")]) }
        catch { throw MCPError.transportError(error) }
    }

    func receive() -> AsyncThrowingStream<Data, any Error> { messages }

    /// Hands each non-empty line to `line` until end of input or a read error. Blocks the calling thread while waiting.
    static func readLines(from descriptor: Int32, _ line: (Data) -> Void) {
        // A client may hand over a non-blocking descriptor. poll then waits for input instead of spinning.
        var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var pending = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { _ = poll(&waiting, 1, -1); continue }
                return
            }
            if count == 0 { return }
            pending.append(contentsOf: buffer[..<count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let message = Data(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
                if !message.isEmpty { line(message) }
            }
        }
    }

    static func compatibleInitialization(_ data: Data) throws -> Data {
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
