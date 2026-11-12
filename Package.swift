// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CSensors", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "TokenBarCore", dependencies: ["CSensors"]),
        .executableTarget(name: "TokenBar", dependencies: ["TokenBarCore"]),
        .executableTarget(name: "tokenbar-fan", dependencies: ["CSensors"]),
        .testTarget(name: "TokenBarCoreTests", dependencies: ["TokenBarCore"]),
    ]
)
