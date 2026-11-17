import StupidSocialCore
import SwiftUI

/// Add Account → Apron: the server's address, then, once it is read, the server as an invite shows it in place of
/// the form, with its sign-in methods. Signing in makes it an account.
struct ApronAddServerView: View {
    @ObservedObject var viewModel: ApronServersViewModel
    let onDone: () -> Void

    var body: some View {
        Group {
            if let preview = viewModel.preview {
                server(preview)
            } else {
                addressForm
            }
        }
        .navigationTitle("Apron")
        .onAppear {
            // Coming back here starts again from the address.
            viewModel.message = nil
            viewModel.clearPreview()
            viewModel.reload()
        }
    }

    private var canContinue: Bool {
        !viewModel.isWorking && !viewModel.serverInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var addressForm: some View {
        Form {
            Section {
                TextField(ApronServersViewModel.exampleServer, text: $viewModel.serverInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.continue)
                    .onSubmit {
                        if canContinue {
                            Task { await viewModel.loadPreview() }
                        }
                    }
                Button {
                    Task { await viewModel.loadPreview() }
                } label: {
                    WorkingLabel(title: "Continue", isWorking: viewModel.isWorking)
                }
                .disabled(!canContinue)
            } header: {
                Text("Server")
            } footer: {
                Text("Apron is an open chat protocol for small groups. Enter a server's address to see how it lets you sign in.")
            }

            if let message = viewModel.message {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func server(_ preview: ApronServerPreview) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                ApronServerCard(preview: preview)
                if let welcome = preview.server.welcome?.trimmingCharacters(in: .whitespacesAndNewlines), !welcome.isEmpty {
                    ApronWelcomeText(text: welcome)
                }
                if let message = viewModel.message {
                    Text(message)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                ApronSignInChoices(options: preview.signIn, isWorking: viewModel.isWorking) { method, token in
                    if await signIn(method, token: token) {
                        onDone()
                    }
                }
            }
            // Two sizes: the server's name, and this one for everything else.
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func signIn(_ method: ApronSignInMethod, token: String?) async -> Bool {
        switch method {
        case .token, .guest:
            viewModel.tokenInput = token ?? ""
            return await viewModel.addServer()
        case .passkey, .createPasskey, .external:
            return await viewModel.signInOnPage(method, openPage: WebAuthenticationSession.openApronPage)
        }
    }
}

/// One Apron account: the server, what it said at sign-in, notifications, the token, and removing it.
struct ApronServerDetailView: View {
    @ObservedObject var viewModel: ApronServersViewModel
    let server: ApronServerMetadata
    @State private var showRemoveConfirmation = false
    @State private var running: ApronSignInMethod?
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

            if let description = server.description, !description.isEmpty {
                Section("About") {
                    Text(markdown(description))
                }
            }

            if let welcome = server.welcome, !welcome.isEmpty {
                Section("Welcome") {
                    Text(markdown(welcome))
                }
            }

            Section {
                Toggle("Notifications", isOn: Binding(
                    get: { viewModel.isPushEnabled(server) },
                    set: { enabled in Task { await viewModel.setPushEnabled(enabled, for: server) } },
                ))
            } footer: {
                Text("Mentions, replies and private rooms notify this device when the server supports push and you're signed in with a token. Choose what each room notifies about from its member list.")
            }

            if let options = server.signIn, case let methods = options.methods.filter({ $0.usesPage && $0 != .createPasskey }), !methods.isEmpty {
                Section(server.status == .invalidCredentials ? "Sign In Again" : "Sign In") {
                    ForEach(methods, id: \.self) { method in
                        Button {
                            running = method
                            Task {
                                defer { running = nil }
                                _ = await viewModel.signInOnPage(method, server: server, openPage: WebAuthenticationSession.openApronPage)
                            }
                        } label: {
                            WorkingLabel(title: options.title(for: method), isWorking: running == method)
                        }
                        .disabled(viewModel.isWorking)
                    }
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
        .navigationTitle(server.displayTitle)
        .onAppear { viewModel.message = nil }
        .alert("Remove \(server.displayTitle)?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Server", role: .destructive) {
                viewModel.remove(server)
                dismiss()
            }
        } message: {
            Text("This removes the server and its saved token, and removes its rooms from your notifications.")
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private var statusLabel: String {
        switch server.status {
        case .invalidCredentials: "Invalid credentials"
        case .valid: "Valid"
        default: "Unavailable"
        }
    }
}

/// A button title with a spinner after it while its action runs.
private struct WorkingLabel: View {
    let title: String
    let isWorking: Bool

    /// The spinner is an overlay at the row's trailing edge, so the row keeps its height.
    var body: some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if isWorking {
                    ProgressView()
                }
            }
    }
}
