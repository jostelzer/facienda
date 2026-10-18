#if DEBUG
import Foundation
import GRDB

extension FaciendaStore {
    /// Invented, mixed-domain data shared by the Debug preview and screenshot path.
    public func seedMemoryDemo(spaceID: String, taskID: String) throws {
        let specimens: [(MemoryShelf, String, String, [String: String])] = [
            (.rules, "Before publishing", "Ask me before publishing anything outside the studio.", ["trigger": "publish", "mode": "Ask first"]),
            (.places, "Project folder", "Work in the studio folder. Put exports in its Results folder.", ["path": "/tmp/example-studio", "role": "work in"]),
            (.people, "Robin", "Robin reviews the illustrations on Thursdays.", ["role": "Illustrator"]),
            (.choices, "Shelf material", "Use birch for the reading room shelves.", [:]),
            (.howtos, "Review a proposal", "Show me the preview first, then the costs, then the open questions.", [:])
        ]
        for (shelf, subject, text, fields) in specimens {
            _ = try writeMemoryEntry(.init(spaceID: spaceID, shelf: shelf, subject: subject, text: text, origin: .you, sources: ["Invented demo conversation"], fields: fields))
        }
        _ = try proposeMemoryEntry(spaceID: spaceID, shelf: .choices, subject: "Shelf material", text: "Use oak for the reading room shelves.", source: "Invented renovation reply", reason: "This differs from your current choice", origin: .facienda)
        for index in 1...3 {
            _ = try writeMemoryEntry(.init(spaceID: spaceID, shelf: .places, subject: "Research room \(index)", text: "Room \(index) holds a different experiment.", origin: .you, sources: ["Invented research group"], fields: ["floor": "2", "instrument": "Station \(index)"]))
        }
        try proposeMemoryCollections(spaceID: spaceID)
        let shared = try writeMemoryEntry(.init(spaceID: spaceID, shelf: .choices, subject: "Useful answers", text: "Start with the next step, then give the reason.", origin: .you, sources: ["Invented user preference"]))
        try shareMemoryEntry(shared.id, spaceID: spaceID)
        for index in 1...3 {
            _ = try writeMemoryEntry(.init(spaceID: spaceID, shelf: .people, subject: "Illustrator \(index)", text: "Reviews the fictional illustration set.", origin: .you, sources: ["Invented studio"], fields: ["collection": "Set \(index)", "review day": "Thursday"]))
        }
        try proposeMemoryCollections(spaceID: spaceID)
        if let section = try memorySections(spaceID: spaceID).first(where: { $0.fields.contains("collection") }) {
            try acceptMemorySection(section.id, spaceID: spaceID, name: "Illustration reviewers")
        }
        try db.write { db in
            try MemorySituation(id: "build", spaceId: nil, name: "Checks passed", description: "An implementation is ready to review", embedding: Data()).save(db)
            for (index, text) in ["Show me the changes.", "I’ll try the preview."].enumerated() {
                try MemoryMove(id: "demo-move-\(index)", spaceId: spaceID, situationId: "build", text: text, stage: index == 0 ? .accepted : .offered,
                               isYourStep: index == 1, seen: index == 0 ? 8 : 3, offered: index == 0 ? 6 : 1, used: index == 0 ? 4 : 0, ignored: 0,
                               embedding: Data(), createdAt: Date(), updatedAt: Date()).save(db)
            }
            try MemoryRoutine(id: "demo-routine", spaceId: spaceID, name: "Review and try", state: .live,
                              steps: [.init(moveId: "demo-move-0", text: "Show me the changes.", mode: .oneClick), .init(text: "Try the preview", action: .yourStep), .init(text: "Note what you would change", mode: .automatic, action: .reminder)], seen: 4, createdAt: Date()).save(db)
            // Suggestions belong to the task's latest result, when it has one.
            let result = try String.fetchOne(db, sql: "SELECT id FROM events WHERE rowid = (\(Self.latestSourceID("?")))", arguments: [taskID]) ?? "demo-result"
            try db.execute(sql: "INSERT INTO taskMoveContexts VALUES (?, ?, 'build') ON CONFLICT(taskId) DO NOTHING", arguments: [taskID, result])
        }
        let examples = [
            "For the studio's book covers, show the composition before choosing type. Last time a typography review was wasted when the composition changed.",
            "The cover review worked well when we agreed on the composition, checked the lettering at actual size, and only then exported the final files.",
            "For our reading-room shelves, compare material samples in the room before ordering. We chose birch after seeing the oak sample against the floor.",
            "The greenhouse measurements drifted in the afternoon sun. Calibrate against the reference before collecting a batch, and repeat that check when the light changes."
        ]
        for (index, text) in examples.enumerated() {
            try captureUtterance(id: "demo-understanding-\(spaceID)-\(index)", text: text, source: "Invented demo conversation \(index + 1)", kind: .userReply, taskID: taskID, spaceID: spaceID, at: Date().addingTimeInterval(Double(index - 4) * 86400))
        }
        try prepareMemoryEvidence(spaceID: spaceID)
        try db.write { db in
            let sources = try MemoryEvidence.fetchAll(db, sql: "SELECT * FROM memoryEvidence WHERE spaceId = ? AND sourceId LIKE 'utterance:demo-understanding-%' ORDER BY at", arguments: [spaceID])
            let samples: [(MemoryUnderstanding.Kind, String, String, String, [MemoryUnderstanding.Step], [Int])] = [
                (.process, "Review from structure to detail", "Agree on the composition before polishing typography. Review at actual size before exporting, so detailed work survives the next decision.", "When a studio design needs approval before production.", [
                    .init(action: "Agree on the composition", why: "Structural changes can invalidate later typography work.", check: "The reviewer accepts the layout."),
                    .init(action: "Check lettering at actual size", why: "A zoomed preview hides readability problems.", check: "The cover reads clearly at its intended size."),
                    .init(action: "Export after review", why: "The final files should represent the agreed design.", check: "The exported version matches the approved preview.")
                ], [0, 1]),
                (.thing, "Material choices depend on their setting", "The reading room's floor changed the shelf decision: a sample in the actual room was more useful than choosing a wood in isolation.", "When selecting a visible material for the reading room.", [], [2]),
                (.process, "Recheck the measurement baseline", "Calibrate before a measurement batch and again when the light changes. Afternoon drift is a reason to question the measurement conditions before interpreting the plants.", "Greenhouse measurements affected by changing sunlight.", [
                    .init(action: "Compare against the reference", why: "The sensor needs a known baseline.", check: "The reading agrees with the reference."),
                    .init(action: "Repeat after the light changes", why: "The observed afternoon drift may recur.", check: "The reference check still holds before another batch.")
                ], [3])
            ]
            for (kind, subject, summary, applies, steps, indices) in samples {
                let citations = indices.filter { sources.indices.contains($0) }.map { MemoryUnderstanding.Citation(evidenceId: sources[$0].id, quote: sources[$0].text) }
                try MemoryUnderstanding(id: "demo-understanding-" + MemoryEntry.key(subject), spaceId: spaceID, kind: kind, subject: subject, subjectKey: MemoryEntry.key(subject), summary: summary,
                    explanation: "This interpretation connects the user's stated problem with the sequence they described. It remains specific to the evidence shown below.", appliesWhen: applies,
                    exceptions: ["A different context needs a fresh check."], steps: steps, questions: [], citations: citations, connections: [], confidence: indices.count > 1 ? "supported" : "tentative",
                    state: .inferred, revision: 1, sourceRevision: 1, model: "Demo", updatedAt: Date(), embedding: Data()).insert(db)
            }
            try db.execute(sql: "UPDATE memoryEvidence SET processedAt = ? WHERE spaceId = ?", arguments: [Date(), spaceID])
        }
        let context = try memoryAgentContext(taskID: taskID, query: "Preview")
        try recordMemoryDelivery(taskID: taskID, kind: "Task started", text: context.index + "\n" + context.rules)
    }
}
#endif
