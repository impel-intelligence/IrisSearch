// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "IrisSearch",
    platforms: [
        .macOS(.v15),
        .iOS(.v26)
    ],
    
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(name: "IrisCommon", targets: ["IrisCommon"]),
        .library(name: "IrisSearch", targets: ["IrisSearch"]),
        .library(name: "Digester", targets: ["Digester"]),
        
        // Embedding Providers
        .library(name: "CoreMLEmbedder", targets: ["CoreMLEmbedder"]),
        .library(name: "AppleIntelligenceEmbedder", targets: ["AppleIntelligenceEmbedder"])
    ],
    traits: [
        .trait(name: "pdf_inspector"),
        .default(enabledTraits: ["pdf_inspector"])
    ],
    dependencies: [
        .package(url: "https://github.com/impel-intelligence/SwiftFaiss", from: "0.4.1"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.13.6"),
        .package(url: "https://github.com/apple/swift-log", from: "1.6.0"),
        
        .package(path: "/Users/taylorlineman/Developer/git/pdf-inspector")
//        .package(url: "https://github.com/jkrukowski/swift-embeddings", from: "0.1.0")
    ],
    targets: [
        // Common
        .target(
            name: "IrisCommon",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(name: "IrisCommonTests", dependencies: ["IrisCommon", "TestUtilities"]),
        
        // Test Utilities
        .target(
            name: "TestUtilities",
            dependencies: ["IrisCommon", "IrisSearch"],
            path: "Tests/Utilities" // Placed inside the Tests folder to keep Sources clean
        ),

        // Search
        .target(
            name: "IrisSearch",
            dependencies: [
                "IrisCommon",
                "SwiftFaiss",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "IrisSearchTests",
            dependencies: [
                "IrisSearch",
                "TestUtilities",
                "AppleIntelligenceEmbedder"
            ],
            resources: [
                .copy("../Test Documents")
            ]
        ),
        
        // Digester
        .target(
            name: "Digester",
            dependencies: [
                "IrisCommon",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PDFInspector", package: "pdf-inspector", condition: .when(traits: ["pdf_inspector"])),
                .product(name: "pdf_inspectorFFI", package: "pdf-inspector", condition: .when(traits: ["pdf_inspector"]))
            ]
        ),
        .testTarget(
            name: "DigesterTests",
            dependencies: [
                "Digester",
                "TestUtilities",
                .product(name: "SwiftSoup", package: "SwiftSoup")
            ],
            resources: [
                .copy("../Test Documents")
            ]
        ),
        
        // Integration Tests
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "Digester",
                "IrisSearch",
                "TestUtilities",
                "AppleIntelligenceEmbedder"
            ],
            resources: [
                .copy("../Test Documents")
            ]
       ),
         
        // MARK: Embeddings
        .target(
            name: "CoreMLEmbedder",
            dependencies: ["IrisCommon"],
            path: "Sources/Embedder/CoreML",
        ),
        
        .testTarget(
            name: "CoreMLEmbedderTests",
            dependencies: ["CoreMLEmbedder", "TestUtilities"],
            resources: [
                .copy("../Test Documents/ml"),
            ]
        ),
    
        .target(
            name: "AppleIntelligenceEmbedder",
            dependencies: ["IrisCommon"],
            path: "Sources/Embedder/AppleIntelligence",
        ),
    ]
)
