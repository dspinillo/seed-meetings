// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "seed",
    platforms: [.macOS("14.4")],
    dependencies: [
        // mesma versão pinada pelo Muesli — API validada
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.1")
    ],
    targets: [
        // Núcleo compartilhado: captura, ASR, diarização, resumo, storage, pipeline
        .target(
            name: "SeedKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/SeedKit",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
        // CLI de validação/debug (Fase 0)
        .executableTarget(
            name: "seed-spike",
            dependencies: ["SeedKit"],
            path: "Sources/SeedSpikeCLI",
            exclude: ["Info.plist"],
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SeedSpikeCLI/Info.plist",
                ])
            ]
        ),
        // O app de verdade (Fase 1) — empacotado em dist/Seed.app pelo Makefile
        .executableTarget(
            name: "SeedApp",
            dependencies: ["SeedKit"],
            path: "Sources/SeedApp",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
        // Servidor MCP (Fase 4): expõe as reuniões ao Claude Code
        .executableTarget(
            name: "seed-mcp",
            dependencies: ["SeedKit"],
            path: "Sources/SeedMCP",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
        .testTarget(
            name: "SeedKitTests",
            dependencies: ["SeedKit"],
            path: "Tests/SeedKitTests",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
    ]
)
