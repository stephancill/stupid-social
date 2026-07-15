import AuthenticationServices
import NoFeedSocialCore
import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

struct BlueskyConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var isFocused: Bool
    @State private var isLoggingIn = false
    @State private var authSession: WebAuthenticationSession?

    var body: some View {
        Form {
            if viewModel.blueskyHandle == nil {
                Section {
                    TextField("Handle or email", text: $viewModel.blueskyLoginHint)
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
                    .disabled(isLoggingIn || viewModel.blueskyLoginHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Login")
                } footer: {
                    Text("Bluesky OAuth requires the app's public client metadata to be hosted before login can complete.")
                }
            }

            Section {
                HStack {
                    Text("Connection")
                    Spacer()
                    Text(viewModel.blueskyConnectionLabel)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.blueskyHandle != nil || viewModel.blueskyStatus != .notConfigured {
                Section {
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnectBluesky()
                    }
                }
            }

            if let message = viewModel.message {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { viewModel.message = nil }
        .navigationTitle("Bluesky")
    }

    private func startLogin() async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            let oauthSession = try await viewModel.beginBlueskyOAuth()
            let webSession = WebAuthenticationSession(url: oauthSession.authorizationURL, callbackURLScheme: "net.stupidtech") { callbackURL in
                guard let callbackURL else {
                    viewModel.message = "Bluesky login was cancelled."
                    return
                }
                Task { await viewModel.finishBlueskyOAuth(callbackURL: callbackURL, session: oauthSession) }
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
        #if os(iOS)
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        #else
            NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}
