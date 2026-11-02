import Foundation
import GRDB

/// Claude's sidebar groups sessions by folder, so a task in its own folder shows under the folder's ID. The runner
/// files each new task session into one custom group instead, where the user finds every Facienda chat together.
extension FaciendaStore {
    /// The Claude sidebar group Facienda's sessions go into.
    public static let claudeSidebarGroupName = "Facienda"

    static func registerClaudeSidebar(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("claude_sidebar_group") { db in
            try db.execute(sql: "ALTER TABLE libraryState ADD COLUMN claudeSidebarGroup BOOLEAN NOT NULL DEFAULT 1")
        }
    }

    /// Whether the runner files new task sessions into the Facienda group in Claude's sidebar.
    public func groupsClaudeSessions() throws -> Bool {
        try db.read { try Bool.fetchOne($0, sql: "SELECT claudeSidebarGroup FROM libraryState WHERE id = 1") } ?? true
    }

    public func setGroupsClaudeSessions(_ on: Bool) throws {
        try write { try $0.execute(sql: "UPDATE libraryState SET claudeSidebarGroup = ? WHERE id = 1", arguments: [on]) }
    }

    /// What the runner does, alongside a session's settings, to file it into the group. nil when the user turned it off.
    public func claudeSidebarStep(threadId: String) throws -> String? {
        guard try groupsClaudeSessions() else { return nil }
        let name = Self.claudeSidebarGroupName
        return "Also file this session under the Claude sidebar group named exactly \"\(name)\": mcp__ccd_sidebar__move_sessions with session_ids [\"\(threadId)\"] and that group's id, together with the settings calls. Look the id up once with mcp__ccd_sidebar__list_groups, create the group with mcp__ccd_sidebar__create_group (name \"\(name)\") only if it is missing, and reuse the id for later jobs. If the sidebar tools are missing or the move is refused, skip it: it never blocks the task and does not count as a refused step."
    }
}
