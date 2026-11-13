import StupidSocialCore
import SwiftUI

/// A chat on a network without a details screen of its own: the shared chat, whose title opens `ChatInfoView`.
struct InfoChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @State private var showsInfo = false

    init(viewModel: @autoclosure @escaping () -> ChatViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        ChatView(viewModel: viewModel, onTitleTap: { showsInfo = true })
            .navigationDestination(isPresented: $showsInfo) {
                ChatInfoView(viewModel: viewModel)
            }
    }
}

/// A chat's details: its picture, title and subtitle, with Mute and Archive buttons where its network has them.
struct ChatInfoView: View {
    @ObservedObject var viewModel: ChatViewModel
    @AppStorage("redactionEnabled") private var redactionEnabled = false

    var body: some View {
        List {
            ChatDetailsHeader(
                title: viewModel.titleNamesPeople ? DebugRedaction.name(viewModel.title, enabled: redactionEnabled) : viewModel.title,
                subtitle: viewModel.subtitle.isEmpty ? nil : viewModel.subtitle,
                description: nil,
                avatarURL: viewModel.titleAvatar?.url,
                colorKey: viewModel.titleAvatar?.colorKey ?? viewModel.title,
            ) {
                if viewModel.hasChatSettings {
                    DetailActionRow { ChatSettingsButtons(viewModel: viewModel) }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A round button with its name below, in the row of actions under a profile or chat header (Message, Mute,
/// Archive). While it works, a spinner takes the icon's place without resizing the button.
struct DetailActionButton: View {
    let title: String
    let systemImage: String
    var isWorking = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: action) {
                // A fixed frame keeps every button in the row the same size, whatever the symbol's shape.
                Image(systemName: systemImage)
                    .frame(width: 24, height: 24)
                    .opacity(isWorking ? 0 : 1)
                    .overlay {
                        if isWorking {
                            ProgressView()
                        }
                    }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel(title)
            Text(title)
                .font(.caption)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
        .disabled(isWorking)
    }
}

/// The row of `DetailActionButton`s under a profile or chat header.
struct DetailActionRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: DetailActionRow.spacing) {
            content()
        }
        .padding(.top, 10)
    }

    static var spacing: CGFloat {
        24
    }
}

extension ChatViewModel {
    /// Whether the chat's details offer Mute or Archive: its network can change them and its Chats row says which
    /// they are.
    var hasChatSettings: Bool {
        (canMute && isMuted != nil) || (canArchive && isArchived != nil)
    }
}

/// Mute and Archive buttons for a chat's details, each shown only where the chat's network can change it. Goes in
/// a `DetailActionRow`, after any other buttons.
struct ChatSettingsButtons: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var saving: Setting?
    @State private var errorMessage: String?

    private enum Setting {
        case mute, archive
    }

    var body: some View {
        HStack(alignment: .top, spacing: DetailActionRow<EmptyView>.spacing) {
            if viewModel.canMute, let isMuted = viewModel.isMuted {
                DetailActionButton(title: isMuted ? "Unmute" : "Mute", systemImage: isMuted ? "bell.slash.fill" : "bell.fill", isWorking: saving == .mute) {
                    save(.mute) { try await viewModel.setMuted(!isMuted) } report: { AppMetrics.chatMuteChanged(network: viewModel.network, muted: !isMuted, error: $0) }
                }
            }
            if viewModel.canArchive, let isArchived = viewModel.isArchived {
                DetailActionButton(title: isArchived ? "Unarchive" : "Archive", systemImage: isArchived ? "tray.and.arrow.up.fill" : "archivebox.fill", isWorking: saving == .archive) {
                    save(.archive) { try await viewModel.setArchived(!isArchived) } report: { AppMetrics.chatArchiveChanged(network: viewModel.network, archived: !isArchived, error: $0) }
                }
            }
        }
        .disabled(saving != nil)
        .alert("Couldn’t Change Chat", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {} message: {
            Text(errorMessage ?? "")
        }
    }

    private func save(_ setting: Setting, _ change: @escaping () async throws -> Void, report: @escaping ((any Error)?) -> Void) {
        saving = setting
        errorMessage = nil
        Task {
            do {
                try await change()
                report(nil)
            } catch {
                report(error)
                errorMessage = error.localizedDescription
            }
            saving = nil
        }
    }
}
