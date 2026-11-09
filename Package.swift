// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "StupidSocial",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        // A stupid-app project contains one library product per app/extension bundle.
        .library(
            name: "StupidSocial",
            targets: ["StupidSocial"]
        ),
        .library(
            name: "StupidSocialNotificationService",
            targets: ["StupidSocialNotificationService"]
        ),
    ],
    dependencies: [
        // The chat framework (docs/TECHNICAL_DESIGN.md § Chat Framework).
        .package(url: "https://github.com/stephancill/stupid-chatkit", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "StupidSocial",
            dependencies: ["StupidSocialCore", "StupidSocialPush", .product(name: "StupidChatKit", package: "stupid-chatkit")]
        ),
        .target(
            name: "StupidSocialCore",
            dependencies: [
                .product(name: "StupidChatKit", package: "stupid-chatkit"),
                "StupidSocialPush",
                "JuiceboxSdk",
                "StupidMetrics",
            ],
            // TelegramSchema.tl, and TelegramAPI.json when scripts/telegram-api-config.py has written it.
            resources: [.process("Resources")]
        ),
        .target(
            name: "StupidSocialPush",
            dependencies: [.product(name: "StupidChatKit", package: "stupid-chatkit")]
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
            name: "StupidSocialNotificationService",
            dependencies: ["StupidSocialPush"]
        ),
        .testTarget(
            name: "StupidSocialTests",
            dependencies: ["StupidSocialCore", "StupidSocialPush"]
        ),
    ]
)
