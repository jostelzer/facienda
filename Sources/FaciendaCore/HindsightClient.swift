import Foundation
import Security

private final class MemoryRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let data = try? MemoryServiceCredentials.readCertificate(),
              let certificate = SecCertificateCreateWithData(nil, data as CFData),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, SecCertificateCopyData(leaf) as Data == data else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // A local memory service must never redirect workspace text to another host.
        completionHandler(nil)
    }
}

/// Local HTTP boundary. No global SDK configuration or credentials are shared with Codex.
public struct HindsightClient: Sendable {
    public static let localSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()
    public let settings: WorkspaceMemorySettings
    /// One memory's bank. Every request names it, so one memory can never read or write another's.
    public let bankId: String
    private let session: URLSession
    private let apiToken: String?
    public init(settings: WorkspaceMemorySettings, bankId: String, session: URLSession = localSession, apiToken: String? = nil) {
        self.settings = settings; self.bankId = bankId; self.session = session; self.apiToken = apiToken
    }

    public func request(_ method: String, _ path: [String], body: JSONValue? = nil, timeout: TimeInterval = 15) async throws -> JSONValue {
        var url = try settings.baseURL
        for part in path { url.append(path: part) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        let token = try apiToken ?? MemoryServiceCredentials.readToken()
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request, delegate: MemoryRedirectPolicy())
        guard let response = response as? HTTPURLResponse else { throw StoreError.invalid("Hindsight returned an invalid response.") }
        guard (200..<300).contains(response.statusCode) else {
            throw StoreError.invalid("Hindsight returned HTTP \(response.statusCode). Response content was withheld to avoid copying memory text into diagnostics.")
        }
        return data.isEmpty ? .object([:]) : try JSONDecoder().decode(JSONValue.self, from: data)
    }
    private var bank: [String] { ["v1", "default", "banks", bankId] }
    public func health() async throws { _ = try await request("GET", ["health"], timeout: 5) }
    public func configure(name: String) async throws {
        _ = try await request("PUT", bank, body: .object([
            "name": .string("Facienda memory: " + name),
            "retain_mission": .string("Extract durable preferences, decisions, people, procedures and verified outcomes. Distinguish explicit user statements from assistant reports and inferences. Keep temporal changes and evidence. Ignore boilerplate and transient status."),
            "enable_observations": .bool(true)
        ]))
        _ = try await request("PATCH", bank + ["config"], body: .object(["updates": .object([
            "enable_auto_consolidation": .bool(true),
            "audit_log_enabled": .bool(false),
            "mental_model_min_refresh_interval_seconds": .number(3600)
        ])]))
    }
    public func retain(_ doc: MemoryDocument) async throws -> JSONValue {
        try await request("POST", bank + ["memories"], body: .object([
            "async": .bool(true), "operation_id": .string(doc.operationId),
            "items": .array([.object([
                "document_id": .string(doc.documentID), "content": .string(doc.content),
                "context": .string(doc.source), "timestamp": .string(ISO8601DateFormatter().string(from: doc.at)),
                "metadata": .object(["source": .string(doc.source)]),
                "observation_scopes": .string("shared")
            ])])
        ]))
    }
    public func operation(_ id: String) async throws -> JSONValue {
        try await request("GET", bank + ["operations", id])
    }
    public func recall(_ query: String) async throws -> JSONValue {
        try await request("POST", bank + ["memories", "recall"], body: .object([
            "query": .string(query.isEmpty ? "Workspace preferences, decisions, procedures and useful lessons" : query),
            "budget": .string("low"), "max_tokens": .number(1600),
            "prefer_observations": .bool(true),
            "include": .object(["source_facts": .object(["max_tokens": .number(800)])])
        ]), timeout: 8)
    }
    public func consolidate() async throws -> JSONValue {
        try await request("POST", bank + ["consolidate"], body: .object([:]))
    }
}

public struct WorkspaceMemoryService: Sendable {
    public let store: FaciendaStore
    private let session: URLSession
    private let apiToken: String?
    /// How built-in memory reaches Luna: a warm hidden thread in the app, the `facienda-memory` helper elsewhere.
    private let inference: (any MemoryInference)?
    public init(store: FaciendaStore, session: URLSession = HindsightClient.localSession, apiToken: String? = nil,
                inference: (any MemoryInference)? = HelperMemoryInference.bundled()) {
        self.store = store; self.session = session; self.apiToken = apiToken; self.inference = inference
    }

    /// Learns from waiting sources of every memory: in Facienda, or by sending each to its memory's Hindsight bank.
    public func synchronize(limit: Int = 8) async throws {
        let settings = try store.memorySettings()
        guard settings.enabled else { return }
        try store.captureWorkspaceMemory()
        guard settings.usesHindsight else {
            guard let inference else { throw StoreError.invalid("Memory learning needs Facienda's bundled Luna helper.") }
            try await NativeMemoryEngine(store: store, inference: inference).synchronize(sources: max(1, limit / 2), batches: max(1, limit / 2))
            return
        }
        for _ in 0..<limit {
            // Recheck after every await: disabling memory or changing servers stops this run.
            let current = try store.memorySettings()
            guard current.enabled, current.endpoint == settings.endpoint else { return }
            guard let doc = try store.claimMemoryDocument() else { return }
            do {
                guard let spaceID = doc.spaceId, let space = try store.memorySpaces().first(where: { $0.id == spaceID }) else {
                    throw StoreError.invalid("This memory source belongs to no memory and was not sent.")
                }
                let client = HindsightClient(settings: settings, bankId: space.bankId, session: session, apiToken: apiToken)
                if space.configuredEndpoint != settings.endpoint {
                    try await client.configure(name: space.name)
                    try store.markSpaceConfigured(space.id, endpoint: settings.endpoint)
                }
                if doc.state == "processing" {
                    let result = try await client.operation(doc.operationId)
                    switch result["status"].string {
                    case "completed": try store.finishMemoryAttempt(doc, state: "completed")
                    case "failed", "cancelled":
                        try store.finishMemoryAttempt(doc, state: "pending", error: "Hindsight processing failed; source-bearing diagnostics were withheld.", retryOperation: true)
                    case "not_found": try store.finishMemoryAttempt(doc, state: "pending", error: "Hindsight lost the operation; resubmitting the source.", retryOperation: true)
                    case "pending", "processing": try store.finishMemoryAttempt(doc, state: "processing")
                    default: throw StoreError.invalid("Hindsight returned an unknown operation status.")
                    }
                } else {
                    let result = try await client.retain(doc)
                    guard result["success"].bool == true, result["bank_id"].string == space.bankId,
                          result["operation_id"].string.flatMap(UUID.init(uuidString:)) == UUID(uuidString: doc.operationId) else {
                        throw StoreError.invalid("Hindsight did not acknowledge the expected memory operation.")
                    }
                    try store.finishMemoryAttempt(doc, state: "processing")
                }
            } catch {
                try store.finishMemoryAttempt(doc, state: doc.state, error: error.localizedDescription)
                throw error
            }
        }
    }

    /// What one memory knows: the one named, or the scoped workspace's. Other memories are never consulted.
    public func context(query: String, spaceID: String? = nil, taskID: String? = nil) async throws -> JSONValue {
        let settings = try store.memorySettings()
        let space = try store.resolvedMemorySpace(spaceID)
        let notes = try store.memory(spaceID: space.id).filter { $0.confirmedAt != nil }
        var context: [String: JSONValue] = ["memory": .string(space.name), "userConfirmed": try .encoded(notes), "bankId": .string(space.bankId)]
        guard settings.enabled else { context["status"] = .string("Learned memory is off"); return .object(context) }
        guard settings.usesHindsight else {
            do {
                let question = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Workspace preferences, decisions, procedures and useful lessons" : query
                var options = MemoryRecallOptions()
                options.taskID = taskID
                context["learned"] = try await MemoryRecall(store: store).recall(question, spaceID: space.id, options: options)
                context["status"] = .string("Learned context from the \(space.name) memory; inferred observations are not user-confirmed facts")
            } catch {
                context["status"] = .string("Learned memory unavailable; use confirmed notes and current task evidence")
                context["error"] = .string(error.localizedDescription)
            }
            return .object(context)
        }
        do {
            context["learned"] = try await HindsightClient(settings: settings, bankId: space.bankId, session: session, apiToken: apiToken).recall(query)
            context["status"] = .string("Hindsight context from the \(space.name) memory; inferred observations are not user-confirmed facts")
        } catch {
            context["status"] = .string("Hindsight unavailable; use confirmed notes and current task evidence")
            context["error"] = .string(error.localizedDescription)
        }
        return .object(context)
    }

    /// Consolidates one memory's waiting facts into observations now.
    public func consolidate(spaceID: String? = nil) async throws {
        let settings = try store.memorySettings()
        guard settings.enabled else { return }
        let space = try store.resolvedMemorySpace(spaceID)
        guard settings.usesHindsight else {
            guard let inference else { throw StoreError.invalid("Memory learning needs Facienda's bundled Luna helper.") }
            let engine = NativeMemoryEngine(store: store, inference: inference)
            for _ in 0..<25 { guard try await engine.consolidateNext(spaceID: space.id) else { break } }
            return
        }
        _ = try await HindsightClient(settings: settings, bankId: space.bankId, session: session, apiToken: apiToken).consolidate()
    }
}
