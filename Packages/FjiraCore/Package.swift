// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FjiraCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FjiraCore", targets: ["FjiraCore"]),
        .library(name: "FjiraUI", targets: ["FjiraUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(name: "FjiraCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "FjiraUI", dependencies: ["FjiraCore"]),
        .testTarget(name: "FjiraCoreTests", dependencies: ["FjiraCore"]),
        .testTarget(name: "FjiraUITests", dependencies: ["FjiraUI", "FjiraCore"])
    ]
)
