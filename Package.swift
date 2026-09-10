// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Softclose",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Softclose",
            path: "Sources/Softclose",
            exclude: ["Shaders"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
