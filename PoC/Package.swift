// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidecastPoC",
    platforms: [.macOS(.v15)],
    targets: [
        // PoC 1: dump audio-producing processes with PID / bundle ID / responsible process
        .executableTarget(
            name: "procdump",
            path: "Sources/procdump"
        ),
    ]
)
