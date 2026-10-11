// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeStatus",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "ClaudeStatus", path: "Sources/ClaudeStatus")
    ]
)
