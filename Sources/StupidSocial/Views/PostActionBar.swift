import StupidSocialCore
import SwiftUI

/// A post's counts and actions, as its network shows them under it: reply, repost or quote, like, bookmark (where
/// the source bookmarks) and share. Changes show at once and go back if the network refuses them. Where the
/// network turns an action away from this client, its own page opens instead, and `reload` runs on return.
struct PostActionBar: View {
    let target: NotificationTarget
    let author: NotificationActor?
    let network: SocialNetwork
    let postURL: URL
    let engaging: any PostEngaging
    @Binding var engagement: PostEngagement?
    /// Loads the post's engagement again, after the network's own page may have changed it.
    let reload: () async -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var composerMode: PostComposerMode?
    @State private var errorMessage: String?
    @State private var isUpdating = false
    /// An action went to the network's own page; its result is loaded on return.
    @State private var awaitsNetworkPage = false

    var body: some View {
        HStack {
            Button {
                composerMode = .reply
            } label: {
                countLabel(systemImage: "bubble.left", count: engagement?.replyCount)
            }
            .accessibilityLabel("Reply")

            Spacer()

            Menu {
                if engagement?.isReposted == true {
                    Button("Undo Repost", systemImage: "arrow.2.squarepath") {
                        Task { await setReposted(false) }
                    }
                } else {
                    Button("Repost", systemImage: "arrow.2.squarepath") {
                        Task { await setReposted(true) }
                    }
                }
                Button("Quote", systemImage: "square.and.pencil") {
                    composerMode = .quote
                }
            } label: {
                countLabel(systemImage: "arrow.2.squarepath", count: engagement.map { $0.repostCount + $0.quoteCount })
                    .foregroundStyle(engagement?.isReposted == true ? Color.green : Color.secondary)
            }
            .accessibilityLabel("Repost")

            Spacer()

            Button {
                Task { await toggleLike() }
            } label: {
                countLabel(systemImage: engagement?.isLiked == true ? "heart.fill" : "heart", count: engagement?.likeCount)
                    .foregroundStyle(engagement?.isLiked == true ? Color.pink : Color.secondary)
            }
            .accessibilityLabel(engagement?.isLiked == true ? "Unlike" : "Like")

            if bookmarking != nil {
                Spacer()

                Button {
                    Task { await toggleBookmark() }
                } label: {
                    countLabel(systemImage: engagement?.isBookmarked == true ? "bookmark.fill" : "bookmark", count: engagement?.bookmarkCount)
                        .foregroundStyle(engagement?.isBookmarked == true ? Color.blue : Color.secondary)
                }
                .accessibilityLabel(engagement?.isBookmarked == true ? "Remove Bookmark" : "Bookmark")
            }

            Spacer()

            ShareLink(item: postURL) {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .disabled(engagement == nil || isUpdating)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, awaitsNetworkPage else { return }
            awaitsNetworkPage = false
            Task { await reload() }
        }
        .sheet(item: $composerMode) { mode in
            PostComposerView(mode: mode, target: target, author: author) { text in
                try await send(mode: mode, text: text)
            }
        }
        .alert("Couldn't Update Post", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } },
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var bookmarking: (any PostBookmarking)? {
        engaging as? any PostBookmarking
    }

    private func countLabel(systemImage: String, count: Int?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            if let count, count > 0 {
                Text(PostCardView.compactCount(count))
                    .monospacedDigit()
            }
        }
    }

    // MARK: Actions

    private func toggleLike() async {
        guard let current = engagement else { return }
        let liked = !current.isLiked
        engagement?.isLiked = liked
        engagement?.likeCount += liked ? 1 : -1
        await update(action: liked ? "like" : "unlike", restoring: current) {
            try await engaging.setLiked(postId: target.id, liked: liked)
        }
    }

    private func setReposted(_ reposted: Bool) async {
        guard let current = engagement else { return }
        if reposted, let url = engaging.repostPageURL(postId: target.id) {
            openNetworkPage(url, action: "repost")
            return
        }
        engagement?.isReposted = reposted
        engagement?.repostCount += reposted ? 1 : -1
        await update(action: reposted ? "repost" : "unrepost", restoring: current) {
            try await engaging.setReposted(postId: target.id, reposted: reposted)
        }
    }

    private func toggleBookmark() async {
        guard let bookmarking, let current = engagement else { return }
        let bookmarked = !current.isBookmarked
        if bookmarked, let url = bookmarking.bookmarkPageURL(postId: target.id) {
            openNetworkPage(url, action: "bookmark")
            return
        }
        engagement?.isBookmarked = bookmarked
        engagement?.bookmarkCount = current.bookmarkCount.map { max(0, $0 + (bookmarked ? 1 : -1)) }
        await update(action: bookmarked ? "bookmark" : "unbookmark", restoring: current) {
            try await bookmarking.setBookmarked(postId: target.id, bookmarked: bookmarked)
        }
    }

    private func openNetworkPage(_ url: URL, action: String) {
        AppMetrics.postEngaged(network: network, action: action, error: nil)
        awaitsNetworkPage = true
        openURL(url)
    }

    /// Sends a change already shown, and shows the post as it was if the network refuses it.
    private func update(action: String, restoring current: PostEngagement, _ send: () async throws -> Void) async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await send()
            AppMetrics.postEngaged(network: network, action: action, error: nil)
        } catch {
            engagement = current
            errorMessage = error.localizedDescription
            AppMetrics.postEngaged(network: network, action: action, error: error)
        }
    }

    private func send(mode: PostComposerMode, text: String) async throws {
        do {
            switch mode {
            case .reply:
                try await engaging.reply(to: target.id, text: text)
                engagement?.replyCount += 1
            case .quote:
                try await engaging.quote(postId: target.id, text: text)
                engagement?.quoteCount += 1
            }
            AppMetrics.postEngaged(network: network, action: mode.rawValue, error: nil)
        } catch {
            AppMetrics.postEngaged(network: network, action: mode.rawValue, error: error)
            throw error
        }
    }
}
