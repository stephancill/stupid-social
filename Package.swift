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
            dependencies: [
                "NoFeedSocialPush",
                "JuiceboxSdk",
                "StupidMetrics",
            ],
            // TelegramSchema.tl, and TelegramAPI.json when scripts/telegram-api-config.py has written it.
            resources: [.process("Resources")]
        ),
        .target(
            name: "NoFeedSocialPush"
        ),
        // XChat key recovery. Vendored by scripts/vendor-juicebox.sh; don't edit these by hand.
        .target(
            name: "JuiceboxSdk",
            dependencies: ["JuiceboxSdkFfi"],
            path: "Vendor/JuiceboxSdk/Sources/JuiceboxSdk",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Anonymous usage metrics. Vendored by scripts/vendor-stupid-metrics.sh; don't edit these by hand.
        .target(
            name: "StupidMetrics",
            path: "Vendor/StupidMetrics/Sources/StupidMetrics"
        ),
        .binaryTarget(
            name: "JuiceboxSdkFfi",
            path: "Vendor/JuiceboxSdk/JuiceboxSdkFfi.xcframework"
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
