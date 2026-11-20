import StupidSocialCore
import SwiftUI

/// A post laid out like it is on its network (X, Farcaster): author line, text, media, and an action bar to reply,
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
    /// A line above the post, such as who reposted it or that it's pinned.
    var context: (text: String, systemImage: String)?
    /// Opens the post here, in place of its page on the network.
    var open: (() -> Void)?
    /// The post's photos and videos as the media viewer plays them, such as from a profile's timeline; otherwise the
    /// viewer shows the images.
    var media: [ProfileTimelineItem.Media]?

    @Environment(\.openURL) private var openURL
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    @State private var engagement: PostEngagement?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let context {
                Label(context.text, systemImage: context.systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 20)
                    .padding(.top, 6)
            }
            card
        }
        .task(id: isLoadingDetails) {
            await loadEngagement()
        }
    }

    private var card: some View {
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
                        ImageCarousel(imageURLs: imageURLs, open: openMedia(at:))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let open {
                        open()
                    } else if let postURL {
                        openURL(postURL)
                    }
                }

                if let engaging, let postURL {
                    PostActionBar(
                        target: target,
                        author: author,
                        network: network,
                        postURL: postURL,
                        engaging: engaging,
                        engagement: $engagement,
                        reload: { await loadEngagement(force: true) },
                    )
                } else if let likeCount = details?.likeCount ?? target.likeCount {
                    countLabel(systemImage: "heart", count: likeCount)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(likeCount) likes")
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

            if author?.isVerified == true {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Verified")
            }

            Text(handleAndTime)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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

    // MARK: Content

    private var postURL: URL? {
        NotificationTargetURL.resolve(network: network, target: target)
    }

    private var author: NotificationActor? {
        details?.author ?? target.author
    }

    private var authorName: String {
        guard let author else { return network.displayName }
        return DebugRedaction.displayName(author, enabled: redactionEnabled)
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

    /// The post's photos and videos full screen, at the one tapped, with its counts and actions.
    private func openMedia(at index: Int) {
        let shown = media.flatMap { $0.count == imageURLs.count ? $0 : nil } ?? imageURLs.map { ProfileTimelineItem.Media(imageURL: $0) }
        let post = PostThread.Post(target: target, engagement: engagement ?? details?.engagement)
        let pages = MediaViewerPage.pages(itemId: target.id, post: post, media: shown, caption: text)
        MediaViewer.present(pages: pages, startKey: pages.indices.contains(index) ? pages[index].key : nil, network: network, engaging: engaging)
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
                                Text(DebugRedaction.displayName(author, enabled: redactionEnabled))
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
