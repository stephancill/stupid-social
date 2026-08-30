// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NoFeedSocial",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "NoFeedSocial",
            targets: ["NoFeedSocial"]
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
        .testTarget(
            name: "NoFeedSocialTests",
            dependencies: ["NoFeedSocialCore"]
        ),
    ]
)
