// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Jas",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "JasLib",
            path: "Sources",
            exclude: ["JasApp.swift"]
        ),
        .executableTarget(
            name: "Jas",
            dependencies: ["JasLib"],
            path: "App"
        ),
        .testTarget(
            name: "JasTests",
            dependencies: ["JasLib"],
            path: "Tests"
        ),
    ]
)
