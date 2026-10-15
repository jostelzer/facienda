import Foundation
import GRDB
import Synchronization

/// The model behind Facienda's own background work: task names, headlines, recaps, next steps, waits, finding earlier
/// tasks and built-in memory. It runs in Codex or in Claude, so a Mac with only one of them gets all of it.
/// Kept in the library, so the app, the dispatcher and the helpers all use the same one.
public struct ServiceModelChoice: Codable, Equatable, Sendable {
    public var provider: AgentProvider
    public var model: String

    public init(provider: AgentProvider, model: String) { self.provider = provider; self.model = model }

    public static let luna = ServiceModelChoice(provider: .codex, model: MemoryInferenceRequest.model)
    public static let haiku = ServiceModelChoice(provider: .claude, model: "claude-haiku-5-5")

    /// A small, fast model suits this work. Codex comes first when it is there, as it was before Claude could do it.
    public static func recommended(codex: Bool, claude: Bool) -> ServiceModelChoice {
        claude && !codex ? haiku : luna
    }
    /// The recommended model of a provider.
    public static func recommended(for provider: AgentProvider) -> ServiceModelChoice { provider == .claude ? haiku : luna }

    public var name: String { TaskModelChoice.catalog.first { $0.id == model }?.name ?? model }

    private static let shared = Mutex<ServiceModelChoice>(.luna)
    /// The choice this process works with. The app sets it from the library, and so does each helper when it starts.
    public static var current: ServiceModelChoice {
        get { shared.withLock { $0 } }
        set { shared.withLock { $0 = newValue } }
    }
}

extension FaciendaStore {
    static func registerServiceModel(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("service_model") { db in
            try db.execute(sql: "CREATE TABLE serviceModel (id INTEGER PRIMARY KEY CHECK(id = 1), provider TEXT NOT NULL, model TEXT NOT NULL, chosenAt DATETIME NOT NULL)")
        }
    }

    /// The model the user chose for background work; nil until setup chose one.
    public func serviceModel() throws -> ServiceModelChoice? {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT provider, model FROM serviceModel WHERE id = 1"),
                  let provider = AgentProvider(rawValue: row["provider"]) else { return nil }
            return ServiceModelChoice(provider: provider, model: row["model"])
        }
    }

    public func saveServiceModel(_ choice: ServiceModelChoice, now: Date = Date()) throws {
        guard !choice.model.isEmpty else { throw StoreError.invalid("Choose a model.") }
        try write { db in
            try db.execute(sql: "INSERT INTO serviceModel(id, provider, model, chosenAt) VALUES (1, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET provider = excluded.provider, model = excluded.model, chosenAt = excluded.chosenAt",
                           arguments: [choice.provider.rawValue, choice.model, now])
        }
        ServiceModelChoice.current = choice
    }

    /// Makes this process use the library's choice, or Luna when none was made.
    public func adoptServiceModel() {
        ServiceModelChoice.current = (try? serviceModel()) ?? .luna
    }
}
