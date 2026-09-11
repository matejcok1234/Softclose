// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Softclose",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Softclose",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Softclose",
            exclude: ["Shaders"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            // Sparkle is embedded in the bundle at Contents/Frameworks, and
            // SwiftPM doesn't build app bundles, so the search path for it has
            // to be added by hand.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
