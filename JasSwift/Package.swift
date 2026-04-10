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
        .executableTarget(
            name: "SvgRoundtrip",
            dependencies: ["JasLib"],
            path: "Tools"
        ),
        .executableTarget(
            name: "WorkspaceRoundtrip",
            dependencies: ["JasLib"],
            path: "ToolsWorkspace"
        ),
        .executableTarget(
            name: "AlgorithmRoundtrip",
            dependencies: ["JasLib"],
            path: "ToolsAlgorithm"
        ),
        .testTarget(
            name: "JasTests",
            dependencies: ["JasLib"],
            path: "Tests"
        ),
    ]
)
