// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Facienda",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "FaciendaCore", targets: ["FaciendaCore"]),
        .library(name: "FaciendaCompanion", targets: ["FaciendaCompanion"]),
        .library(name: "FaciendaBridge", targets: ["FaciendaBridge"]),
        .executable(name: "facienda-mcp", targets: ["FaciendaMCP"]),
        .executable(name: "facienda-hook", targets: ["FaciendaHook"]),
        .executable(name: "facienda-memory", targets: ["FaciendaMemory"]),
        .executable(name: "facienda-dispatch", targets: ["FaciendaDispatch"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(name: "FaciendaCompanion"),
        .target(name: "FaciendaExceptions"),
        .target(name: "FaciendaCore", dependencies: ["FaciendaExceptions", .product(name: "GRDB", package: "GRDB.swift")],
                resources: [.copy("Resources/Memory")]),
        .target(name: "FaciendaBridge", dependencies: ["FaciendaCore"]),
        .executableTarget(name: "FaciendaMCP", dependencies: ["FaciendaCore", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "FaciendaHook", dependencies: ["FaciendaCore"]),
        .executableTarget(name: "FaciendaMemory", dependencies: ["FaciendaBridge"]),
        .executableTarget(name: "FaciendaDispatch", dependencies: ["FaciendaBridge"]),
        .testTarget(name: "FaciendaCompanionTests", dependencies: ["FaciendaCompanion"]),
        .testTarget(name: "FaciendaCoreTests", dependencies: ["FaciendaCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FaciendaBridgeTests", dependencies: ["FaciendaBridge"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
