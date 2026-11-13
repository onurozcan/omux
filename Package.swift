// swift-tools-version:6.2
import PackageDescription

// Linux builds the parts with no window: the core and the protocol, for the headless session
// host. The app, its updater and its terminal view are macOS only.
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    // What the app and the `omux` command line tool say to each other.
    .target(name: "OmuxCLIProtocol", path: "Sources/OmuxCLIProtocol"),
    // Everything about sessions and agents that needs no window: what the Mac app and the
    // headless session host on Linux are both built on. Foundation only, so it compiles there.
    .target(name: "OmuxCore", path: "Sources/OmuxCore"),
    .testTarget(name: "OmuxCoreTests", dependencies: ["OmuxCore"]),
    // The session host: the protocol, the sessions it keeps, and the socket it answers on.
    .target(name: "OmuxHostKit", dependencies: ["OmuxCore"], path: "Sources/OmuxHostKit"),
    // The host as a program, and the command line that talks to it: `omux-host`.
    .executableTarget(name: "omux-host", dependencies: ["OmuxHostKit"], path: "Sources/omux-host"),
    .testTarget(name: "OmuxHostKitTests", dependencies: ["OmuxHostKit"]),
]

#if os(macOS)
dependencies += [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
]
targets += [
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
]
#endif

let package = Package(
    name: "omux",
    platforms: [.macOS(.v14)],
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v5]
)
