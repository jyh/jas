// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MandelbrotExplorer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MandelbrotExplorer",
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-framework", "Metal", "-framework", "MetalKit", "-framework", "AppKit"]),
            ]
        ),
    ]
)
