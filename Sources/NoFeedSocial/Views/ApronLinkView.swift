import NoFeedSocialCore
import SwiftUI

/// Confirms an opened Apron link, laid out like a group invite: what the link opens, the server's address, and one
/// button. Nothing signs in or joins until the user taps it, and a server the user hasn't used isn't contacted
/// before then (SPEC.md §6); a saved server previews the room.
struct ApronLinkView: View {
    @StateObject private var viewModel: ApronLinkViewModel
    let openRoom: (ApronLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 400
    @State private var buttonHeight: CGFloat = 0

    init(viewModel: @autoclosure @escaping () -> ApronLinkViewModel, openRoom: @escaping (ApronLink) -> Void) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.openRoom = openRoom
    }

    private var link: ApronLink {
        viewModel.link
    }

    private var roomPreview: ApronLinkViewModel.RoomPreview? {
        if case let .loaded(preview) = viewModel.preview { return preview }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                if let description = roomPreview?.description {
                    Text(markdown(description))
                        .multilineTextAlignment(.center)
                }
                if let members = roomPreview?.members, !members.isEmpty {
                    memberFaces(members)
                }
                details
            }
            // Two sizes: the title, and this one for everything else.
            .font(.subheadline)
            .padding(.horizontal, 24)
            .padding(.top, 64)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if let buttonTitle {
                confirmButton(buttonTitle)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { buttonHeight = $0 }
            }
        }
        .overlay(alignment: .topLeading) {
            closeButton
        }
        // Fits the content, as a group invite does; content taller than the screen scrolls.
        .presentationDetents([.height(contentHeight + (buttonTitle == nil ? 0 : buttonHeight))])
        .presentationDragIndicator(.visible)
        .task { await viewModel.loadPreview() }
    }

    @ViewBuilder
    private var closeButton: some View {
        let button = Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel("Close")
        .padding(16)
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered).tint(.secondary)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            avatar
            VStack(spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                // The address always shows, so a server's chosen name can't pass for another server's (PROTOCOL.md §3.1).
                Text(link.serverURL.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A room shows its initial with the server's icon as a badge (Apron's without one), as Chats rows do; a server
    /// shows its icon.
    private var avatar: some View {
        let size: CGFloat = 88
        return Group {
            if link.room != nil {
                initialCircle(title, size: size)
                    .overlay(alignment: .bottomTrailing) {
                        Group {
                            if viewModel.savedServer?.avatarURL != nil {
                                serverIcon(size: 30)
                            } else {
                                NetworkBadgeIcon(network: .apron, size: 30)
                            }
                        }
                        .padding(2)
                        .background(Color(uiColor: .systemBackground), in: Circle())
                    }
            } else {
                serverIcon(size: size)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func serverIcon(size: CGFloat) -> some View {
        let name = viewModel.savedServer?.displayTitle ?? link.host
        Group {
            if let url = viewModel.savedServer?.avatarURL {
                CachedAsyncImage(url: url) { initialCircle(name, size: size) } failure: { initialCircle(name, size: size) }
            } else {
                initialCircle(name, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func initialCircle(_ name: String, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.18))
            Text(name.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
    }

    /// Up to five overlapping faces, with how many more there are.
    private func memberFaces(_ members: [ApronUser]) -> some View {
        let shown = Array(members.prefix(5))
        let more = (roomPreview?.memberCount ?? members.count) - shown.count
        return HStack(spacing: 8) {
            HStack(spacing: -10) {
                ForEach(shown, id: \.userId) { user in
                    ApronUserAvatar(user: user, avatarURL: user.avatarURL, presence: nil, size: 32)
                        .overlay { Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2) }
                }
            }
            if more > 0 {
                Text("+\(more)")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Details

    private var details: some View {
        VStack(spacing: 12) {
            if link.isLocalServer, viewModel.action == .addServer || viewModel.action == .signIn {
                Label("This server is on your device or network.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if let note {
                Text(note)
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .multilineTextAlignment(.center)
    }

    private func confirmButton(_ title: String) -> some View {
        Button {
            Task {
                guard await viewModel.confirm() else { return }
                dismiss()
                if link.room != nil {
                    openRoom(link)
                }
            }
        } label: {
            ZStack {
                Text(title)
                    .opacity(viewModel.isWorking ? 0 : 1)
                if viewModel.isWorking {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(viewModel.isWorking)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    // MARK: Text

    /// IDs come from whoever wrote the link, so characters that hide or reorder text are escaped.
    private var title: String {
        if let roomPreview { return roomPreview.title }
        if let room = link.room { return ApronLink.displayValue(room) }
        if let user = link.user { return ApronLink.displayValue(user) }
        return viewModel.savedServer?.displayTitle ?? link.host
    }

    /// A saved server's name and the room's size; a new server has only its address, which shows below.
    private var subtitle: String? {
        guard let server = viewModel.savedServer else { return nil }
        guard link.room != nil else {
            return link.user == nil ? "Signed in as \(server.user?.displayName ?? "a guest")" : server.displayTitle
        }
        guard let count = roomPreview?.memberCount else { return server.displayTitle }
        return "\(server.displayTitle) · \(count == 1 ? "1 member" : "\(count) members")"
    }

    /// One line at most: why the room can't be previewed, or what to trust before continuing.
    private var note: String? {
        switch viewModel.preview {
        case .unavailable: return "This room is private or doesn't exist."
        case .failed: return "Couldn't load this room."
        case .none, .loading, .loaded: break
        }
        switch viewModel.action {
        case .signIn: return "Only sign in if you asked to. A link from someone else can sign you in to their account."
        case .addServer: return "You haven't used this server. Only add servers you trust."
        case .joinRoom, .openRoom, .none: return nil
        }
    }

    private var buttonTitle: String? {
        switch viewModel.action {
        case .signIn: "Sign In"
        case .addServer: link.room == nil ? "Add Server" : "Add Server and Open Room"
        case .joinRoom: "Join Room"
        case .openRoom: "Open Room"
        case .none: nil
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
