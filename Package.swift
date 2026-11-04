// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "omux",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // What the app and the `omux` command line tool say to each other.
        .target(name: "OmuxCLIProtocol", path: "Sources/OmuxCLIProtocol"),
        // The `omux` tool; build.sh puts it in the app bundle at Contents/Resources/bin/omux.
        .executableTarget(name: "omux-cli", dependencies: ["OmuxCLIProtocol"], path: "Sources/omux-cli"),
        // What the app and its keep-awake helper say to each other, and the helper's lease rules.
        .target(name: "OmuxAwakeProtocol", path: "Sources/OmuxAwakeProtocol"),
        // The keep-awake helper; build.sh puts it in the app bundle at Contents/MacOS/omux-awake
        // and registers it as a launch daemon (Contents/Library/LaunchDaemons).
        .executableTarget(name: "omux-awake", dependencies: ["OmuxAwakeProtocol"], path: "Sources/omux-awake"),
        .executableTarget(
            name: "omux",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
                "OmuxCLIProtocol",
                "OmuxAwakeProtocol",
            ],
            path: "Sources/omux",
            // build.sh embeds Sparkle.framework in the app bundle; the binary finds it there.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "omuxTests", dependencies: ["omux", "OmuxAwakeProtocol"]),
    ],
    swiftLanguageModes: [.v5]
)
