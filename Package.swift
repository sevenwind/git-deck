// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GitDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GitDeck", path: "Sources/GitDeck")
    ]
)
