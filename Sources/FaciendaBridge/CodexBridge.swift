import Foundation
import Synchronization
import FaciendaCore

public struct CodexThread: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var preview: String
    public var cwd: String
    public var updatedAt: Double
    public var status: JSONValue
    public var title: String { name?.isEmpty == false ? name! : String(preview.prefix(90)) }
    public var statusLabel: String {
        if let flag = status["activeFlags"].array?.first?.string { return flag }
        return status["type"].string ?? "unknown"
    }
}
public struct ThreadPage: Decodable, Sendable { public let data: [CodexThread]; public let nextCursor: String? }
public struct BridgeMessage: Sendable {
    public let method: String
    public let params: JSONValue
    public let requestID: JSONValue?
}
public enum BridgeError: LocalizedError, Sendable {
    case disconnected, timeout(String), server(String), unavailable
    public var errorDescription: String? {
        switch self {
        case .disconnected: "Codex disconnected. Reconnect to continue."
        case .timeout(let method): "Codex did not answer \(method) in time."
        case .server(let message): message
        case .unavailable: "Codex was not found on this Mac. Install Codex, then retry the connection."
        }
    }
}

/// One owning process or the Codex app's own server, one ordered message stream, bounded requests. No database access to Codex.
public actor CodexBridge {
    /// Every listener gets its own stream. A cancelled AsyncStream consumer finishes the
    /// stream for everyone, so one shared stream died for good after a single timeout.
    private let subscribers = Mutex<[UUID: AsyncStream<BridgeMessage>.Continuation]>([:])
    private var process: Process?
    private var writer: (@Sendable (Data) throws -> Void)?
    private var closer: (@Sendable () -> Void)?
    private var reading: Task<Void, Never>?
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var generation = UUID()

    /// Longest single message kept. Real linked histories can exceed 16 MiB because of tool output and images.
    private let maximumLineBytes: Int

    public init(maximumLineBytes: Int = 64 * 1024 * 1024) { self.maximumLineBytes = maximumLineBytes }
    /// Messages from now on. Subscribe before sending a request whose notifications matter.
    public nonisolated var messages: AsyncStream<BridgeMessage> { subscribe() }
    public nonisolated func subscribe() -> AsyncStream<BridgeMessage> {
        let (stream, continuation) = AsyncStream<BridgeMessage>.makeStream()
        let id = UUID()
        subscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in _ = self?.subscribers.withLock { $0.removeValue(forKey: id) } }
        return stream
    }
    private nonisolated func publish(_ message: BridgeMessage) {
        for continuation in subscribers.withLock({ Array($0.values) }) { continuation.yield(message) }
    }
    public var isConnected: Bool { writer != nil }
    public static func discoverExecutable() -> String? {
        // Match the desktop app's protocol/model support before falling back to a
        // separately installed CLI, which may lag behind the desktop release.
        let applications = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        let bundled = applications.flatMap { root in
            ["ChatGPT.app", "Codex.app"].flatMap { app in
                ["codex-cli/bin/codex", "codex"].map { "\(root)/\(app)/Contents/Resources/\($0)" }
            }
        }
        return (bundled + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public func connect(executable: String, arguments: [String] = ["app-server"]) async throws {
        disconnect()
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw BridgeError.unavailable }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        try process.run()
        let input = stdin.fileHandleForWriting
        self.process = process
        writer = { try input.write(contentsOf: $0) }
        closer = { try? input.close() }
        DispatchQueue(label: "org.facienda.codex.stdout", qos: .utility).async {
            defer { continuation.finish() }
            while true {
                let data = stdout.fileHandleForReading.availableData
                guard !data.isEmpty else { break }
                continuation.yield(data)
            }
        }
        try await begin(chunks)
    }
    /// Connects to Codex's shared daemon. The desktop app uses a separate server: a turn started here holds the
    /// chat's writer lock, and this client must handle its approvals and release its subscription when done.
    public func connectDaemon(socketPath: String? = nil) async throws {
        disconnect()
        let path = socketPath ?? DaemonSocket.defaultPath
        let (socket, leftover) = try await Task.detached { try DaemonSocket.open(path: path) }.value
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        // Each WebSocket message is one JSON message; the reader below splits on newlines.
        writer = { try socket.send(Data($0.dropLast())) }
        closer = { socket.close() }
        DispatchQueue(label: "org.facienda.codex.daemon", qos: .utility).async {
            defer { continuation.finish() }
            socket.readMessages(leftover: leftover) { var line = $0; line.append(10); continuation.yield(line) }
        }
        try await begin(chunks)
    }
    private func begin(_ chunks: AsyncStream<Data>) async throws {
        let generation = UUID(); self.generation = generation
        let maximumLineBytes = maximumLineBytes
        reading = Task { [weak self] in
            var buffer = Data()
            var scannedBytes = 0
            // An oversized message is skipped up to its newline, failing only its own request. Ending the
            // connection instead made one huge chat drop it on every read, again and again.
            var skipping: Int?? = nil
            for await chunk in chunks {
                guard !Task.isCancelled else { return }
                var data = chunk
                if let id = skipping {
                    guard let newline = data.firstIndex(of: 10) else { continue }
                    data = Data(data[data.index(after: newline)...])
                    skipping = nil
                    await self?.oversized(id, generation: generation)
                }
                buffer.append(data)
                // Scan only newly received bytes. Rescanning the whole partial JSON
                // response for every pipe chunk made large histories time out.
                while let end = buffer[buffer.index(buffer.startIndex, offsetBy: scannedBytes)...].firstIndex(of: 10) {
                    let oversized = buffer.distance(from: buffer.startIndex, to: end) > maximumLineBytes
                    let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                    scannedBytes = 0
                    if oversized { await self?.oversized(Self.responseID(line), generation: generation) }
                    else { await self?.receive(line, generation: generation) }
                }
                scannedBytes = buffer.count
                if buffer.count > maximumLineBytes {
                    skipping = .some(Self.responseID(buffer)); buffer = Data(); scannedBytes = 0
                }
            }
            await self?.ended(generation)
        }
        do {
            _ = try await request("initialize", params: .object([
                "clientInfo": .object(["name": .string("facienda"), "version": .string("0.1.0")]),
                "capabilities": .object(["experimentalApi": .bool(true)])
            ]))
            try send(.object(["method": .string("initialized")]))
        } catch { disconnect(); throw error }
    }
    public func disconnect() {
        generation = UUID(); reading?.cancel(); reading = nil
        closer?(); closer = nil; writer = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        failPending(BridgeError.disconnected)
    }
    /// Waits for an owned server to release its chat writer locks before handing them to another app.
    func disconnectAndWait() async {
        let owned = process
        disconnect()
        if let owned { await Task.detached { owned.waitUntilExit() }.value }
    }
    private func failPending(_ error: any Error) {
        let requests = pending; pending.removeAll()
        for timeout in deadlines.values { timeout.cancel() }; deadlines.removeAll()
        for continuation in requests.values { continuation.resume(throwing: error) }
    }
    private func ended(_ generation: UUID) {
        guard self.generation == generation else { return }
        disconnect()
        publish(.init(method: "facienda/disconnected", params: .null, requestID: nil))
    }
    private func send(_ value: JSONValue) throws {
        guard let writer else { throw BridgeError.disconnected }
        var data = try JSONEncoder().encode(value); data.append(10)
        try writer(data)
    }
    public func request(_ method: String, params: JSONValue = .object([:]), timeout: Duration = .seconds(20)) async throws -> JSONValue {
        guard writer != nil else { throw BridgeError.disconnected }
        nextID += 1; let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.expire(id, method: method)
                }
                do { try send(.object(["id": .number(Double(id)), "method": .string(method), "params": params])) }
                catch { pending.removeValue(forKey: id)?.resume(throwing: error); deadlines.removeValue(forKey: id)?.cancel() }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError()); deadlines.removeValue(forKey: id)?.cancel()
    }
    private func expire(_ id: Int, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: BridgeError.timeout(method)); deadlines.removeValue(forKey: id)?.cancel()
    }
    /// The request a response answers, read from its opening bytes; Codex writes the id first.
    private static func responseID(_ line: Data) -> Int? {
        let opening = String(decoding: line.prefix(64), as: UTF8.self)
        guard let match = opening.firstMatch(of: /^\{"id":(\d+),/) else { return nil }
        return Int(match.1)
    }
    private func oversized(_ id: Int?, generation: UUID) {
        guard self.generation == generation, let id, let continuation = pending.removeValue(forKey: id) else { return }
        deadlines.removeValue(forKey: id)?.cancel()
        continuation.resume(throwing: BridgeError.server("Codex sent more than \(maximumLineBytes / 1_048_576) MiB for one request, so Facienda skipped it."))
    }
    private func receive(_ data: Data, generation: UUID) {
        guard self.generation == generation, let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        if let method = value["method"].string {
            publish(.init(method: method, params: value["params"], requestID: value["id"] == .null ? nil : value["id"]))
        } else if let number = value["id"].number, let continuation = pending.removeValue(forKey: Int(number)) {
            deadlines.removeValue(forKey: Int(number))?.cancel()
            if value["error"] != .null { continuation.resume(throwing: BridgeError.server(value["error"]["message"].string ?? "Unknown Codex error")) }
            else { continuation.resume(returning: value["result"]) }
        }
    }
    public func respond(id: JSONValue, result: JSONValue) throws { try send(.object(["id": id, "result": result])) }
    public func rejectUnsupported(id: JSONValue) throws { try send(.object(["id": id, "error": .object(["code": .number(-32601), "message": .string("Facienda does not support this request")])])) }
    public func listThreads(cursor: String? = nil, search: String? = nil) async throws -> ThreadPage {
        var params: [String: JSONValue] = ["limit": .number(100), "sortKey": .string("updated_at"), "useStateDbOnly": .bool(true)]
        if let cursor { params["cursor"] = .string(cursor) }; if let search, !search.isEmpty { params["searchTerm"] = .string(search) }
        return try await request("thread/list", params: .object(params)).decoded(ThreadPage.self)
    }
    public func readThread(_ id: String) async throws -> JSONValue {
        try await request("thread/read", params: .object(["threadId": .string(id), "includeTurns": .bool(true)]))
    }
}
