import NoFeedSocialCore
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct NotificationDetailView: View {
    let displayItem: DisplayNotificationItem
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                LabeledContent("Network", value: displayItem.item.network.displayName)

                VStack(alignment: .leading, spacing: 8) {
                    let displayText = displayItem.item.target?.text ?? (displayItem.item.target?.imageURL != nil ? "" : displayItem.item.text)
                    if let targetURL {
                        LabeledContent("Content") {
                            HStack(spacing: 4) {
                                if !displayText.isEmpty {
                                    Text(displayText)
                                        .foregroundStyle(.primary)
                                }
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            openURL(targetURL)
                        }
                    } else {
                        LabeledContent("Content") {
                            if !displayText.isEmpty {
                                Text(displayText)
                            }
                        }
                    }

                    if let imageURL = displayItem.item.target?.imageURL {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case let .success(image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 200, maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            case .failure, .empty:
                                EmptyView()
                            @unknown default:
                                EmptyView()
                            }
                        }
                    }
                }
            }

            if !displayItem.item.actors.isEmpty {
                Section("People") {
                    ForEach(displayItem.item.actors, id: \.id) { actor in
                        if let url = profileURL(for: actor) {
                            Link(destination: url) {
                                PersonRow(actor: actor)
                            }
                        } else {
                            PersonRow(actor: actor)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .navigationTitle(title)
    }

    private var title: String {
        switch displayItem.item.type {
        case .mention: "Mention"
        case .reply: "Reply"
        case .reaction:
            displayItem.item.text.localizedCaseInsensitiveContains("retweet") ? "Retweet" : "Like"
        case .follow: "Follow"
        case .unknown: "Notification"
        }
    }

    private var usernames: String {
        let names = displayItem.item.actors.map { actor in
            actor.username ?? actor.id
        }
        return names.isEmpty ? "Unknown" : names.joined(separator: ", ")
    }

    private var content: String {
        displayItem.item.target?.text ?? displayItem.item.text
    }

    private var targetURL: URL? {
        guard let sourceId = displayItem.item.sourceId else { return nil }
        switch displayItem.item.network {
        case .farcaster:
            let hash = sourceId.hasPrefix("0x") ? sourceId : "0x\(sourceId)"
            guard hash.range(of: #"^0x[0-9a-fA-F]+$"#, options: .regularExpression) != nil else {
                return nil
            }
            return URL(string: "https://farcaster.xyz/~/conversations/\(hash)")
        case .x:
            guard displayItem.item.target?.id != nil,
                  sourceId.allSatisfy(\.isNumber), !sourceId.isEmpty else {
                return nil
            }
            return URL(string: "https://x.com/i/status/\(sourceId)")
        case .instagram:
            return displayItem.item.target?.url
        case .debug:
            return nil
        }
    }

    private func profileURL(for actor: NotificationActor) -> URL? {
        guard let username = actor.username else { return nil }
        switch actor.network {
        case .farcaster:
            return URL(string: "https://farcaster.xyz/\(username)")
        case .x:
            return URL(string: "https://x.com/\(username)")
        case .instagram:
            return URL(string: "https://www.instagram.com/\(username)/")
        case .debug:
            return nil
        }
    }
}

private struct PersonRow: View {
    let actor: NotificationActor

    var body: some View {
        HStack(spacing: 12) {
            DetailActorAvatar(actor: actor)

            HStack(spacing: 6) {
                DetailNetworkUsernameBadge(network: actor.network)

                Text(actor.username ?? actor.id)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 1)
    }
}

private struct DetailNetworkUsernameBadge: View {
    let network: SocialNetwork

    var body: some View {
        Group {
            if let image = detailNetworkBadgeImage(named: network.badgeAssetName) {
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
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }
}

private extension SocialNetwork {
    var badgeAssetName: String {
        switch self {
        case .x:
            "XBadge"
        case .farcaster:
            "FarcasterBadge"
        case .instagram:
            "InstagramBadge"
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
        case .debug:
            .orange
        }
    }
}

private func detailNetworkBadgeImage(named name: String) -> Image? {
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

private struct DetailActorAvatar: View {
    let actor: NotificationActor

    var body: some View {
        Group {
            if let avatarURL = actor.avatarURL {
                AsyncImage(url: avatarURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty, .failure:
                        DetailAvatarFallback(actor: actor)
                    @unknown default:
                        DetailAvatarFallback(actor: actor)
                    }
                }
            } else {
                DetailAvatarFallback(actor: actor)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
    }
}

private struct DetailAvatarFallback: View {
    let actor: NotificationActor

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.18))

            Text(initial)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var initial: String {
        let value = actor.username ?? actor.displayName ?? actor.id
        return value.first.map { String($0).uppercased() } ?? "?"
    }
}
