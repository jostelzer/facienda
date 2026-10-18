import Foundation
import GRDB

public struct MemorySection: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "memorySections"
    public var id: String
    public var spaceId: String
    public var name: String
    public var fields: [String]
    public var state: MemoryEntry.State
    public var entryIds: [String]
    public var createdAt: Date
}

public struct MemoryRoutine: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "memoryRoutines"
    public struct Step: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, CaseIterable, Sendable { case ask, oneClick, automatic }
        public enum Action: String, Codable, Sendable { case message, yourStep, reminder }
        public var moveId: String?
        public var text: String
        public var mode: Mode
        public var action: Action
        public init(moveId: String? = nil, text: String, mode: Mode = .ask, action: Action = .message) {
            self.moveId = moveId; self.text = MemoryRedaction.redact(text); self.mode = mode; self.action = action
        }
        public var canBeAutomatic: Bool { action == .reminder }
    }
    public var id: String
    public var spaceId: String
    public var name: String
    public var state: MemoryEntry.State
    public var steps: [Step]
    public var seen: Int
    public var createdAt: Date
}

public struct MemoryRoutineRun: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "memoryRoutineRuns"
    public var taskId: String
    public var routineId: String
    public var step: Int
}

extension FaciendaStore {
    static func registerMemoryCollections(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("memory_collections") { db in
            try db.execute(sql: """
                CREATE TABLE memorySections (id TEXT PRIMARY KEY, spaceId TEXT NOT NULL REFERENCES memorySpaces(id), name TEXT NOT NULL, fields TEXT NOT NULL, state TEXT NOT NULL, entryIds TEXT NOT NULL, createdAt DATETIME NOT NULL);
                CREATE TABLE memoryRoutines (id TEXT PRIMARY KEY, spaceId TEXT NOT NULL REFERENCES memorySpaces(id), name TEXT NOT NULL, state TEXT NOT NULL, steps TEXT NOT NULL, seen INTEGER NOT NULL, createdAt DATETIME NOT NULL);
                CREATE TABLE memoryRoutineRuns (taskId TEXT PRIMARY KEY REFERENCES tasks(id), routineId TEXT NOT NULL REFERENCES memoryRoutines(id), step INTEGER NOT NULL);
                """)
        }
    }

    public func memorySections(spaceID: String) throws -> [MemorySection] {
        try db.read { try MemorySection.fetchAll($0, sql: "SELECT * FROM memorySections WHERE spaceId = ? AND state != 'archived' ORDER BY createdAt", arguments: [spaceID]) }
    }

    public func memoryRoutines(spaceID: String) throws -> [MemoryRoutine] {
        try db.read { try MemoryRoutine.fetchAll($0, sql: "SELECT * FROM memoryRoutines WHERE spaceId = ? AND state != 'archived' ORDER BY seen DESC", arguments: [spaceID]) }
    }

    /// Structure is proposed only after at least three entries share fields; no domain-specific category is built in.
    public func proposeMemoryCollections(spaceID: String) throws {
        try db.write { db in
            var entries = try MemoryEntry.fetchAll(db, sql: "SELECT * FROM memoryEntries WHERE spaceId = ? AND state = 'live' AND sectionId IS NULL", arguments: [spaceID])
            let existing = try MemorySection.fetchAll(db, sql: "SELECT * FROM memorySections WHERE spaceId = ?", arguments: [spaceID])
            for var section in existing where section.state == .live {
                let matching = entries.filter { Set(section.fields).isSubset(of: Set($0.fields.keys)) }
                for entry in matching {
                    try db.execute(sql: "UPDATE memoryEntries SET sectionId = ? WHERE id = ?", arguments: [section.id, entry.id])
                    section.entryIds.append(entry.id)
                }
                if !matching.isEmpty { section.entryIds = Array(Set(section.entryIds)).sorted(); try section.update(db) }
                entries.removeAll { item in matching.contains { $0.id == item.id } }
            }
            let shapes = Dictionary(grouping: entries.filter { $0.fields.count >= 2 }, by: { $0.fields.keys.sorted().joined(separator: "\n") })
            for (shape, group) in shapes where group.count >= 3 {
                let fields = shape.components(separatedBy: "\n")
                guard !existing.contains(where: { $0.fields == fields }) else { continue }
                try MemorySection(id: UUID().uuidString, spaceId: spaceID, name: fields.map(\.capitalized).joined(separator: " · "), fields: fields,
                                  state: .proposed, entryIds: group.map(\.id), createdAt: Date()).insert(db)
            }
            let utterances = try MemoryUtterance.fetchAll(db, sql: "SELECT * FROM memoryUtterances WHERE spaceId = ? AND taskId IS NOT NULL AND moveId IS NOT NULL ORDER BY taskId, at", arguments: [spaceID])
            var pairs: [String: Int] = [:]
            for (a, b) in zip(utterances, utterances.dropFirst()) where a.taskId == b.taskId && a.moveId != b.moveId {
                pairs[(a.moveId ?? "") + ":" + (b.moveId ?? ""), default: 0] += 1
            }
            let routines = try MemoryRoutine.fetchAll(db, sql: "SELECT * FROM memoryRoutines WHERE spaceId = ?", arguments: [spaceID])
            for (pair, count) in pairs where count >= 3 {
                let ids = pair.components(separatedBy: ":")
                guard !routines.contains(where: { $0.steps.compactMap(\.moveId) == ids }) else { continue }
                let moves = try ids.compactMap { try MemoryMove.fetchOne(db, key: $0) }
                guard moves.count == 2, moves.allSatisfy({ $0.spaceId == spaceID }) else { continue }
                try MemoryRoutine(id: UUID().uuidString, spaceId: spaceID, name: "A sequence you repeat", state: .proposed,
                                  steps: moves.map { .init(moveId: $0.id, text: $0.text, action: $0.isYourStep ? .yourStep : .message) }, seen: count, createdAt: Date()).insert(db)
            }
        }
    }

    public func renameMemorySectionField(_ id: String, spaceID: String, from old: String, to new: String) throws {
        let new = MemoryRedaction.redact(new.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !new.isEmpty else { throw StoreError.invalid("Name this field.") }
        try write { db in
            guard var section = try MemorySection.fetchOne(db, key: id), section.spaceId == spaceID, section.fields.contains(old),
                  new == old || !section.fields.contains(new) else { throw StoreError.invalid("Choose a different field name.") }
            for entryID in section.entryIds {
                guard var entry = try MemoryEntry.fetchOne(db, key: entryID), entry.spaceId == spaceID, let value = entry.fields[old] else { continue }
                try Self.saveEntryVersion(db, entry); entry.fields.removeValue(forKey: old); entry.fields[new] = value; entry.revision += 1; try entry.update(db)
            }
            section.fields = section.fields.map { $0 == old ? new : $0 }; try section.update(db)
        }
    }

    public func acceptMemorySection(_ id: String, spaceID: String, name: String) throws {
        let name = MemoryRedaction.redact(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !name.isEmpty else { throw StoreError.invalid("Give this section a name.") }
        try write { db in
            guard var section = try MemorySection.fetchOne(db, key: id), section.spaceId == spaceID else { throw StoreError.notFound }
            section.name = name; section.state = .live; try section.update(db)
            for entry in section.entryIds {
                try db.execute(sql: "UPDATE memoryEntries SET sectionId = ? WHERE id = ? AND spaceId = ? AND state = 'live'", arguments: [id, entry, spaceID])
            }
        }
    }

    public func foldMemorySection(_ id: String, spaceID: String, into targetID: String? = nil) throws {
        try write { db in
            guard var section = try MemorySection.fetchOne(db, key: id), section.spaceId == spaceID else { throw StoreError.notFound }
            if let targetID {
                guard var target = try MemorySection.fetchOne(db, key: targetID), target.spaceId == spaceID, target.state == .live, target.id != id else { throw StoreError.notFound }
                target.entryIds = Array(Set(target.entryIds + section.entryIds)).sorted(); target.fields = Array(Set(target.fields + section.fields)).sorted(); try target.update(db)
            }
            try db.execute(sql: "UPDATE memoryEntries SET sectionId = ? WHERE sectionId = ? AND spaceId = ?", arguments: [targetID, id, spaceID])
            section.state = .archived; try section.update(db)
        }
    }

    public func shareMemorySection(_ id: String, spaceID: String, to targetSpaceID: String) throws {
        guard targetSpaceID != spaceID else { return }
        try write { db in
            _ = try Self.memorySpace(db, targetSpaceID)
            guard var section = try MemorySection.fetchOne(db, key: id), section.spaceId == spaceID, section.state == .live else { throw StoreError.notFound }
            let entries = try MemoryEntry.fetchAll(db, sql: "SELECT * FROM memoryEntries WHERE sectionId = ? AND spaceId = ? AND state = 'live'", arguments: [id, spaceID])
            section.id = UUID().uuidString; section.spaceId = targetSpaceID; section.entryIds = []
            for var entry in entries {
                // Sharing into a workspace with its own wording must never replace that wording silently.
                if try Self.liveEntry(db, spaceID: targetSpaceID, shelf: entry.shelf, key: entry.subjectKey) != nil { continue }
                entry.id = UUID().uuidString; entry.spaceId = targetSpaceID; entry.sectionId = section.id
                entry.sources = ["Shared by you from another workspace"]; entry.origin = .you
                try entry.insert(db); section.entryIds.append(entry.id)
            }
            try section.insert(db)
        }
    }

    public func saveMemoryRoutine(_ id: String, spaceID: String, name: String, steps: [MemoryRoutine.Step], state: MemoryEntry.State = .live) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !steps.isEmpty, steps.count <= 12,
              !steps.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ($0.mode == .automatic && !$0.canBeAutomatic) }) else {
            throw StoreError.invalid("Only a reminder shown in Facienda can run automatically. Messages and your own steps need you.")
        }
        try write { db in
            var routine = try MemoryRoutine.fetchOne(db, key: id) ?? MemoryRoutine(id: id, spaceId: spaceID, name: name, state: .live, steps: [], seen: 0, createdAt: Date())
            guard routine.spaceId == spaceID else { throw StoreError.notFound }
            routine.name = MemoryRedaction.redact(name); routine.steps = steps.map { .init(moveId: $0.moveId, text: $0.text, mode: $0.mode, action: $0.action) }; routine.state = state
            try routine.save(db)
        }
    }

    public func startMemoryRoutine(_ id: String, taskID: String) throws {
        let space = try memorySpace(forTask: taskID).id
        try write { db in
            guard let routine = try MemoryRoutine.fetchOne(db, key: id), routine.spaceId == space, routine.state == .live else { throw StoreError.notFound }
            try MemoryRoutineRun(taskId: taskID, routineId: id, step: 0).save(db)
        }
    }

    public func memoryRoutineStep(taskID: String) throws -> (MemoryRoutine, Int)? {
        let space = try memorySpace(forTask: taskID).id
        return try db.read { db in
            guard let run = try MemoryRoutineRun.fetchOne(db, key: taskID), let routine = try MemoryRoutine.fetchOne(db, key: run.routineId),
                  routine.spaceId == space, routine.state == .live, routine.steps.indices.contains(run.step) else { return nil }
            return (routine, run.step)
        }
    }

    public func advanceMemoryRoutine(taskID: String, expectedStep: Int, userConfirmed: Bool) throws -> String? {
        let space = try memorySpace(forTask: taskID).id
        return try write { db in
            guard var run = try MemoryRoutineRun.fetchOne(db, key: taskID), run.step == expectedStep,
                  let routine = try MemoryRoutine.fetchOne(db, key: run.routineId), routine.spaceId == space, routine.state == .live,
                  routine.steps.indices.contains(run.step) else { throw StoreError.conflict }
            let step = routine.steps[run.step]
            guard userConfirmed || (step.mode == .automatic && step.canBeAutomatic) else { throw StoreError.userOnly }
            run.step += 1; try run.update(db)
            // Automatic steps can only display text locally. Dispatch is exclusively the existing user reply path.
            return step.action == .reminder ? step.text : nil
        }
    }
}
