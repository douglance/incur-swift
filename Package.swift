// swift-tools-version: 6.0

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Incur",
    platforms: [
        .macOS(.v13),
        .iOS(.v18),
        .tvOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "Incur",
            targets: ["Incur"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
    ],
    targets: [
        .macro(
            name: "IncurMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "Incur",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                "IncurMacros",
            ]
        ),
        .executableTarget(
            name: "IncurExample",
            dependencies: ["Incur"]
        ),
        .executableTarget(
            name: "IncurGen",
            dependencies: ["Incur"]
        ),
        .testTarget(
            name: "IncurTests",
            dependencies: ["Incur"]
        ),
        .testTarget(
            name: "IncurMacrosTests",
            dependencies: [
                "IncurMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
