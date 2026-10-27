// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RetouchStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "RetouchStudio",
            path: "Sources/RetouchStudio"
        )
    ]
)
