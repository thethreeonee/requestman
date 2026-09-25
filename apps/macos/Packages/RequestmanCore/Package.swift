// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RequestmanCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RequestmanCore", targets: ["RequestmanCore"]),
        .library(name: "RequestmanProxy", targets: ["RequestmanProxy"])
    ],
    dependencies: [.package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0")],
    targets: [
        .target(name: "RequestmanCore"),
        .target(name: "RequestmanProxy", dependencies: [
            "RequestmanCore", .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOHTTP1", package: "swift-nio")
        ]),
        .testTarget(name: "RequestmanCoreTests", dependencies: ["RequestmanCore"]),
        .testTarget(name: "RequestmanProxyTests", dependencies: [
            "RequestmanProxy", .product(name: "NIOEmbedded", package: "swift-nio")
        ])
    ]
)
