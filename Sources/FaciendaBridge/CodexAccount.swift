import Foundation
import FaciendaCore

public struct CodexAccountStatus: Decodable, Sendable {
    public struct Account: Decodable, Sendable { public let type: String }
    public let account: Account?
    public let requiresOpenaiAuth: Bool
    public var isReady: Bool { account != nil || !requiresOpenaiAuth }
}

public struct CodexSignIn: Sendable {
    public let id: String
    public let url: URL

    init(response: JSONValue) throws {
        guard response["type"].string == "chatgpt",
              let id = response["loginId"].string, !id.isEmpty,
              let raw = response["authUrl"].string, let url = URL(string: raw),
              url.scheme == "https", ["auth.openai.com", "chatgpt.com"].contains(url.host),
              url.user == nil, url.password == nil else {
            throw BridgeError.server("Codex did not return a valid sign-in link. Try connecting again.")
        }
        self.id = id; self.url = url
    }
}

extension CodexBridge {
    public func accountStatus() async throws -> CodexAccountStatus {
        try await request("account/read", params: .object(["refreshToken": .bool(false)])).decoded(CodexAccountStatus.self)
    }
    public func startSignIn() async throws -> CodexSignIn {
        let response = try await request("account/login/start", params: .object([
            "type": .string("chatgpt"), "useHostedLoginSuccessPage": .bool(true), "appBrand": .string("codex")
        ]))
        return try CodexSignIn(response: response)
    }
    public func cancelSignIn(_ id: String) async throws {
        _ = try await request("account/login/cancel", params: .object(["loginId": .string(id)]))
    }
}
