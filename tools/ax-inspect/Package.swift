// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ax-inspect",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ax-inspect",
            path: "Sources"
        )
    ]
)
