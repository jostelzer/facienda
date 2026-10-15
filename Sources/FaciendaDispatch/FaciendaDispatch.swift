import Foundation
import FaciendaCore
import FaciendaBridge

/// Delivers the library's queued Codex work, as a launch agent of the Facienda app, so tasks, replies and due checks
/// reach Codex whether or not Facienda is open. It sleeps on the queue between deliveries.
/// `--database PATH` pins a library; otherwise it follows the one the app uses, wherever that moves.
@main
struct FaciendaDispatch {
    static func main() async {
        setvbuf(stderr, nil, _IOLBF, 0)
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        // A pinned library must be one the helper may serve too: the app's own, an experiment library or a test library.
        let pinned: URL?
        do { pinned = try value("--database").map { _ in try HelperPolicy.database(arguments) } }
        catch { FileHandle.standardError.write(Data("Facienda: \(error.localizedDescription)\n".utf8)); exit(1) }
        // For testing approvals: chats it makes ask before they act, whatever the user's Codex settings say.
        let approvalPolicy = value("--approval-policy")
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "facienda-mcp").path
        if pinned == nil {
            // launchd keeps no output, so the agent writes its own log beside the library's backups, one megabyte at most.
            let file = LibraryHome.supportDirectory.appending(path: "dispatch.log")
            try? FileManager.default.createDirectory(at: LibraryHome.supportDirectory, withIntermediateDirectories: true)
            if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 1_000_000 {
                _ = try? FileManager.default.replaceItemAt(file.appendingPathExtension("old"), withItemAt: file)
            }
            freopen(file.path, "a", stderr)
        }
        let log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data((ISO8601DateFormatter().string(from: Date()) + " " + $0 + "\n").utf8)) }
        // launchd stops the agent with SIGTERM; the queue's hold is given back first so a new one starts at once.
        signal(SIGTERM, SIG_IGN)
        let stopping = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        var current: Task<Void, Never>?
        var currentStore: FaciendaStore?
        // A wait for work does not notice cancelling, so the hold is given back here too: otherwise the next
        // dispatcher, after an update for example, waits out the whole lease before it delivers anything.
        stopping.setEventHandler {
            current?.cancel()
            try? currentStore?.endRunnerTurn(runnerId: CodexDispatcher.runnerId, holder: CodexDispatcher.processHolder)
            Task { try? await Task.sleep(for: .seconds(2)); exit(0) }
        }
        stopping.resume()
        while true {
            let database = pinned ?? LibraryHome.databaseURL
            guard let store = try? HelperPolicy.open(database) else {
                // No library yet, or it moved: look again in a minute.
                try? await Task.sleep(for: .seconds(60)); continue
            }
            log("Dispatching for \(database.path)")
            let dispatcher = CodexDispatcher(store: store, helper: helper, approvalPolicy: approvalPolicy, log: log)
            let running = Task { await dispatcher.run() }
            current = running; currentStore = store
            // Follow the app when the user moves the library or deletes it.
            while !running.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if (pinned ?? LibraryHome.databaseURL) != database || !FileManager.default.fileExists(atPath: database.path) { running.cancel() }
            }
            await running.value
        }
    }
}
