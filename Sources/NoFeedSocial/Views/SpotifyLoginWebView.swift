import NoFeedSocialCore
import SwiftUI
import WebKit

struct SpotifyLoginWebView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var failureMessage: String?
    @State private var retry = 0
    var onLoginSuccess: (SpotifyCredentials) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                SpotifyLoginWKWebView(
                    url: URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F%3Fnd%3D1")!,
                    retry: retry,
                    onCredentialsFound: { credentials in
                        onLoginSuccess(credentials)
                        dismiss()
                    },
                    onFailure: { failureMessage = $0 },
                )
                .ignoresSafeArea()
                .opacity(failureMessage == nil ? 1 : 0)
                .accessibilityHidden(failureMessage != nil)

                if let failureMessage {
                    ContentUnavailableView {
                        Label("Spotify login interrupted", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    } description: {
                        Text(failureMessage)
                    } actions: {
                        Button("Retry") {
                            self.failureMessage = nil
                            retry += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Log in to Spotify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct SpotifyLoginWKWebView: UIViewRepresentable {
    let url: URL
    let retry: Int
    let onCredentialsFound: (SpotifyCredentials) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCredentialsFound: onCredentialsFound, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.attach(to: webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.retry != retry else { return }
        context.coordinator.retry = retry
        webView.load(URLRequest(url: url))
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach(from: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        var retry = 0
        private let onCredentialsFound: (SpotifyCredentials) -> Void
        private let onFailure: (String) -> Void
        private var completed = false
        private weak var webView: WKWebView?

        init(onCredentialsFound: @escaping (SpotifyCredentials) -> Void, onFailure: @escaping (String) -> Void) {
            self.onCredentialsFound = onCredentialsFound
            self.onFailure = onFailure
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            webView.navigationDelegate = self
            webView.configuration.websiteDataStore.httpCookieStore.add(self)
        }

        func detach(from webView: WKWebView) {
            completed = true
            webView.navigationDelegate = nil
            webView.configuration.websiteDataStore.httpCookieStore.remove(self)
            webView.stopLoading()
            self.webView = nil
        }

        func cookiesDidChange(in _: WKHTTPCookieStore) {
            checkCookies()
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            checkCookies()
        }

        func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard !completed else {
                decisionHandler(.cancel)
                return
            }
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            guard ["https", "http", "about"].contains(url.scheme?.lowercased() ?? "") else {
                decisionHandler(.cancel)
                return
            }

            // Login needs the session cookie, not the player and its JavaScript engine.
            if url.host?.lowercased() == "open.spotify.com", navigationAction.targetFrame?.isMainFrame != false {
                decisionHandler(.cancel)
                checkCookies(failureMessage: "Spotify didn't provide a login session. Please retry signing in.")
                return
            }
            decisionHandler(.allow)
        }

        func webViewWebContentProcessDidTerminate(_: WKWebView) {
            #if targetEnvironment(simulator)
                let message = "The simulator's web process stopped. Retry to continue. If it happens again, restart the simulator."
            #else
                let message = "The sign-in page stopped responding. Retry to continue."
            #endif
            checkCookies(failureMessage: message)
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            navigationFailed(error)
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            navigationFailed(error)
        }

        private func navigationFailed(_ error: Error) {
            let error = error as NSError
            guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
            checkCookies(failureMessage: "Couldn't load Spotify's sign-in page. Check your connection and retry.")
        }

        private func checkCookies(failureMessage: String? = nil) {
            guard !completed, let webView else { return }
            let attempt = retry
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.completed, retry == attempt else { return }
                if let credentials = CookieHeaderParser.extractSpotifyLoginCredentials(from: cookies) {
                    completed = true
                    self.webView?.stopLoading()
                    onCredentialsFound(credentials)
                } else if let failureMessage {
                    onFailure(failureMessage)
                }
            }
        }
    }
}
