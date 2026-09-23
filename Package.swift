// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonospaceNotes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MonospaceNotes", path: "Sources/MonospaceNotes"),
        .testTarget(name: "MonospaceNotesTests", dependencies: ["MonospaceNotes"], path: "Tests/MonospaceNotesTests"),
    ]
)
