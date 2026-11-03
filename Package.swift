// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lipi",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Lipi",
            path: "Sources/Lipi"
        )
    ],
    swiftLanguageModes: [.v5]
)
