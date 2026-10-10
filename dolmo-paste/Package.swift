// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dolmo-paste",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DolmoPaste",
            path: "Sources/DolmoPaste",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
