import Foundation
import GRDB

extension FaciendaStore {
    /// Every schema change in the order it was made. Feature files register theirs here; never reorder or edit one.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE tasks (
              id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, intention TEXT NOT NULL,
              definitionOfDone TEXT NOT NULL, area TEXT NOT NULL, state TEXT NOT NULL,
              nextAction TEXT NOT NULL, returnAt DATETIME, waitingOn TEXT, checkAt DATETIME,
              automationScope TEXT NOT NULL, brief TEXT NOT NULL, cwd TEXT, snoozeCount INTEGER NOT NULL,
              createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, completedBy TEXT, revision INTEGER NOT NULL
            );
            CREATE TABLE threadLinks (
              id TEXT PRIMARY KEY NOT NULL, taskId TEXT NOT NULL REFERENCES tasks(id), codexThreadId TEXT NOT NULL UNIQUE,
              role TEXT NOT NULL, linkedBy TEXT NOT NULL, title TEXT NOT NULL, preview TEXT NOT NULL,
              lastKnownStatus TEXT NOT NULL, statusSource TEXT NOT NULL, statusVerified BOOLEAN NOT NULL, lastActivityAt DATETIME
            );
            CREATE TABLE events (
              id TEXT PRIMARY KEY NOT NULL, taskId TEXT REFERENCES tasks(id), threadId TEXT,
              source TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, verified BOOLEAN NOT NULL, at DATETIME NOT NULL
            );
            CREATE INDEX events_task ON events(taskId, at);
            CREATE INDEX events_thread ON events(threadId, at);
            CREATE TABLE decisions (
              id TEXT PRIMARY KEY NOT NULL, taskId TEXT NOT NULL REFERENCES tasks(id), question TEXT NOT NULL,
              context TEXT NOT NULL, recommendation TEXT NOT NULL, options TEXT NOT NULL,
              state TEXT NOT NULL, kind TEXT NOT NULL, answer TEXT, answeredAt DATETIME, createdAt DATETIME NOT NULL
            );
            CREATE TABLE memoryFacts (
              id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL, scope TEXT NOT NULL,
              taskId TEXT REFERENCES tasks(id), source TEXT NOT NULL, confirmedAt DATETIME, supersededBy TEXT REFERENCES memoryFacts(id), createdAt DATETIME NOT NULL
            );
            CREATE VIRTUAL TABLE taskSearch USING fts5(id UNINDEXED, title, intention, brief, nextAction, tokenize = 'unicode61 remove_diacritics 2');
            CREATE TRIGGER task_insert AFTER INSERT ON tasks BEGIN
              INSERT INTO taskSearch VALUES (new.id, new.title, new.intention, new.brief, new.nextAction);
            END;
            CREATE TRIGGER task_update AFTER UPDATE ON tasks BEGIN
              DELETE FROM taskSearch WHERE id = old.id;
              INSERT INTO taskSearch VALUES (new.id, new.title, new.intention, new.brief, new.nextAction);
            END;
            CREATE VIRTUAL TABLE threadSearch USING fts5(taskId UNINDEXED, title, preview);
            CREATE TRIGGER link_insert AFTER INSERT ON threadLinks BEGIN
              INSERT INTO threadSearch(rowid, taskId, title, preview) VALUES(new.rowid, new.taskId, new.title, new.preview);
            END;
            CREATE TRIGGER link_update AFTER UPDATE ON threadLinks BEGIN
              DELETE FROM threadSearch WHERE rowid = old.rowid;
              INSERT INTO threadSearch(rowid, taskId, title, preview) VALUES(new.rowid, new.taskId, new.title, new.preview);
            END;
            CREATE TRIGGER link_delete AFTER DELETE ON threadLinks BEGIN DELETE FROM threadSearch WHERE rowid = old.rowid; END;
            """)
        }
        migrator.registerMigration("v2_native_runner") { db in
            try db.execute(sql: """
            CREATE TABLE runnerState (id INTEGER PRIMARY KEY CHECK(id = 1), threadId TEXT NOT NULL, automationId TEXT, lastSeen DATETIME);
            CREATE TABLE dispatches (
              id TEXT PRIMARY KEY, taskId TEXT NOT NULL REFERENCES tasks(id), state TEXT NOT NULL,
              requestedAt DATETIME NOT NULL, runnerId TEXT, threadId TEXT, triggerKey TEXT UNIQUE
            );
            CREATE UNIQUE INDEX dispatch_pending_task ON dispatches(taskId) WHERE state IN ('queued', 'claimed', 'dispatching');
            """)
        }
        migrator.registerMigration("v3_task_display_titles") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN displayTitle TEXT")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN displayTitleSource TEXT")
        }
        migrator.registerMigration("v4_workspace_setup") { db in
            try db.execute(sql: """
            CREATE TABLE workspaceSetup (
              id INTEGER PRIMARY KEY CHECK(id = 1), projectPath TEXT NOT NULL,
              projectId TEXT, challenge TEXT NOT NULL, requestedAt DATETIME NOT NULL,
              verifiedAt DATETIME, runnerId TEXT, automationId TEXT
            );
            """)
        }
        migrator.registerMigration("v5_workspace_memory") { db in
            // Preserve every fact and its old category while removing category-based access.
            try db.execute(sql: "ALTER TABLE memoryFacts RENAME COLUMN scope TO originScope")
        }
        migrator.registerMigration("v6_check_plans") { db in
            try db.execute(sql: """
            CREATE TABLE checkPlans (
              taskId TEXT PRIMARY KEY REFERENCES tasks(id), threadId TEXT NOT NULL,
              revision INTEGER NOT NULL, nextCheck DATETIME NOT NULL, purpose TEXT NOT NULL,
              reason TEXT NOT NULL, paused BOOLEAN NOT NULL, pinned BOOLEAN NOT NULL,
              minimumInterval DOUBLE NOT NULL, deadline DATETIME NOT NULL,
              failures INTEGER NOT NULL, checks INTEGER NOT NULL,
              lastChecked DATETIME, lastOutcome TEXT
            );
            ALTER TABLE dispatches ADD COLUMN kind TEXT;
            ALTER TABLE dispatches ADD COLUMN message TEXT;
            ALTER TABLE dispatches ADD COLUMN checkRevision INTEGER;
            ALTER TABLE dispatches ADD COLUMN availableAt DATETIME;
            """)
        }
        migrator.registerMigration("v7_hindsight_memory") { db in
            try db.execute(sql: """
            CREATE TABLE memorySettings (
              id INTEGER PRIMARY KEY CHECK(id = 1), bankId TEXT NOT NULL,
              endpoint TEXT NOT NULL, enabled BOOLEAN NOT NULL DEFAULT 0, workerModel TEXT,
              configured BOOLEAN NOT NULL DEFAULT 0
            );
            INSERT INTO memorySettings(id, bankId, endpoint) VALUES (1, ?, 'http://127.0.0.1:8888');
            CREATE TABLE memoryDocuments (
              id TEXT PRIMARY KEY, content TEXT NOT NULL, digest TEXT NOT NULL,
              source TEXT NOT NULL, at DATETIME NOT NULL, operationId TEXT NOT NULL,
              state TEXT NOT NULL, leaseUntil DATETIME, attempts INTEGER NOT NULL DEFAULT 0,
              nextAttempt DATETIME NOT NULL, error TEXT
            );
            CREATE INDEX memory_pending ON memoryDocuments(state, nextAttempt);
            """, arguments: ["facienda-" + UUID().uuidString.lowercased()])
        }
        migrator.registerMigration("v8_task_blockers") { db in
            try db.execute(sql: """
            CREATE TABLE taskBlockers (
              id TEXT PRIMARY KEY, taskId TEXT NOT NULL REFERENCES tasks(id), kind TEXT NOT NULL,
              prerequisiteId TEXT REFERENCES tasks(id), title TEXT NOT NULL, sourceReference TEXT NOT NULL,
              criterion TEXT NOT NULL, freshnessSeconds DOUBLE, revision INTEGER NOT NULL,
              status TEXT NOT NULL, evidence TEXT NOT NULL, observedAt DATETIME, removed BOOLEAN NOT NULL DEFAULT 0
            );
            CREATE UNIQUE INDEX blocker_dependency ON taskBlockers(taskId, prerequisiteId) WHERE removed = 0 AND kind = 'task';
            CREATE TABLE taskReadiness (
              taskId TEXT PRIMARY KEY REFERENCES tasks(id), armed BOOLEAN NOT NULL DEFAULT 0,
              revision INTEGER NOT NULL DEFAULT 0, notBefore DATETIME, userInstruction TEXT NOT NULL DEFAULT ''
            );
            """)
        }
        migrator.registerMigration("v9_dispatch_context") { db in
            try db.execute(sql: """
            CREATE TABLE dispatchContext (
              dispatchId TEXT PRIMARY KEY REFERENCES dispatches(id), taskId TEXT NOT NULL REFERENCES tasks(id),
              payload TEXT NOT NULL, savedAt DATETIME NOT NULL
            );
            CREATE INDEX context_task ON dispatchContext(taskId, savedAt);
            """)
        }
        migrator.registerMigration("v10_task_attachments") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN attachments TEXT")
        }
        migrator.registerMigration("v11_project_name_confirmation") { db in
            try db.execute(sql: """
            ALTER TABLE workspaceSetup ADD COLUMN codexProjectId TEXT;
            ALTER TABLE workspaceSetup ADD COLUMN confirmedProjectName TEXT;
            ALTER TABLE workspaceSetup ADD COLUMN projectNameVerifiedAt DATETIME;
            """)
        }
        migrator.registerMigration("v12_thread_snapshots") { db in
            try db.execute(sql: """
            CREATE TABLE threadSnapshots (
              taskId TEXT NOT NULL REFERENCES tasks(id), threadId TEXT NOT NULL,
              payload TEXT NOT NULL, fetchedAt DATETIME NOT NULL,
              PRIMARY KEY(taskId, threadId)
            );
            """)
        }
        migrator.registerMigration("v13_memory_reasoning") { db in
            try db.execute(sql: "ALTER TABLE memorySettings ADD COLUMN workerReasoningEffort TEXT NOT NULL DEFAULT 'high'")
            try db.execute(sql: "UPDATE memorySettings SET workerModel = 'gpt-6-luna' WHERE workerModel IS NULL")
        }
        migrator.registerMigration("v14_memory_local_tls") { db in
            try db.execute(sql: "UPDATE memorySettings SET endpoint = 'https://' || substr(endpoint, 8) WHERE endpoint LIKE 'http://%'")
        }
        registerTaskGroups(&migrator)
        registerWaits(&migrator)
        registerHeadlines(&migrator)
        migrator.registerMigration("task_worker_model") { db in
            try db.execute(sql: """
            ALTER TABLE tasks ADD COLUMN workerModel TEXT;
            ALTER TABLE tasks ADD COLUMN workerReasoningEffort TEXT;
            ALTER TABLE tasks ADD COLUMN workerServiceTier TEXT;
            """)
        }
        registerLibrary(&migrator)
        registerClaude(&migrator)
        registerReading(&migrator)
        registerWorkspaceCovers(&migrator)
        registerGroupFolders(&migrator)
        registerNextSteps(&migrator)
        registerOwnSteps(&migrator)
        registerPlanLines(&migrator)
        registerRetiredRunner(&migrator)
        registerScheduledRunner(&migrator)
        registerRunnerFolder(&migrator)
        registerTaskBoardPlaces(&migrator)
        registerNativeMemory(&migrator)
        registerRecaps(&migrator)
        registerGroupSources(&migrator)
        registerWorkFolder(&migrator)
        registerRunnerRuns(&migrator)
        registerCodexApprovals(&migrator)
        registerServiceModel(&migrator)
        registerHandovers(&migrator)
        registerTaskHandles(&migrator)
        migrator.registerMigration("codex_native_queue") { db in
            try db.execute(sql: "ALTER TABLE dispatches ADD COLUMN codexQueueId TEXT; ALTER TABLE dispatches ADD COLUMN codexQueuePreparedAt DATETIME")
        }
        registerOwnMemories(&migrator)
        registerWorkspaceSources(&migrator)
        registerMemoryPrivacy(&migrator)
        registerMemoryMoves(&migrator)
        registerMemoryEntries(&migrator)
        registerMemoryDiscovery(&migrator)
        registerMemoryCollections(&migrator)
        registerMemoryUnderstanding(&migrator)
        registerUnifiedIntake(&migrator)
        return migrator
    }
}
