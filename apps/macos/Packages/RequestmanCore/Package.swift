// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RequestmanCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RequestmanCore", targets: ["RequestmanCore"]),
        .library(name: "RequestmanProxy", targets: ["RequestmanProxy"]),
        .library(name: "RequestmanCertificates", targets: ["RequestmanCertificates"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.5")
    ],
    targets: [
        .target(name: "RequestmanCore"),
        .target(name: "RequestmanCertificates", dependencies: [
            .product(name: "X509", package: "swift-certificates")
        ]),
        .target(name: "RequestmanProxy", dependencies: [
            "RequestmanCore", "RequestmanCertificates", .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOHTTP1", package: "swift-nio")
        ]),
        .testTarget(name: "RequestmanCoreTests", dependencies: ["RequestmanCore"]),
        .testTarget(name: "RequestmanCertificatesTests", dependencies: ["RequestmanCertificates"]),
        .testTarget(name: "RequestmanProxyTests", dependencies: [
            "RequestmanProxy", "RequestmanCertificates", .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOEmbedded", package: "swift-nio")
        ])
    ]
)
