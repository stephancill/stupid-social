import NoFeedSocialCore
import SwiftUI

/// Confirms an opened Apron link. The server comes first, then what the link refers to, and nothing connects,
/// signs in or joins until the user taps the button (SPEC.md §6).
struct ApronLinkView: View {
    @StateObject private var viewModel: ApronLinkViewModel
    let openRoom: (ApronLink) -> Void
    @Environment(\.dismiss) private var dismiss

    init(viewModel: @autoclosure @escaping () -> ApronLinkViewModel, openRoom: @escaping (ApronLink) -> Void) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.openRoom = openRoom
    }

    private var link: ApronLink {
        viewModel.link
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Server", value: link.host)
                    Text(link.serverURL.absoluteString)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } footer: {
                    if let serverFooter {
                        Text(serverFooter)
                    }
                }

                if link.isLocalServer, viewModel.action == .addServer || viewModel.action == .signIn {
                    Section {
                        Label("This server is on your device or local network. Only continue if you started it or trust it.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                if link.room != nil || link.user != nil {
                    Section("Link") {
                        if let room = link.room {
                            LabeledContent("Room") { code(room) }
                        }
                        if let message = link.message {
                            LabeledContent("Message") { code(message) }
                        }
                        if let user = link.user {
                            LabeledContent("User") { code(user) }
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                if let buttonTitle {
                    Section {
                        Button {
                            Task {
                                guard await viewModel.confirm() else { return }
                                dismiss()
                                if link.room != nil {
                                    openRoom(link)
                                }
                            }
                        } label: {
                            HStack {
                                Text(buttonTitle)
                                if viewModel.isWorking {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(viewModel.isWorking)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(buttonTitle == nil ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    /// IDs come from whoever wrote the link, so characters that hide or reorder text are escaped.
    private func code(_ value: String) -> some View {
        Text(ApronLink.displayValue(value))
            .lineLimit(1)
            .textSelection(.enabled)
    }

    private var title: String {
        switch viewModel.action {
        case .signIn: "Sign In"
        case .addServer: "Add Server"
        case .joinRoom: "Join Room"
        case .openRoom: "Open Room"
        case .none: "Apron Link"
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

    private var serverFooter: String? {
        switch viewModel.action {
        case .signIn:
            let replaces = viewModel.savedServer == nil ? "" : " It replaces the token saved for this server."
            return "This link signs you in to \(link.host). Only continue if you asked to sign in: a link someone else made can sign you in to their account.\(replaces)"
        case .addServer:
            return "You haven't used this server. Servers choose their own names and messages, so only add servers you trust. You join as a guest."
        case .joinRoom:
            return "You haven't joined this room. Joining adds it to Chats, and its members can see you."
        case .openRoom:
            return nil
        case .none:
            return viewModel.savedServer.map { "You've added this server, signed in as \($0.user?.displayName ?? "a guest")." }
        }
    }
}
