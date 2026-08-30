import NoFeedSocialCore
import SwiftUI
import WebKit

struct GitHubLoginWebView: View {
    @Environment(\.dismiss) private var dismiss
    let onLoginSuccess: (GitHubCredentials) -> Void

    var body: some View {
        NavigationStack {
            GitHubLoginWKWebView { credentials in
                onLoginSuccess(credentials)
                dismiss()
            }
            .ignoresSafeArea()
            .navigationTitle("Log in to GitHub")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

private struct GitHubLoginWKWebView: UIViewRepresentable {
    let onCredentialsFound: (GitHubCredentials) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCredentialsFound: onCredentialsFound)
    }

    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_: WKWebView, context _: Context) {}
}

@MainActor
private func makeWebView(coordinator: Coordinator) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = coordinator
    coordinator.webView = webView
    configuration.websiteDataStore.httpCookieStore.add(coordinator)
    #if DEBUG
        webView.isInspectable = true
    #endif
    webView.load(URLRequest(url: URL(string: "https://github.com/login")!))
    return webView
}

@MainActor
private final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    let onCredentialsFound: (GitHubCredentials) -> Void
    weak var webView: WKWebView?
    private var captured = false

    init(onCredentialsFound: @escaping (GitHubCredentials) -> Void) {
        self.onCredentialsFound = onCredentialsFound
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        checkCookies(in: webView)
    }

    func cookiesDidChange(in _: WKHTTPCookieStore) {
        guard let webView else { return }
        checkCookies(in: webView)
    }

    private func checkCookies(in webView: WKWebView) {
        guard !captured else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.captured else { return }
            let values = Dictionary(
                cookies
                    .filter { $0.domain == "github.com" || $0.domain.hasSuffix(".github.com") }
                    .map { ($0.name, $0.value) },
                uniquingKeysWith: { _, latest in latest },
            )
            guard let session = values["user_session"], let sameSite = values["__Host-user_session_same_site"] else { return }
            captured = true
            let credentials = GitHubCredentials(userSession: session, sameSiteUserSession: sameSite, username: values["dotcom_user"])
            DispatchQueue.main.async {
                self.onCredentialsFound(credentials)
            }
        }
    }
}
