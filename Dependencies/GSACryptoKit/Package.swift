// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GSACryptoKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "GSACryptoKit", targets: ["GSACryptoKit"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3")
    ],
    targets: [
        .target(name: "GSACryptoKit", dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto")
        ], path: "Sources")
    ]
)
