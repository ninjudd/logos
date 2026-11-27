// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Logos",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Logos",
            path: "Sources/Logos",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
