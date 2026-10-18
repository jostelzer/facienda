import Foundation
import Darwin

/// Codex's shared daemon, reached as a WebSocket over a local socket. This is separate from the desktop app's server;
/// both enforce a single writer per chat. `codex app-server proxy` is meant to relay this socket over stdio.
final class DaemonSocket: Sendable {
    private let descriptor: Int32

    /// The control socket the Codex app keeps in its home folder.
    static var defaultPath: String {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex").path
        return home + "/app-server-control/app-server-control.sock"
    }

    /// Connects and upgrades to a WebSocket. Returns the bytes that arrived after the upgrade, which begin the first frame.
    static func open(path: String) throws -> (socket: DaemonSocket, leftover: Data) {
        // A socket address holds about a hundred bytes, so a long path goes by the file it links to.
        let target = path.utf8.count < 100 ? path : URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BridgeError.unavailable }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(target.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(descriptor); throw BridgeError.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes); buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw BridgeError.server("The Codex app is not running its app server. Open Codex, then try again.")
        }
        let socket = DaemonSocket(descriptor: descriptor)
        do { return (socket, try socket.upgrade()) } catch { socket.close(); throw error }
    }

    private init(descriptor: Int32) { self.descriptor = descriptor }

    private func upgrade() throws -> Data {
        var key = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&key, key.count)
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(Data(key).base64EncodedString())\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try write(Data(request.utf8))
        var received = Data()
        while true {
            if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: received[..<end.lowerBound], as: UTF8.self)
                guard head.hasPrefix("HTTP/1.1 101") else { throw BridgeError.server("The Codex app server refused the connection.") }
                return Data(received[end.upperBound...])
            }
            guard let chunk = try readChunk() else { throw BridgeError.disconnected }
            received.append(chunk)
        }
    }

    /// Sends one text message.
    func send(_ text: Data) throws { try write(frame(opcode: 1, payload: text)) }

    /// Reads messages until the connection ends, handing each text message on. Answers pings itself.
    func readMessages(leftover: Data, _ deliver: (Data) -> Void) {
        var buffer = leftover, message = Data()
        func take(_ count: Int) -> Data? {
            while buffer.count < count {
                guard let chunk = try? readChunk() else { return nil }
                buffer.append(chunk)
            }
            let out = Data(buffer.prefix(count)); buffer.removeFirst(count); return out
        }
        while let head = take(2) {
            let opcode = head[head.startIndex] & 0x0f, final = head[head.startIndex] & 0x80 != 0
            var length = Int(head[head.startIndex + 1] & 0x7f)
            if length == 126 { guard let extended = take(2) else { return }; length = extended.reduce(0) { $0 << 8 | Int($1) } }
            else if length == 127 { guard let extended = take(8) else { return }; length = extended.reduce(0) { $0 << 8 | Int($1) } }
            guard let payload = take(length) else { return }
            switch opcode {
            case 8: return
            case 9: try? write(frame(opcode: 10, payload: payload))
            case 10: continue
            default:
                message.append(payload)
                if final { deliver(message); message = Data() }
            }
        }
    }

    func close() { shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor) }

    private func readChunk() throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0 else { return nil }
        return Data(bytes[..<count])
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { throw BridgeError.disconnected }
                offset += written
            }
        }
    }

    /// Client frames are masked, as the protocol requires.
    private func frame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(0x80 | UInt8(payload.count)) }
        else if payload.count < 65_536 { frame.append(0x80 | 126); frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]) }
        else { frame.append(0x80 | 127); frame.append(contentsOf: (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xff) }) }
        var mask = [UInt8](repeating: 0, count: 4)
        arc4random_buf(&mask, 4)
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }
}
