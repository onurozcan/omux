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
        // Everything about sessions and agents that needs no window: what the Mac app and the
        // headless session host on Linux are both built on. Foundation only, so it compiles there.
        .target(name: "OmuxCore", path: "Sources/OmuxCore"),
        // The `omux` tool; build.sh puts it in the app bundle at Contents/Resources/bin/omux.
        .executableTarget(name: "omux-cli", dependencies: ["OmuxCLIProtocol"], path: "Sources/omux-cli"),
        .executableTarget(
            name: "omux",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
                "OmuxCLIProtocol",
                "OmuxCore",
            ],
            path: "Sources/omux",
            // build.sh embeds Sparkle.framework in the app bundle; the binary finds it there.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "omuxTests", dependencies: ["omux", "OmuxCore"]),
    ],
    swiftLanguageModes: [.v5]
)
