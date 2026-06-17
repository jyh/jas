// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Jas",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Persistent map for the id->element index (REFERENCE_GRAPH.md §2.4):
        // TreeDictionary gives O(log n) ops, O(1) structure-sharing copy (so
        // each undo snapshot carries the index in O(1)), and is value-type
        // clean. Backs the Model's IdIndex companion. Mirrors Rust's rpds.
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "JasLib",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
            ],
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
