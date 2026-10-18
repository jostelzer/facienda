import AppKit
import FaciendaCore

/// What the Memory page does to the workspace's memory. Forgetting goes on the undo stack like any other change.
extension AppModel {
    /// A note or rule in the user's words, confirmed as it is written.
    func addNote(kind: String, text: String) {
        perform {
            var fact = MemoryFact(kind: kind, text: text, source: "You wrote it in Facienda, \(Date().formatted(.dateTime.day().month().year()))")
            fact.confirmedAt = Date(); fact.spaceId = memorySpace?.id
            try store.remember(fact, source: .user)
            refresh()
        }
    }
    /// A changed wording supersedes the old one and counts as confirmed, whoever wrote the original.
    func correctNote(_ fact: MemoryFact, text: String) {
        perform { try store.correctMemory(fact.id, text: text); refresh() }
    }
    func confirmNote(_ fact: MemoryFact) {
        perform { try store.confirmMemory(fact.id); refresh() }
    }
    func forgetNote(_ fact: MemoryFact, named name: String) {
        perform(undo: name) { try store.forgetMemory(fact.id); refresh() }
    }
    func moveNote(_ fact: MemoryFact, to workspace: Workspace) {
        perform(undo: "Move Note") { try store.moveMemory(fact.id, toSpace: workspace.memorySpaceId); refresh() }
    }
    /// A learned memory the user forgets leaves every recall; Undo brings it back.
    func forgetLearned(_ unit: MemoryUnit, named name: String) {
        perform(undo: name) { try store.forgetMemoryUnit(unit.id); refresh() }
    }
    /// A learned memory the user stands behind becomes a note in the same words, and the observation goes, so the
    /// memory holds it once.
    func confirmLearned(_ unit: MemoryUnit) {
        perform(undo: "Confirm Memory") {
            let kind = ["preference", "person", "procedure"].contains(unit.memoryKind ?? "") ? unit.memoryKind! : "fact"
            var fact = MemoryFact(kind: kind, text: unit.text, taskId: unit.taskId, source: "Learned from your task chats, confirmed \(Date().formatted(.dateTime.day().month().year()))")
            fact.confirmedAt = Date(); fact.spaceId = memorySpace?.id
            try store.remember(fact, source: .user)
            try store.forgetMemoryUnit(unit.id)
            refresh()
        }
    }
    /// Seeds the rules from a text file such as an AGENTS.md: every paragraph that is not a heading becomes one rule.
    func importRules() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.prompt = "Add as rules"
        panel.message = "Each paragraph of the file becomes a rule of this workspace. Headings are left out."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { error = "That file could not be read as text."; return }
        let rules = Self.rules(in: text)
        guard !rules.isEmpty else { error = "No rules were found in \(url.lastPathComponent)."; return }
        perform(undo: "Add Rules") {
            for rule in rules {
                var fact = MemoryFact(kind: FaciendaStore.ruleKind, text: rule, source: "From \(url.lastPathComponent), \(Date().formatted(.dateTime.day().month().year()))")
                fact.confirmedAt = Date(); fact.spaceId = memorySpace?.id
                try store.remember(fact, source: .user)
            }
            refresh()
        }
        notice = "\(rules.count) \(rules.count == 1 ? "rule" : "rules") added from \(url.lastPathComponent)."
    }

    /// Paragraphs of a Markdown file as single lines, without headings; list items count one each.
    static func rules(in text: String) -> [String] {
        var rules: [String] = [], paragraph: [String] = []
        func flush() {
            let line = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { rules.append(line) }
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { flush(); continue }
            if let marker = ["- ", "* ", "+ "].first(where: line.hasPrefix) { flush(); paragraph = [String(line.dropFirst(marker.count))]; continue }
            if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { flush(); paragraph = [String(line[range.upperBound...])]; continue }
            paragraph.append(line)
        }
        flush()
        return rules.map { $0.replacingOccurrences(of: "  ", with: " ") }
    }
}
