import Foundation
import Darwin
import FaciendaCore

// Fail open, including malformed stdin, locked DB, or an app not yet initialized.
// A process-level deadline also covers a stalled stdin producer.
DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(90)) { exit(0) }
do {
    let args = CommandLine.arguments
    // Only Facienda's own library (or a test library in the system temp folder), like the helper.
    let url = try HelperPolicy.database(args)
    // No library, nothing to record: a hook never makes one.
    guard FileManager.default.fileExists(atPath: url.path) else { exit(0) }
    var data = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
        data.append(chunk)
        if data.count > 65_536 { exit(0) }
    }
    let store = try FaciendaStore(existing: url, busyTimeout: 0.01, migrate: false)
    if args.contains("--claude") {
        // Claude reads a hook's output as its answer, so this prints nothing: the user decides the prompt in Claude.
        let event = try JSONDecoder().decode(ClaudeHookEvent.self, from: data)
        guard event.status != nil else { exit(0) }
        try event.apply(to: store)
    } else {
        let event = try JSONDecoder().decode(HookEvent.self, from: data)
        if let response = try event.apply(to: store) { print(response.json) }
    }
} catch { /* Hooks must never block or break Codex or Claude. */ }
