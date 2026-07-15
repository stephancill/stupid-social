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
    @State private var targetDetails: NotificationTargetDetails?
    @State private var parentTargetDetails: NotificationTargetDetails?
    @State private var isLoadingTargetDetails = false
    @State private var isLoadingParentTargetDetails = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Network", value: displayItem.item.network.displayName)
                LabeledContent(
                    "Activity",
                    value: DebugRedaction.text(displayItem.item.text, actors: displayItem.item.actors, enabled: devModeEnabled),
                )
            }

            if let parentTarget = displayItem.item.parentTarget,
               let target = displayItem.item.target
            {
                Section("Thread") {
                    ReplyThreadView(
                        parentTarget: parentTarget,
                        replyTarget: target,
                        network: displayItem.item.network,
                        actors: displayItem.item.actors,
                        parentDetails: parentTargetDetails,
                        replyDetails: targetDetails,
                        isLoadingParentDetails: isLoadingParentTargetDetails,
                        isLoadingReplyDetails: displayItem.item.type == .message ? false : isLoadingTargetDetails,
                        parentURL: postURL(for: parentTarget),
                        replyURL: targetURL,
                    ) { url in
                        openURL(url)
                    }
                }
            } else if let target = displayItem.item.target {
                Section(targetSectionTitle) {
                    if displayItem.item.type == .message {
                        MessageBubbleView(
                            target: target,
                            actors: displayItem.item.actors,
                            timestamp: displayItem.item.timestamp,
                            targetURL: targetURL,
                        ) { url in
                            openURL(url)
                        }
                    } else if let targetDetails, !targetDetails.relatedTargets.isEmpty {
                        ForEach(targetDetails.relatedTargets, id: \.id) { relatedTarget in
                            TargetPostView(
                                target: relatedTarget,
                                fallbackNetwork: displayItem.item.network,
                                fallbackActors: displayItem.item.actors,
                                details: nil,
                                isLoadingDetails: false,
                                targetURL: postURL(for: relatedTarget),
                                hidesMediaFallbackText: false,
                                showsFallbackWhileLoading: false,
                                showsInlineLoadingRow: true,
                            ) { url in
                                openURL(url)
                            }
                        }
                    } else {
                        TargetPostView(
                            target: target,
                            fallbackNetwork: displayItem.item.network,
                            fallbackActors: displayItem.item.actors,
                            details: targetDetails,
                            isLoadingDetails: isLoadingTargetDetails,
                            targetURL: targetURL,
                            hidesMediaFallbackText: displayItem.item.type == .message,
                            showsFallbackWhileLoading: false,
                            showsInlineLoadingRow: true,
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
            await loadTargetDetails()
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
        case .message: "Message"
        case .music: "Listening"
        case .unknown: "Notification"
        }
    }

    private var targetSectionTitle: String {
        displayItem.item.type == .message ? "Message" : "Post"
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
        case .bluesky:
            return target.url
        case .debug:
            return nil
        }
    }

    private func loadTargetDetails() async {
        guard displayItem.item.target != nil else { return }
        guard displayItem.item.type != .message else { return }
        targetDetails = nil
        parentTargetDetails = nil

        if let parentTarget = displayItem.item.parentTarget {
            isLoadingParentTargetDetails = true
            parentTargetDetails = try? await feedService.fetchTargetDetails(for: detailItem(target: parentTarget))
            isLoadingParentTargetDetails = false
        }

        isLoadingTargetDetails = true
        defer { isLoadingTargetDetails = false }
        targetDetails = try? await feedService.fetchTargetDetails(for: displayItem.item)
    }

    private func detailItem(target: NotificationTarget) -> NotificationItem {
        NotificationItem(
            id: "detail:\(displayItem.item.id):\(target.id)",
            network: displayItem.item.network,
            accountId: displayItem.item.accountId,
            sourceId: target.id,
            type: displayItem.item.type,
            timestamp: target.postedAt ?? displayItem.item.timestamp,
            text: target.text ?? displayItem.item.text,
            actors: displayItem.item.actors,
            target: target,
        )
    }
}

private struct MessageBubbleView: View {
    let target: NotificationTarget
    let actors: [NotificationActor]
    let timestamp: Date
    let targetURL: URL?
    let openURL: (URL) -> Void

    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if let actor = actors.first {
                DetailActorAvatar(actor: actor, size: 32)
            } else {
                DetailNetworkFallbackAvatar(network: .instagram)
                    .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let actorName {
                    HStack(spacing: 6) {
                        Text(actorName)
                        Text("•")
                        Text(timestamp.compactRelativeTime)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    if let displayText {
                        Text(DebugRedaction.text(displayText, actors: actors, enabled: devModeEnabled))
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let imageURL = target.imageURL {
                        MessagePreviewImage(url: imageURL)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onTapGesture {
                    if let targetURL {
                        openURL(targetURL)
                    }
                }
            }

            Spacer(minLength: 32)
        }
        .padding(.vertical, 6)
    }

    private var actorName: String? {
        guard let actor = actors.first else { return nil }
        return DebugRedaction.actorName(actor, enabled: devModeEnabled)
    }

    private var displayText: String? {
        guard let text = target.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard target.imageURL != nil else { return text }

        let normalized = text.lowercased()
        if normalized.hasPrefix("sent a reel") || normalized.hasPrefix("sent a post") || normalized.hasPrefix("sent media") {
            return nil
        }
        return text
    }
}

private struct MessagePreviewImage: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 180, height: 180)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            case .empty:
                ProgressView()
                    .frame(width: 180, height: 120)
            case .failure:
                EmptyView()
            @unknown default:
                EmptyView()
            }
        }
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

private struct ReplyThreadView: View {
    let parentTarget: NotificationTarget
    let replyTarget: NotificationTarget
    let network: SocialNetwork
    let actors: [NotificationActor]
    let parentDetails: NotificationTargetDetails?
    let replyDetails: NotificationTargetDetails?
    let isLoadingParentDetails: Bool
    let isLoadingReplyDetails: Bool
    let parentURL: URL?
    let replyURL: URL?
    let openURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TargetPostView(
                target: parentTarget,
                fallbackNetwork: network,
                fallbackActors: actors,
                details: parentDetails,
                isLoadingDetails: isLoadingParentDetails,
                targetURL: parentURL,
                hidesMediaFallbackText: false,
                showsFallbackWhileLoading: true,
                showsInlineLoadingRow: false,
                openURL: openURL,
            )

            ThreadConnector()

            TargetPostView(
                target: replyTarget,
                fallbackNetwork: network,
                fallbackActors: actors,
                details: replyDetails,
                isLoadingDetails: isLoadingReplyDetails,
                targetURL: replyURL,
                hidesMediaFallbackText: false,
                showsFallbackWhileLoading: true,
                showsInlineLoadingRow: false,
                openURL: openURL,
            )
        }
    }
}

private struct ThreadConnector: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(width: 2, height: 18)
                .padding(.leading, 17)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct TargetPostView: View {
    let target: NotificationTarget
    let fallbackNetwork: SocialNetwork
    let fallbackActors: [NotificationActor]
    let details: NotificationTargetDetails?
    let isLoadingDetails: Bool
    let targetURL: URL?
    let hidesMediaFallbackText: Bool
    let showsFallbackWhileLoading: Bool
    let showsInlineLoadingRow: Bool
    let openURL: (URL) -> Void

    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoadingDetails, details == nil, !showsFallbackWhileLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                postContent
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if let targetURL, !(isLoadingDetails && details == nil) {
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
                    if hidesAuthorWhileLoading {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(width: 120, height: 14)
                    } else {
                        Text(authorName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }

                    if !hidesAuthorWhileLoading {
                        HStack(spacing: 6) {
                            if let username = displayAuthor?.username {
                                Text("@\(DebugRedaction.username(username, enabled: devModeEnabled))")
                            } else {
                                Text(fallbackNetwork.displayName)
                            }

                            if let postedAt = details?.postedAt ?? target.postedAt {
                                Text("•")
                                Text(postedAt.compactRelativeTime)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
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
            } else if isLoadingDetails {
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                        .frame(width: 180, height: 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !displayImageURLs.isEmpty {
                ImageCarousel(imageURLs: displayImageURLs)
            }

            if isLoadingDetails, showsInlineLoadingRow {
                loadingRow
            }

            if let likeCount = details?.likeCount ?? target.likeCount {
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
        details?.author ?? target.author
    }

    private var hidesAuthorWhileLoading: Bool {
        isLoadingDetails && details == nil && displayText == nil
    }

    private var displayText: String? {
        let text = details?.text ?? target.text
        guard hidesMediaFallbackText, !displayImageURLs.isEmpty else { return text }
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized.hasPrefix("sent a reel") || normalized.hasPrefix("sent a post") || normalized.hasPrefix("sent media") {
            return nil
        }
        return text
    }

    private var redactionActors: [NotificationActor] {
        if let author = displayAuthor {
            return fallbackActors + [author]
        }
        return fallbackActors
    }

    private var displayImageURLs: [URL] {
        if let details, !details.imageURLs.isEmpty {
            return details.imageURLs
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
        NetworkBadgeIcon(network: network)
            .accessibilityHidden(true)
    }
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
