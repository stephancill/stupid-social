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

/// A chat's details: its picture, title and subtitle, then muting and archiving where its network has them.
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
            )
            ChatSettingsSection(viewModel: viewModel)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Mute and Archive for a chat's details, each shown only where the chat's network can change it.
struct ChatSettingsSection: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        if viewModel.canMute || viewModel.canArchive {
            Section {
                if viewModel.canMute, let isMuted = viewModel.isMuted {
                    Toggle("Mute", isOn: Binding(get: { isMuted }, set: { muted in
                        save { try await viewModel.setMuted(muted) } report: { AppMetrics.chatMuteChanged(network: viewModel.network, muted: muted, error: $0) }
                    }))
                }
                if viewModel.canArchive, let isArchived = viewModel.isArchived {
                    Button(isArchived ? "Unarchive" : "Archive") {
                        save { try await viewModel.setArchived(!isArchived) } report: { AppMetrics.chatArchiveChanged(network: viewModel.network, archived: !isArchived, error: $0) }
                    }
                }
            } footer: {
                if let errorMessage {
                    Text(errorMessage)
                }
            }
            .disabled(isSaving)
        }
    }

    private func save(_ change: @escaping () async throws -> Void, report: @escaping ((any Error)?) -> Void) {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await change()
                report(nil)
            } catch {
                report(error)
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
