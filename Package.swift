// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sidekick",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sidekick", targets: ["Sidekick"]),
        .executable(name: "sidekick-cli", targets: ["sidekick-cli"]),
    ],
    targets: [
        // Shared models, provider protocol, store, bridge hub, small utilities.
        .target(name: "SidekickCore"),
        // Claude Code sessions (registry + transcripts + bridge mod sends).
        .target(name: "ClaudeKit", dependencies: ["SidekickCore", "TerminalKit"]),
        // Finding and focusing the terminal tab that hosts a CLI session.
        .target(name: "TerminalKit", dependencies: ["SidekickCore"]),
        // Codex threads (state dbs + rollouts + hooks + `codex queue`).
        .target(name: "CodexKit", dependencies: ["SidekickCore", "TerminalKit"]),
        // HTTP over a Unix socket for the Claude mod, Codex hooks and the CLI.
        .target(name: "BridgeKit", dependencies: ["SidekickCore"]),
        // Codex-format pet packs: pet.json + atlas, rows, frame timings.
        .target(name: "PetKit"),
        .executableTarget(
            name: "Sidekick",
            dependencies: ["SidekickCore", "ClaudeKit", "CodexKit", "BridgeKit", "PetKit", "TerminalKit"],
            resources: [.copy("Resources/Pets")]
        ),
        .executableTarget(name: "sidekick-cli", dependencies: ["SidekickCore", "ClaudeKit", "CodexKit"]),
        .testTarget(name: "ClaudeKitTests", dependencies: ["ClaudeKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CodexKitTests", dependencies: ["CodexKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "BridgeKitTests", dependencies: ["BridgeKit"]),
        .testTarget(name: "PetKitTests", dependencies: ["PetKit"]),
    ],
    swiftLanguageModes: [.v5]
)
