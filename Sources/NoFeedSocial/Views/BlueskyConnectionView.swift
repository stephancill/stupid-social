import AuthenticationServices
import NoFeedSocialCore
import SwiftUI
import UIKit

/// Adds a Bluesky account (`accountId` nil), or shows one account's settings.
struct BlueskyConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let accountId: String?
    let onDone: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isLoggingIn = false
    @State private var authSession: WebAuthenticationSession?

    private var account: Account? {
        accountId.flatMap(viewModel.account(id:))
    }

    var body: some View {
        Form {
            if let account {
                if viewModel.status(for: account.id) == .invalidCredentials {
                    LoginButtonSection(title: "Reconnect Bluesky") {
                        viewModel.blueskyLoginHint = account.handle ?? ""
                        Task { await startLogin() }
                    }
                    .disabled(isLoggingIn)
                }
                Section {
                    LabeledContent("Account", value: viewModel.connectionLabel(for: account))
                }
                MessageSection(message: viewModel.message)
                RemoveAccountSection(viewModel: viewModel, account: account, onRemoved: onDone)
            } else {
                Section {
                    TextField("Handle or email", text: $viewModel.blueskyLoginHint)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                        .autocorrectionDisabled()
                        .focused($isFocused)
                    Button {
                        isFocused = false
                        Task { await startLogin() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoggingIn {
                                ProgressView()
                            } else {
                                Label("Log in to Bluesky", systemImage: "safari")
                            }
                            Spacer()
                        }
                    }
                    .foregroundStyle(isLoginDisabled ? Color.secondary : Color.accentColor)
                    .disabled(isLoginDisabled)
                } header: {
                    Text("Login")
                }
                MessageSection(message: viewModel.message)
            }
        }
        .onAppear { viewModel.message = nil }
        .navigationTitle("Bluesky")
    }

    private var isLoginDisabled: Bool {
        isLoggingIn || viewModel.blueskyLoginHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startLogin() async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            let oauthSession = try await viewModel.beginBlueskyOAuth(reconnecting: accountId)
            let webSession = WebAuthenticationSession(url: oauthSession.authorizationURL, callbackURLScheme: "net.stupidtech") { callbackURL in
                guard let callbackURL else {
                    viewModel.message = "Bluesky login was cancelled."
                    return
                }
                Task {
                    let added = await viewModel.finishBlueskyOAuth(callbackURL: callbackURL, session: oauthSession)
                    if added != nil, accountId == nil {
                        onDone()
                    }
                }
            }
            authSession = webSession
            webSession.start()
        } catch {
            viewModel.message = "Could not start Bluesky login: \(error.localizedDescription)"
        }
    }
}

private final class WebAuthenticationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let session: ASWebAuthenticationSession

    init(url: URL, callbackURLScheme: String, completion: @escaping (URL?) -> Void) {
        session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme) { callbackURL, _ in
            completion(callbackURL)
        }
        super.init()
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
    }

    func start() {
        session.start()
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
