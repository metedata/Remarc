// swift-tools-version: 6.0

import PackageDescription
import Foundation

// Opt in explicitly: the upstream build retains its full speech backend.
let venturaBuild = Context.environment["REMARC_VENTURA"] == "1"

let package = Package(
    name: "RemarcFeature",
    platforms: [.macOS(venturaBuild ? .v13 : .v14)],
    products: [
        .library(
            name: "RemarcFeature",
            targets: ["RemarcFeature"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
        .package(url: "https://github.com/linearmouse/AppMover", branch: "master"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0")
    ] + (venturaBuild ? [] : [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5")
    ]),
    targets: [
        .target(
            name: "RemarcFeature",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "AppMover", package: "AppMover"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ] + (venturaBuild ? [] : [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]),
            resources: [
                .process("Resources")
            ],
            swiftSettings: venturaBuild ? [.define("REMARC_VENTURA")] : []
        ),
        .testTarget(
            name: "RemarcFeatureTests",
            dependencies: [
                "RemarcFeature"
            ],
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
