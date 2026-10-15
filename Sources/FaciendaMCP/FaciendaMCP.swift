import Foundation
import FaciendaCore
import MCP

@main struct FaciendaMCP {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Facienda: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        let arguments = CommandArguments(args)
        // One mode per command, so a permission rule that allows one command allows nothing else.
        let mode = try HelperPolicy.mode(args)
        if mode == .initialize {
            // Makes an empty library for isolated tests, only in the system temp folder. Nothing else ever makes one.
            let database = try HelperPolicy.database(args, creating: true)
            if FileManager.default.fileExists(atPath: database.path), !HelperPolicy.isLibrary(database) {
                throw StoreError.invalid("\(database.path) is not a Facienda library, so Facienda left it unchanged.")
            }
            _ = try FaciendaStore(url: database)
            print(database.path)
            return
        }
        if mode == .tools {
            // The same tools the MCP server offers, for sessions that reach them through --call.
            print(JSONValue.array(ToolService.definitions.map { definition in
                .object(["name": .string(definition.name), "description": .string(definition.description), "arguments": definition.schema, "readOnly": .bool(definition.readOnly)])
            }).json)
            return
        }
        let database = try HelperPolicy.database(args)
        let workspace = MCPWorkspace(database: database)
        if mode == .claude {
            print(try await ClaudeCommand.run(args: args, store: try await workspace.store()))
            return
        }
        if ["tick", "wait", "instructions"].contains(arguments.value("--runner")), !FileManager.default.fileExists(atPath: database.path) {
            print(RunnerCommand.libraryGone(database.path))
            return
        }
        if mode == .call {
            print(try await RunnerCommand.call(arguments, store: try await workspace.store()))
            return
        }
        if mode == .runner {
            print(try await RunnerCommand.run(args: args, store: try await workspace.store()))
            return
        }
        let server = Server(name: "facienda", version: "0.1.0", capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            let tools = try ToolService.definitions.map { definition in
                let context = definition.name.hasPrefix("facienda_memory_") ? " Pass taskId: your task's Facienda handle from your latest Facienda instructions. Its memory is the only one available to you." : ""
                return Tool(name: definition.name, description: definition.description + context,
                     inputSchema: try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(definition.schema)),
                     annotations: .init(readOnlyHint: definition.readOnly, openWorldHint: false))
            }
            return .init(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let service = ToolService(store: try await workspace.store())
                let data = try JSONEncoder().encode(params.arguments ?? [:])
                let arguments = try JSONDecoder().decode(JSONValue.self, from: data)
                return .init(content: [.text(text: try await service.callWithMemory(params.name, arguments: arguments).json, annotations: nil, _meta: nil)], isError: false)
            } catch { return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true) }
        }
        try await server.start(transport: CompatibleStdioTransport())
        await server.waitUntilCompleted()
    }
}

/// The helper's command line: flags, and flags followed by a value.
struct CommandArguments {
    let all: [String]
    init(_ all: [String]) { self.all = all }

    /// The helper's own path, as the prompts it prints name it.
    var helper: String { URL(fileURLWithPath: all[0]).standardizedFileURL.path }

    func value(_ flag: String) -> String? {
        guard let index = all.firstIndex(of: flag), all.indices.contains(index + 1) else { return nil }
        return all[index + 1]
    }

    func required(_ flag: String) throws -> String {
        guard let result = value(flag), !result.isEmpty else { throw StoreError.invalid("Missing \(flag)") }
        return result
    }
}

/// The library this helper serves. It is opened only if it exists: a missing library is an error, never a new empty one.
private actor MCPWorkspace {
    let database: URL
    private var cached: FaciendaStore?
    init(database: URL) { self.database = database }
    func store() throws -> FaciendaStore {
        if let cached { return cached }
        let store = try HelperPolicy.open(database)
        // Memory the MCP tools trigger runs on the model the user chose for background work.
        store.adoptServiceModel()
        cached = store
        return store
    }
}
