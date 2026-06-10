// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "IrisSearch",
    platforms: [
        .macOS(.v14),
//        .macOS(.v15),
//        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(name: "IrisCommon", targets: ["IrisCommon"]),
        .library(name: "IrisSearch", targets: ["IrisSearch"]),
        .library(name: "Digester", targets: ["Digester"]),
    ],
    dependencies: [
        .package(url: "https://github.com/impel-intelligence/SwiftFaiss", from: "0.2.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0")
    ],
    targets: [
        // Common
        .target(
            name: "IrisCommon",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(name: "IrisCommonTests", dependencies: ["IrisCommon"]),
        
        // Search
        .target(
            name: "IrisSearch",
            dependencies: [
                "IrisCommon",
                "SwiftFaiss",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(name: "IrisSearchTests", dependencies: ["IrisSearch"]),
        
        // Digester
        .target(
            name: "Digester",
            dependencies: ["IrisCommon"]
        ),
        .testTarget(
            name: "DigesterTests",
            dependencies: ["Digester"],
            resources: [
                .copy("Test Documents")
            ]
        )
    ]
)
