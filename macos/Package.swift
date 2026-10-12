// swift-tools-version:6.0
import PackageDescription

// Black Team for macOS. BlackTeamKit is the app without a window (models, engine,
// tools, memory); BlackTeamUI is the SwiftUI interface; BlackTeam is the app itself.
let package = Package(
    name: "BlackTeam",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BlackTeamKit", targets: ["BlackTeamKit"]),
        .executable(name: "BlackTeam", targets: ["BlackTeam"]),
        .executable(name: "black-team-cli", targets: ["BlackTeamCLI"]),
    ],
    targets: [
        .target(name: "BlackTeamKit", path: "Sources/BlackTeamKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "BlackTeamUI", dependencies: ["BlackTeamKit"], path: "Sources/BlackTeamUI",
                resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "BlackTeam", dependencies: ["BlackTeamUI"], path: "Sources/BlackTeam",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "BlackTeamCLI", dependencies: ["BlackTeamKit"], path: "Sources/BlackTeamCLI",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BlackTeamKitTests", dependencies: ["BlackTeamKit"], path: "Tests/BlackTeamKitTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
