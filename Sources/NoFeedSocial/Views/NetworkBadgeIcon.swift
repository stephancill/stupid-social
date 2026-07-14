import NoFeedSocialCore
import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

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
        case .debug:
            .orange
        }
    }
}

func networkBadgeImage(named name: String) -> Image? {
    guard let path = Bundle.main.path(forResource: name, ofType: "png") else { return nil }

    #if os(iOS)
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        return Image(uiImage: image)
    #elseif os(macOS)
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        return Image(nsImage: image)
    #else
        return nil
    #endif
}
