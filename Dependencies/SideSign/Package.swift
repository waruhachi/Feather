// swift-tools-version: 6.0
//
// Vendored from SideStore/Catalyst (Dependencies/SideSign), AGPL-3.0.
// Odysseus only uses the library: the CLI and test targets are left out.
//

import PackageDescription

let package = Package(
    name: "SideSign",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1)
    ],

    products: [
        .library(
            name: "SideSign",
            type: .static,
            targets: ["SideSign"]
        ),
        .library(
            name: "SideSign-Dynamic",
            type: .dynamic,
            targets: ["SideSign"]
        ),
    ],

    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git",    from: "3.12.3"),

        .package(path: "../CodeSignKit"),
        .package(path: "../GSACryptoKit"),
        .package(url: "https://github.com/SideStore/libdeflate",      revision: "da6c7dae03b78dc71af973664575e4209786fbfe"),
        .package(url: "https://github.com/mahee96/AnisetteKit.git",   revision: "db8b41022697b6c19be8a5f01a1ce834145a2a26"),

//        .package(name: "CodeSignKit",  path: "../../local/CodeSignKit"),
//        .package(name: "GSACryptoKit", path: "../../local/GSACryptoKit"),
//        .package(name: "libdeflate",   path: "../../local/libdeflate"),
//        .package(name: "AnisetteKit",   path: "../../local/AnisetteKit")
    ],

    targets: [
        .target(
            name: "SideSign",
            dependencies: [
                .product(name: "libdeflate", package: "libdeflate"),
                .product(name: "Crypto", package: "swift-crypto"),
                "AnisetteKit",
                "CodeSignKit",
                "GSACryptoKit"
            ],
            path: "Sources"
        )
    ],

    swiftLanguageModes: [.v6],
    cLanguageStandard: .gnu11
)
