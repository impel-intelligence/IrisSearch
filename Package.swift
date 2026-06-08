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
        .library(
            name: "IrisSearch",
            targets: ["IrisSearch"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/impel-intelligence/SwiftFaiss", from: "0.2.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.1")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "IrisSearch",
            dependencies: [
                "SwiftFaiss",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Algorithms", package: "swift-algorithms")
            ]
        ),
        .testTarget(
            name: "IrisSearchTests",
            dependencies: ["IrisSearch"]
        ),
    ]
)
