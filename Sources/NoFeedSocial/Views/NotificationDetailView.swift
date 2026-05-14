import NoFeedSocialCore
import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

struct NotificationDetailView: View {
    let displayItem: DisplayNotificationItem
    let feedService: FeedService
    @Environment(\.openURL) private var openURL
    @AppStorage("devModeEnabled") private var devModeEnabled = false
    @State private var targetMetrics: NotificationTargetMetrics?
    @State private var isLoadingTargetMetrics = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Network", value: displayItem.item.network.displayName)
                LabeledContent(
                    "Activity",
                    value: DebugRedaction.text(displayItem.item.text, actors: displayItem.item.actors, enabled: devModeEnabled)
                )
            }

            if let target = displayItem.item.target {
                Section("Post") {
                    if let targetMetrics, !targetMetrics.relatedTargets.isEmpty {
                        ForEach(targetMetrics.relatedTargets, id: \.id) { relatedTarget in
                            TargetPostView(
                                target: relatedTarget,
                                fallbackNetwork: displayItem.item.network,
                                fallbackActors: displayItem.item.actors,
                                metrics: nil,
                                isLoadingMetrics: false,
                                targetURL: postURL(for: relatedTarget)
                            ) { url in
                                openURL(url)
                            }
                        }
                    } else {
                        TargetPostView(
                            target: target,
                            fallbackNetwork: displayItem.item.network,
                            fallbackActors: displayItem.item.actors,
                            metrics: targetMetrics,
                            isLoadingMetrics: isLoadingTargetMetrics,
                            targetURL: targetURL
                        ) { url in
                            openURL(url)
                        }
                    }
                }
            } else {
                Section("Content") {
                    Text(DebugRedaction.text(displayItem.item.text, actors: displayItem.item.actors, enabled: devModeEnabled))
                }
            }

            if displayItem.item.type == .reply, let parentTarget = displayItem.item.parentTarget {
                Section("Parent Post") {
                    TargetPostView(
                        target: parentTarget,
                        fallbackNetwork: displayItem.item.network,
                        fallbackActors: displayItem.item.actors,
                        metrics: nil,
                        isLoadingMetrics: false,
                        targetURL: nil
                    ) { url in
                        openURL(url)
                    }
                }
            }

            if !displayItem.item.actors.isEmpty {
                Section("People") {
                    ForEach(displayItem.item.actors, id: \.id) { actor in
                        NavigationLink {
                            ProfileDetailView(actor: actor, feedService: feedService)
                        } label: {
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
        .task(id: displayItem.id) {
            await loadTargetMetrics()
        }
    }

    private var title: String {
        switch displayItem.item.type {
        case .mention: "Mention"
        case .reply: "Reply"
        case .reaction:
            displayItem.item.text.localizedCaseInsensitiveContains("retweet") ? "Retweet" : "Like"
        case .follow: "Follow"
        case .post: "Tweet"
        case .music: "Listening"
        case .unknown: "Notification"
        }
    }

    private var targetURL: URL? {
        guard let target = displayItem.item.target else { return nil }
        return postURL(for: target)
    }

    private func postURL(for target: NotificationTarget) -> URL? {
        switch displayItem.item.network {
        case .farcaster:
            let hash = target.id.hasPrefix("0x") ? target.id : "0x\(target.id)"
            guard hash.range(of: #"^0x[0-9a-fA-F]+$"#, options: .regularExpression) != nil else {
                return nil
            }
            return URL(string: "https://farcaster.xyz/~/conversations/\(hash)")
        case .x:
            guard target.id.allSatisfy(\.isNumber), !target.id.isEmpty
            else {
                return nil
            }
            return URL(string: "https://x.com/i/status/\(target.id)")
        case .instagram:
            return target.url
        case .spotify:
            return target.url
        case .debug:
            return nil
        }
    }

    private func loadTargetMetrics() async {
        guard displayItem.item.target != nil else { return }
        targetMetrics = nil
        isLoadingTargetMetrics = true
        defer { isLoadingTargetMetrics = false }
        targetMetrics = try? await feedService.fetchTargetMetrics(for: displayItem.item)
    }
}

private struct PersonRow: View {
    let actor: NotificationActor
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        HStack(spacing: 12) {
            DetailActorAvatar(actor: actor)

            HStack(spacing: 6) {
                DetailNetworkUsernameBadge(network: actor.network)

                Text(DebugRedaction.actorName(actor, enabled: devModeEnabled))
                    .foregroundStyle(.primary)
            }

            Spacer()

            if let actorTimestamp = actor.timestamp {
                Text(actorTimestamp.compactRelativeTime)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

private struct TargetPostView: View {
    let target: NotificationTarget
    let fallbackNetwork: SocialNetwork
    let fallbackActors: [NotificationActor]
    let metrics: NotificationTargetMetrics?
    let isLoadingMetrics: Bool
    let targetURL: URL?
    let openURL: (URL) -> Void

    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoadingMetrics, metrics == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                postContent
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if let targetURL, !(isLoadingMetrics && metrics == nil) {
                openURL(targetURL)
            }
        }
    }

    private var postContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                if let author = displayAuthor {
                    DetailActorAvatar(actor: author, size: 36)
                } else {
                    DetailNetworkFallbackAvatar(network: fallbackNetwork)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(authorName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        if let username = displayAuthor?.username {
                            Text("@\(DebugRedaction.username(username, enabled: devModeEnabled))")
                        } else {
                            Text(fallbackNetwork.displayName)
                        }

                        if let postedAt = metrics?.postedAt ?? target.postedAt {
                            Text("•")
                            Text(postedAt.compactRelativeTime)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if targetURL != nil {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let text = displayText, !text.isEmpty {
                Text(DebugRedaction.text(text, actors: redactionActors, enabled: devModeEnabled))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !displayImageURLs.isEmpty {
                ImageCarousel(imageURLs: displayImageURLs)
            }

            if isLoadingMetrics {
                loadingRow
            }

            if let likeCount = metrics?.likeCount ?? target.likeCount {
                HStack(spacing: 2) {
                    Image(systemName: "heart")
                    Text(likeCountText(likeCount))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var loadingRow: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var authorName: String {
        guard let author = displayAuthor else { return fallbackNetwork.displayName }
        guard !devModeEnabled else { return "Redacted" }
        return author.displayName ?? author.username ?? author.id
    }

    private var displayAuthor: NotificationActor? {
        metrics?.author ?? target.author
    }

    private var displayText: String? {
        metrics?.text ?? target.text
    }

    private var redactionActors: [NotificationActor] {
        if let author = displayAuthor {
            return fallbackActors + [author]
        }
        return fallbackActors
    }

    private var displayImageURLs: [URL] {
        if let metrics, !metrics.imageURLs.isEmpty {
            return metrics.imageURLs
        }
        if !target.imageURLs.isEmpty {
            return target.imageURLs
        }
        return target.imageURL.map { [$0] } ?? []
    }

    private func likeCountText(_ count: Int) -> String {
        let absoluteCount = abs(count)
        let units: [(threshold: Double, suffix: String)] = [
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1000, "K"),
        ]

        guard let unit = units.first(where: { Double(absoluteCount) >= $0.threshold }) else {
            return "\(count)"
        }

        let scaled = Double(count) / unit.threshold
        let digitsBeforeDecimal = max(1, Int(floor(log10(abs(scaled)))) + 1)
        let fractionDigits = max(0, 2 - digitsBeforeDecimal)
        return String(format: "%.*f%@", fractionDigits, scaled, unit.suffix)
    }
}

private struct ImageCarousel: View {
    let imageURLs: [URL]

    var body: some View {
        if imageURLs.count == 1, let imageURL = imageURLs.first {
            PostImage(url: imageURL)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(imageURLs, id: \.self) { imageURL in
                        PostImage(url: imageURL)
                            .containerRelativeFrame(.horizontal, count: 1, spacing: 10)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

private struct PostImage: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            case .empty:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .failure:
                EmptyView()
            @unknown default:
                EmptyView()
            }
        }
    }
}

private struct DetailNetworkFallbackAvatar: View {
    let network: SocialNetwork

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.18))

            Text(network.badgeFallbackText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 36, height: 36)
        .overlay {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
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
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let avatarURL = actor.avatarURL {
                CachedAsyncImage(url: avatarURL) {
                    DetailAvatarFallback(actor: actor)
                } failure: {
                    DetailAvatarFallback(actor: actor)
                }
            } else {
                DetailAvatarFallback(actor: actor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
    }
}

private struct DetailAvatarFallback: View {
    let actor: NotificationActor
    @AppStorage("devModeEnabled") private var devModeEnabled = false

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
        let value = DebugRedaction.actorName(actor, enabled: devModeEnabled)
        return value.first.map { String($0).uppercased() } ?? "?"
    }
}
