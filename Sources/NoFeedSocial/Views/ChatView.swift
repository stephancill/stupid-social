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

    var body: some View {
        ChatUIKitView(viewModel: viewModel, showProfile: showProfile)
            .ignoresSafeArea(.keyboard)
            // Full-bleed under the bar and home indicator; the list insets itself from the safe area.
            .ignoresSafeArea(edges: [.top, .bottom])
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            // Messages scroll under a transparent bar; the title and subtitle sit in a floating pill.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // Without an action it isn't a button: a disabled button would dim the title.
                    if let onTitleTap {
                        Button(action: onTitleTap) {
                            ChatTitlePill(title: displayTitle, subtitle: displaySubtitle)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ChatTitlePill(title: displayTitle, subtitle: displaySubtitle)
                    }
                }
            }
            .task {
                await viewModel.connect()
            }
            .onDisappear {
                guard !keepsConnection else { return }
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

private struct ChatTitlePill: View {
    let title: String
    let subtitle: String

    var body: some View {
        let content = VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 5)

        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
