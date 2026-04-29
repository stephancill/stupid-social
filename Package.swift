// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NoFeedSocial",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "NoFeedSocial",
            targets: ["NoFeedSocial"]
        ),
        .executable(
            name: "NoFeedSocialMac",
            targets: ["NoFeedSocialMac"]
        ),
    ],
    targets: [
        .target(
            name: "NoFeedSocial",
            dependencies: ["NoFeedSocialCore"]
        ),
        .target(
            name: "NoFeedSocialCore"
        ),
        .executableTarget(
            name: "NoFeedSocialMac",
            dependencies: ["NoFeedSocial", "NoFeedSocialCore"]
        ),
        .testTarget(
            name: "NoFeedSocialTests",
            dependencies: ["NoFeedSocialCore"]
        ),
    ]
)
