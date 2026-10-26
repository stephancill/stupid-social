import NoFeedSocialCore
import SwiftUI
import UIKit

struct NetworkBadgeIcon: View {
    let network: SocialNetwork
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = networkBadgeImage(named: network.badgeAssetName) {
                image
                    .resizable()
                    .interpolation(.high)
            } else {
                Text(network.badgeFallbackText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(network.badgeForegroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(network.badgeBackgroundColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(3, size / 4), style: .continuous))
        .accessibilityLabel(network.displayName)
    }
}

extension SocialNetwork {
    var badgeAssetName: String {
        switch self {
        case .x:
            "XBadge"
        case .farcaster:
            "FarcasterBadge"
        case .instagram:
            "InstagramBadge"
        case .spotify:
            "SpotifyBadge"
        case .bluesky:
            "BlueskyBadge"
        case .github:
            "GitHubBadge"
        case .apron:
            "ApronBadge"
        case .debug:
            "DebugBadge"
        }
    }

    var badgeFallbackText: String {
        switch self {
        case .x:
            "X"
        case .farcaster:
            "F"
        case .instagram:
            "I"
        case .spotify:
            "S"
        case .bluesky:
            "B"
        case .github:
            "GH"
        case .apron:
            "A"
        case .debug:
            "D"
        }
    }

    var badgeForegroundColor: Color {
        switch self {
        case .x:
            .black
        case .farcaster:
            .white
        case .instagram:
            .white
        case .spotify:
            .black
        case .bluesky:
            .white
        case .github:
            .white
        case .apron:
            .white
        case .debug:
            .white
        }
    }

    var badgeBackgroundColor: Color {
        switch self {
        case .x:
            .white
        case .farcaster:
            Color(red: 0.52, green: 0.36, blue: 0.80)
        case .instagram:
            Color(red: 0.88, green: 0.21, blue: 0.44)
        case .spotify:
            Color(red: 0.12, green: 0.73, blue: 0.26)
        case .bluesky:
            Color(red: 0.06, green: 0.49, blue: 0.98)
        case .github:
            Color(red: 0.14, green: 0.16, blue: 0.19)
        case .apron:
            .orange
        case .debug:
            .orange
        }
    }
}

/// Decoded badges, so drawing a row doesn't read the PNG from disk each time (seen while scrolling the feed).
@MainActor private var networkBadgeImages: [String: UIImage] = [:]

@MainActor
func networkBadgeImage(named name: String) -> Image? {
    if let cached = networkBadgeImages[name] {
        return Image(uiImage: cached)
    }
    guard let path = Bundle.main.path(forResource: name, ofType: "png") else { return nil }

    guard let image = UIImage(contentsOfFile: path) else { return nil }
    networkBadgeImages[name] = image
    return Image(uiImage: image)
}
