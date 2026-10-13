// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FjiraCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FjiraCore", targets: ["FjiraCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(name: "FjiraCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "FjiraCoreTests", dependencies: ["FjiraCore"])
    ]
)
