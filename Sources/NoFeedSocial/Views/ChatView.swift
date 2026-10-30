import NoFeedSocialCore
import SwiftUI
import UIKit

/// The shared chat screen: the UIKit chat full-bleed under a transparent bar, with the title in a floating
/// pill. It connects while visible and again when the app becomes active.
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    /// Tapping the title pill, such as to list members; `nil` leaves the pill inert.
    var onTitleTap: (() -> Void)?
    var showProfile: (ChatUser) -> Void = { _ in }
    /// While a screen pushed on top reads the chat's live state, leaving doesn't disconnect.
    var keepsConnection = false

    @AppStorage("redactionEnabled") private var redactionEnabled = false

    /// Like the feed, "Redact names" hides people's names: the title of a chat named for people, and an
    /// `@username` subtitle.
    private var displayTitle: String {
        viewModel.titleNamesPeople ? DebugRedaction.name(viewModel.title, enabled: redactionEnabled) : viewModel.title
    }

    private var displaySubtitle: String {
        redactionEnabled && viewModel.subtitle.hasPrefix("@") ? "Redacted" : viewModel.subtitle
    }

    private var isSearching: Bool {
        viewModel.searchQuery != nil
    }

    /// Tapping runs `onTitleTap`; long-pressing searches the chat. The pill draws its own capsule, so the pointer's
    /// hover outline (on a Mac) is turned off.
    private var titlePill: some View {
        ChatTitlePill(title: displayTitle, subtitle: displaySubtitle, network: viewModel.network, avatar: viewModel.titleAvatar)
            .contentShape(.capsule)
            .onTapGesture { onTitleTap?() }
            .onLongPressGesture(minimumDuration: 0.4) { viewModel.beginSearch() }
            .sensoryFeedback(.impact, trigger: isSearching) { _, searching in searching }
            .accessibilityAddTraits(onTitleTap == nil ? [] : .isButton)
            .accessibilityAction(named: "Search Messages") { viewModel.beginSearch() }
            .hoverEffectDisabled()
    }

    var body: some View {
        ChatUIKitView(viewModel: viewModel, showProfile: showProfile)
            .ignoresSafeArea(.keyboard)
            // Full-bleed under the bar and home indicator; the list insets itself from the safe area.
            .ignoresSafeArea(edges: [.top, .bottom])
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            // Messages scroll under the bar, which has no background on iOS 26; the title and subtitle sit in a
            // floating pill. `.toolbarBackground(.hidden)` here hid the Chats search field's background while
            // swiping back, until the pop finished.
            .toolbar {
                ToolbarItem(placement: .principal) {
                    titlePill
                }
            }
            // On a background, so starting and ending a search doesn't rebuild the chat's view and lose its place.
            .background {
                if isSearching {
                    ChatSearchField(viewModel: viewModel)
                }
            }
            .task {
                AppMetrics.chatOpened(network: viewModel.network)
                await viewModel.connect()
            }
            .onDisappear {
                guard !keepsConnection else { return }
                viewModel.endSearch()
                viewModel.disconnect()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { await viewModel.connect() }
            }
    }
}

/// The shared chat for a network without screens of its own, such as Spotify and Instagram.
struct NetworkChatView: View {
    @StateObject private var viewModel: ChatViewModel

    init(viewModel: @autoclosure @escaping () -> ChatViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        ChatView(viewModel: viewModel)
    }
}

/// The app's search field under the chat's title while searching, focused as it appears. Its Cancel ends the
/// search; Return looks further back when nothing loaded matches.
private struct ChatSearchField: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var text = ""
    @State private var isPresented = false

    var body: some View {
        Color.clear
            .searchBar(text: $text, isPresented: $isPresented, prompt: "Search Messages", placement: .navigationBarDrawer(displayMode: .always))
            .onSubmit(of: .search) { Task { await viewModel.submitSearch() } }
            .onChange(of: text) { _, query in viewModel.updateSearch(query) }
            .onChange(of: isPresented) { _, presented in
                if !presented { viewModel.endSearch() }
            }
            .task {
                // Presenting in the same pass the field appears doesn't take.
                try? await Task.sleep(for: .milliseconds(150))
                isPresented = true
            }
    }
}

private struct ChatTitlePill: View {
    let title: String
    let subtitle: String
    let network: SocialNetwork
    /// Leads with the chat's picture, as its Chats row does.
    var avatar: ChatTitleAvatar?

    var body: some View {
        let content = HStack(spacing: 8) {
            if let avatar {
                ChatAvatarImage(url: avatar.url, title: title, size: 32, colorKey: avatar.colorKey)
                    .overlay(alignment: .bottomTrailing) {
                        // An opaque backing, since some badges (such as Spotify's round logo) have transparent corners.
                        NetworkBadgeIcon(network: network, size: 12)
                            .clipShape(Circle())
                            .padding(1)
                            .background(Color(uiColor: .systemBackground), in: Circle())
                            .offset(x: 2, y: 2)
                    }
            }
            VStack(spacing: 0) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    HStack(spacing: 4) {
                        // Without an avatar to carry it, the network icon leads the subtitle.
                        if avatar == nil {
                            NetworkBadgeIcon(network: network, size: 12)
                        }
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(subtitle == ChatPresence.online.text ? AnyShapeStyle(.blue) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.leading, avatar == nil ? 18 : 5)
        .padding(.trailing, 18)
        .padding(.vertical, 5)

        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
