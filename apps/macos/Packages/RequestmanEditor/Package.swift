// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RequestmanEditor",
    platforms: [.macOS(.v14)],
    products: [.library(name: "RequestmanEditor", type: .static, targets: ["RequestmanEditor"])],
    dependencies: [
        .package(url: "https://github.com/CodeEditApp/CodeEditTextView.git", exact: "0.12.1"),
        .package(url: "https://github.com/smittytone/HighlighterSwift.git", exact: "3.1.0")
    ],
    targets: [.target(name: "RequestmanEditor", dependencies: [
        .product(name: "CodeEditTextView", package: "CodeEditTextView"),
        .product(name: "Highlighter", package: "HighlighterSwift")
    ], resources: [.copy("ThirdPartyNotices.md")])]
)
