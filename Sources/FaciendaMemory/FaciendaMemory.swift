import Foundation
import FaciendaCore
import FaciendaBridge

@main struct FaciendaMemory {
    static func main() async {
        do {
            let request = try MemoryInferenceRequest(JSONDecoder().decode(JSONValue.self, from: FileHandle.standardInput.readDataToEndOfFile()))
            // The model the user chose for background work, passed by the process that asks.
            let arguments = CommandLine.arguments
            func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
            let model = value("--model") ?? MemoryInferenceRequest.model
            if value("--provider") == AgentProvider.claude.rawValue {
                let profile = EphemeralMemoryInference.profile
                let content = try await ClaudeBackground.complete(system: profile.baseInstructions + "\n\n" + profile.developerInstructions, model: model,
                                                                  message: request.request.json, schema: request.outputSchema)
                try request.validate(content)
                print(JSONValue.object(["content": .string(content), "model": .string(model), "provider": .string("claude")]).json)
            } else {
                print(try await EphemeralMemoryInference.run(request, model: model).json)
            }
        } catch {
            FileHandle.standardError.write(Data("Memory inference failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
