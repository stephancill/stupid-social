import NoFeedSocialCore
import SwiftUI

/// Settings list of Apron servers plus the add-server form.
struct ApronServersView: View {
    @ObservedObject var viewModel: ApronServersViewModel

    var body: some View {
        Form {
            if !viewModel.servers.isEmpty {
                Section("Servers") {
                    ForEach(viewModel.servers) { server in
                        NavigationLink {
                            ApronServerDetailView(viewModel: viewModel, server: server)
                        } label: {
                            HStack {
                                if server.status == .invalidCredentials {
                                    Circle()
                                        .fill(.red)
                                        .frame(width: 8, height: 8)
                                        .accessibilityLabel("Invalid credentials")
                                }
                                Text(server.serverURL.host() ?? server.serverURL.absoluteString)
                                Spacer()
                                Text(server.user?.displayName ?? "Guest")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                TextField(ApronServersViewModel.exampleServer, text: $viewModel.serverInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Token (optional)", text: $viewModel.tokenInput)
                TextField("Display name (optional)", text: $viewModel.nameInput)
                    .autocorrectionDisabled()

                Button {
                    Task { await viewModel.addServer() }
                } label: {
                    HStack {
                        Text("Add Server")
                        if viewModel.isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isWorking || viewModel.serverInput.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Add Server")
            } footer: {
                Text("Apron is an open chat protocol for small groups. Leave the token empty to join as a guest where the server allows it. Some servers only let guests read; get a token from the server's own app to post.")
            }

            if let message = viewModel.message {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Apron")
        .onAppear {
            viewModel.message = nil
            viewModel.reload()
        }
    }
}

private struct ApronServerDetailView: View {
    @ObservedObject var viewModel: ApronServersViewModel
    let server: ApronServerMetadata
    @State private var showRemoveConfirmation = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                LabeledContent("Server") {
                    Text(server.serverURL.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let user = server.user {
                    LabeledContent("Signed in as", value: user.displayName)
                    LabeledContent("User ID") {
                        Text(user.userId)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Status", value: statusLabel)
                if let agent = server.agent {
                    LabeledContent("Software", value: agent)
                }
            }

            if let welcome = server.welcome, !welcome.isEmpty {
                Section("Welcome") {
                    Text((try? AttributedString(markdown: welcome, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(welcome))
                }
            }

            Section {
                SecureField(viewModel.hasToken(server) ? "Replace token" : "Token", text: $viewModel.tokenInput)
                Button("Save Token") {
                    Task { await viewModel.updateToken(for: server) }
                }
                .disabled(viewModel.isWorking || viewModel.tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Token")
            } footer: {
                Text(viewModel.hasToken(server) ? "A token is saved for this server." : "Signed in as a guest.")
            }

            if let message = viewModel.message {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Remove Server", role: .destructive) {
                    showRemoveConfirmation = true
                }
            }
        }
        .navigationTitle(server.serverURL.host() ?? "Server")
        .onAppear { viewModel.message = nil }
        .alert("Remove \(server.serverURL.host() ?? "server")?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Server", role: .destructive) {
                viewModel.remove(server)
                dismiss()
            }
        } message: {
            Text("This removes the server and its saved token, and removes its rooms from your notifications.")
        }
    }

    private var statusLabel: String {
        switch server.status {
        case .invalidCredentials: "Invalid credentials"
        case .valid: "Valid"
        default: "Unavailable"
        }
    }
}
