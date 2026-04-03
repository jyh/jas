// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MandelbrotExplorer",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "MandelbrotLib",
            path: "Sources",
            exclude: ["MandelbrotApp.swift"],
            linkerSettings: [
                .unsafeFlags(["-framework", "Metal", "-framework", "MetalKit", "-framework", "AppKit"]),
            ]
        ),
        .executableTarget(
            name: "MandelbrotExplorer",
            dependencies: ["MandelbrotLib"],
            path: "App",
            linkerSettings: [
                .unsafeFlags(["-framework", "Metal", "-framework", "MetalKit", "-framework", "AppKit"]),
            ]
        ),
        .testTarget(
            name: "MandelbrotTests",
            dependencies: ["MandelbrotLib"],
            path: "Tests"
        ),
    ]
)
