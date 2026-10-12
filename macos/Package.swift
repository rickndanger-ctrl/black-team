// swift-tools-version:6.0
import PackageDescription

// Black Team for macOS. BlackTeamKit is the app without a window (models, engine,
// tools, memory); BlackTeamUI is the SwiftUI interface; BlackTeam is the app itself.
#if os(macOS)
let platformTargets: [Target] = [
    .target(name: "BlackTeamUI", dependencies: ["BlackTeamKit"], path: "Sources/BlackTeamUI",
            resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "BlackTeam", dependencies: ["BlackTeamUI"], path: "Sources/BlackTeam",
                      swiftSettings: [.swiftLanguageMode(.v5)]),
]
let platformProducts: [Product] = [.executable(name: "BlackTeam", targets: ["BlackTeam"])]
#else
let platformTargets: [Target] = []
let platformProducts: [Product] = []
#endif

let package = Package(
    name: "BlackTeam",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BlackTeamKit", targets: ["BlackTeamKit"]),
        // The command: `black-team`. The old name stays as a second product of the same program.
        .executable(name: "black-team", targets: ["BlackTeamCLI"]),
        .executable(name: "black-team-cli", targets: ["BlackTeamCLI"]),
    ] + platformProducts,
    // The only dependency, used on Linux where CryptoKit does not exist.
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        .target(name: "BlackTeamKit",
                dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))],
                path: "Sources/BlackTeamKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The terminal parts that need no model or screen: line editor, keys, history, slash commands, prompt, one-shot arguments.
        .target(name: "BlackTeamTerminal", path: "Sources/BlackTeamTerminal", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "BlackTeamCLI", dependencies: ["BlackTeamKit", "BlackTeamTerminal"], path: "Sources/BlackTeamCLI",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BlackTeamKitTests", dependencies: ["BlackTeamKit"], path: "Tests/BlackTeamKitTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BlackTeamTerminalTests", dependencies: ["BlackTeamTerminal"], path: "Tests/BlackTeamTerminalTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ] + platformTargets
)
