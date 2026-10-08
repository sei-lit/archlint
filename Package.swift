// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "archlint",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "archlint", targets: ["archlint"]),
    ],
    dependencies: [
        // 検査対象のコードと同じ Swift の構文を読むため、Swift 6.4 系の 604 を使う（602 は 6.2 系）
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .target(
            name: "ArchlintCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .executableTarget(name: "archlint", dependencies: ["ArchlintCore"]),
        .testTarget(name: "ArchlintCoreTests", dependencies: ["ArchlintCore"]),
    ]
)
