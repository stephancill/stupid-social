// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NoFeedSocial",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        // A stupid-app project contains one library product per app/extension bundle.
        .library(
            name: "NoFeedSocial",
            targets: ["NoFeedSocial"]
        ),
        .library(
            name: "NoFeedSocialNotificationService",
            targets: ["NoFeedSocialNotificationService"]
        ),
    ],
    targets: [
        .target(
            name: "NoFeedSocial",
            dependencies: ["NoFeedSocialCore", "NoFeedSocialPush"]
        ),
        .target(
            name: "NoFeedSocialCore",
            dependencies: ["NoFeedSocialPush"],
            // TelegramSchema.tl, and TelegramAPI.json when scripts/telegram-api-config.py has written it.
            resources: [.process("Resources")]
        ),
        .target(
            name: "NoFeedSocialPush"
        ),
        .target(
            name: "NoFeedSocialNotificationService",
            dependencies: ["NoFeedSocialPush"]
        ),
        .testTarget(
            name: "NoFeedSocialTests",
            dependencies: ["NoFeedSocialCore", "NoFeedSocialPush"]
        ),
    ]
)
