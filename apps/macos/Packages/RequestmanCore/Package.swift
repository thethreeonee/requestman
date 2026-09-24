// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RequestmanCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "RequestmanCore", targets: ["RequestmanCore"])],
    targets: [
        .target(name: "RequestmanCore"),
        .testTarget(name: "RequestmanCoreTests", dependencies: ["RequestmanCore"])
    ]
)
