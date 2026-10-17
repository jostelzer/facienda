import Foundation
import Darwin

/// Machine-local credential: never stored in a synced workspace or dispatch prompt.
public enum MemoryServiceCredentials {
    public static var tokenURL: URL {
        LibraryHome.supportDirectory.appending(path: "memory-service/api-token")
    }

    public static func readCertificate() throws -> Data {
        let url = tokenURL.deletingLastPathComponent().appending(path: "server.der")
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StoreError.invalid("Local memory TLS identity is missing.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 16_384 else {
            throw StoreError.invalid("The memory TLS identity must be a private file owned by your account.")
        }
        return try file.read(upToCount: 16_385) ?? Data()
    }

    public static func readToken(at url: URL = tokenURL) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StoreError.invalid("Cannot securely open the local memory credential.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 32, info.st_size <= 257 else {
            throw StoreError.invalid("Memory service credential must be a private file readable only by your account.")
        }
        let token = String(decoding: try file.read(upToCount: 258) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 32, token.count <= 256,
              token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }) else {
            throw StoreError.invalid("Invalid local memory service credential. Reinstall the memory login service.")
        }
        return token
    }
}
