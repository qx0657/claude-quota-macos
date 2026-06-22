// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ClaudeQuotaTray",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClaudeQuotaTray", targets: ["ClaudeQuotaTray"])
    ],
    targets: [
        .target(
            name: "CommonCryptoShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "ClaudeQuotaTray",
            dependencies: ["CommonCryptoShim"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit")
            ]
        )
    ]
)
