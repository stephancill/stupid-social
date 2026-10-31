import NoFeedSocialCore
import SwiftUI

/// A post laid out like it is on its network (X): author line, text, media, and an action bar to reply,
/// repost, quote, like and share when the account's source supports engaging.
struct PostCardView: View {
    let target: NotificationTarget
    let network: SocialNetwork
    let fallbackActors: [NotificationActor]
    let details: NotificationTargetDetails?
    let isLoadingDetails: Bool
    let engaging: (any PostEngaging)?
    /// Draws the thread line from the avatar down to the next post, which follows directly below.
    var continuesThread = false
    /// Draws the thread line into the avatar from above, continuing the post directly above.
    var followsThread = false

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    @State private var engagement: PostEngagement?
    @State private var composerMode: PostComposerMode?
    @State private var errorMessage: String?
    @State private var isUpdating = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let author {
                ActorAvatar(actor: author, size: 40)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    header

                    if let text, !text.isEmpty {
                        Text(DebugRedaction.text(text, actors: redactionActors, enabled: redactionEnabled))
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if isLoadingDetails {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if !imageURLs.isEmpty {
                        ImageCarousel(imageURLs: imageURLs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let postURL { openURL(postURL) }
                }

                if engaging != nil, postURL != nil {
                    actionBar
                } else if let likeCount = details?.likeCount ?? target.likeCount {
                    Label(Self.compactCount(likeCount), systemImage: "heart")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, continuesThread ? 16 : 0)
        }
        .padding(.top, 6)
        .padding(.bottom, continuesThread ? 0 : 6)
        .overlay(alignment: .topLeading) {
            // The line meets each avatar: from the card's top down to it, and from under it to the card's bottom.
            VStack(spacing: 0) {
                threadLine
                    .frame(height: 6)
                    .opacity(followsThread ? 1 : 0)
                Spacer()
                    .frame(height: 40)
                if continuesThread {
                    threadLine
                }
            }
            .padding(.leading, 19)
        }
        .task(id: isLoadingDetails) {
            await loadEngagement()
        }
        .onChange(of: scenePhase) { _, phase in
            // Reposting happens on X's own page; pick up the result on return.
            guard phase == .active else { return }
            Task { await loadEngagement(force: true) }
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

    private var threadLine: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.28))
            .frame(width: 2)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(authorName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            Text(handleAndTime)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var actionBar: some View {
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

            Spacer()

            if let postURL {
                ShareLink(item: postURL) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .disabled(engagement == nil || isUpdating)
    }

    private func countLabel(systemImage: String, count: Int?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            if let count, count > 0 {
                Text(Self.compactCount(count))
                    .monospacedDigit()
            }
        }
    }

    // MARK: Actions

    private func loadEngagement(force: Bool = false) async {
        if !force, let detailsEngagement = details?.engagement {
            engagement = detailsEngagement
            return
        }
        guard let engaging, postURL != nil, force || (engagement == nil && !isLoadingDetails) else { return }
        if let loaded = try? await engaging.fetchEngagement(postId: target.id) {
            engagement = loaded
        }
    }

    private func toggleLike() async {
        guard let engaging, let current = engagement else { return }
        let liked = !current.isLiked
        engagement?.isLiked = liked
        engagement?.likeCount += liked ? 1 : -1
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await engaging.setLiked(postId: target.id, liked: liked)
            AppMetrics.postEngaged(network: network, action: liked ? "like" : "unlike", error: nil)
        } catch {
            engagement = current
            errorMessage = error.localizedDescription
            AppMetrics.postEngaged(network: network, action: liked ? "like" : "unlike", error: error)
        }
    }

    private func setReposted(_ reposted: Bool) async {
        guard let engaging, let current = engagement else { return }
        if reposted, let url = engaging.repostPageURL(postId: target.id) {
            AppMetrics.postEngaged(network: network, action: "repost", error: nil)
            openURL(url)
            return
        }
        engagement?.isReposted = reposted
        engagement?.repostCount += reposted ? 1 : -1
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await engaging.setReposted(postId: target.id, reposted: reposted)
            AppMetrics.postEngaged(network: network, action: reposted ? "repost" : "unrepost", error: nil)
        } catch {
            engagement = current
            errorMessage = error.localizedDescription
            AppMetrics.postEngaged(network: network, action: reposted ? "repost" : "unrepost", error: error)
        }
    }

    private func send(mode: PostComposerMode, text: String) async throws {
        guard let engaging else { return }
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

    // MARK: Content

    private var postURL: URL? {
        NotificationTargetURL.resolve(network: network, target: target)
    }

    private var author: NotificationActor? {
        details?.author ?? target.author
    }

    private var authorName: String {
        guard let author else { return network.displayName }
        return DebugRedaction.actorName(author, enabled: redactionEnabled)
    }

    private var handleAndTime: String {
        var parts: [String] = []
        if let username = author?.username {
            parts.append("@\(DebugRedaction.username(username, enabled: redactionEnabled))")
        }
        if let postedAt = details?.postedAt ?? target.postedAt {
            parts.append(postedAt.compactRelativeTime)
        }
        return parts.joined(separator: " · ")
    }

    private var text: String? {
        details?.text ?? target.text
    }

    private var redactionActors: [NotificationActor] {
        fallbackActors + [author].compactMap(\.self)
    }

    private var imageURLs: [URL] {
        if let details, !details.imageURLs.isEmpty { return details.imageURLs }
        if !target.imageURLs.isEmpty { return target.imageURLs }
        return target.imageURL.map { [$0] } ?? []
    }

    /// 1234 → "1.2K", as networks show counts.
    static func compactCount(_ count: Int) -> String {
        let units: [(threshold: Double, suffix: String)] = [
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1000, "K"),
        ]
        guard let unit = units.first(where: { Double(abs(count)) >= $0.threshold }) else {
            return "\(count)"
        }
        let scaled = Double(count) / unit.threshold
        let digitsBeforeDecimal = max(1, Int(floor(log10(abs(scaled)))) + 1)
        let fractionDigits = max(0, 2 - digitsBeforeDecimal)
        return String(format: "%.*f%@", fractionDigits, scaled, unit.suffix)
    }
}

enum PostComposerMode: String, Identifiable {
    case reply
    case quote

    var id: String {
        rawValue
    }
}

/// Writes a reply to, or a quote of, a post.
struct PostComposerView: View {
    let mode: PostComposerMode
    let target: NotificationTarget
    let author: NotificationActor?
    let post: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    @State private var text = ""
    @State private var isPosting = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if mode == .reply, let username = author?.username {
                    Section {
                        Text("Replying to @\(DebugRedaction.username(username, enabled: redactionEnabled))")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField(mode == .reply ? "Post your reply" : "Add a comment", text: $text, axis: .vertical)
                        .lineLimit(4 ... 12)
                        .focused($isFocused)
                }

                if mode == .quote {
                    Section("Quoting") {
                        VStack(alignment: .leading, spacing: 4) {
                            if let author {
                                Text(DebugRedaction.actorName(author, enabled: redactionEnabled))
                                    .font(.subheadline.weight(.semibold))
                            }
                            if let quoted = target.text {
                                Text(DebugRedaction.text(quoted, actors: [author].compactMap(\.self), enabled: redactionEnabled))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                        }
                    }
                }
            }
            .navigationTitle(mode == .reply ? "Reply" : "Quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isPosting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isPosting {
                        ProgressView()
                    } else {
                        Button("Post") {
                            Task { await submit() }
                        }
                        .disabled(trimmedText.isEmpty)
                    }
                }
            }
            .alert("Couldn't Post", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } },
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(isPosting || !trimmedText.isEmpty)
        .onAppear { isFocused = true }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() async {
        isPosting = true
        defer { isPosting = false }
        do {
            try await post(trimmedText)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
