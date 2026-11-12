// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TokenBarCore"),
        .executableTarget(name: "TokenBar", dependencies: ["TokenBarCore"]),
        .testTarget(name: "TokenBarCoreTests", dependencies: ["TokenBarCore"]),
    ]
)
