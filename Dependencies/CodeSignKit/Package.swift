// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CodeSignKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "CodeSignKit", targets: ["CodeSignKit"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.6.0")
    ],
    targets: [
        .target(name: "CodeSignKit", dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
            .product(name: "SwiftASN1", package: "swift-asn1")
        ], path: "Sources")
    ]
)
