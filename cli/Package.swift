// swift-tools-version: 6.0

import PackageDescription

/// The command line for the app's chats on a Mac (`ChatControlServer` in the app). A package of its own, since the
/// app's package builds only for iOS.
let package = Package(
    name: "StupidSocialCLI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "stupid-social", targets: ["stupid-social"]),
    ],
    targets: [
        .executableTarget(name: "stupid-social"),
    ],
)
