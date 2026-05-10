import NoFeedSocialCore
import SwiftUI
import WebKit

struct SpotifyLoginWebView: View {
    @Environment(\.dismiss) private var dismiss
    var onLoginSuccess: (SpotifyCredentials) -> Void

    var body: some View {
        NavigationStack {
            SpotifyLoginWKWebView(
                url: URL(string: "https://accounts.spotify.com/en/login?continue=https://open.spotify.com/")!,
                onCredentialsFound: { creds in
                    onLoginSuccess(creds)
                    dismiss()
                }
            )
            .ignoresSafeArea()
            .navigationTitle("Log in to Spotify")
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

#if os(iOS)
    struct SpotifyLoginWKWebView: UIViewRepresentable {
        let url: URL
        let onCredentialsFound: (SpotifyCredentials) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onCredentialsFound: onCredentialsFound)
        }

        func makeUIView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()

            let script = WKUserScript(
                source: captureScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            config.userContentController.addUserScript(script)
            config.userContentController.add(context.coordinator, name: "spotifyTokenCapture")

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

            webView.load(URLRequest(url: url))
            return webView
        }

        func updateUIView(_: WKWebView, context _: Context) {}

        class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
            let onCredentialsFound: (SpotifyCredentials) -> Void
            private var captured = false
            private var pendingBearerToken: String?
            private var pendingClientToken: String?
            private weak var webView: WKWebView?

            init(onCredentialsFound: @escaping (SpotifyCredentials) -> Void) {
                self.onCredentialsFound = onCredentialsFound
            }

            func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
                guard !captured, let body = message.body as? [String: String] else { return }
                guard let bearerToken = body["bearerToken"] else { return }
                pendingBearerToken = bearerToken
                pendingClientToken = body["clientToken"]
                tryExtractCredentials()
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                self.webView = webView
                tryExtractCredentials()
            }

            func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
                guard let url = navigationAction.request.url, url.host == "open.spotify.com" else {
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
                self.webView = webView
                tryExtractCredentials()
            }

            private func tryExtractCredentials() {
                guard !captured, let bearer = pendingBearerToken, let view = webView else { return }

                view.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                    guard let self, !self.captured else { return }
                    let spDC = cookies.first(where: { $0.name == "sp_dc" })?.value ?? ""
                    let spT = cookies.first(where: { $0.name == "sp_t" })?.value ?? ""
                    guard !spDC.isEmpty, !spT.isEmpty else { return }

                    self.captured = true
                    let creds = SpotifyCredentials(
                        bearerToken: bearer,
                        clientToken: self.pendingClientToken ?? "",
                        spDC: spDC,
                        spT: spT,
                        username: nil
                    )
                    DispatchQueue.main.async {
                        self.onCredentialsFound(creds)
                    }
                }
            }
        }

        private var captureScript: String {
            """
            (function() {
                const origFetch = window.fetch;
                window.fetch = function(...args) {
                    return origFetch.apply(this, args).then(response => {
                        try {
                            const reqHeaders = args[1]?.headers;
                            if (reqHeaders) {
                                let bearer = null;
                                let clientToken = null;
                                if (reqHeaders instanceof Headers) {
                                    bearer = reqHeaders.get('authorization');
                                    clientToken = reqHeaders.get('client-token');
                                } else if (typeof reqHeaders === 'object') {
                                    for (const [k, v] of Object.entries(reqHeaders)) {
                                        if (k.toLowerCase() === 'authorization') bearer = v;
                                        if (k.toLowerCase() === 'client-token') clientToken = v;
                                    }
                                }
                                if (bearer && bearer.startsWith('Bearer ')) {
                                    window.webkit.messageHandlers.spotifyTokenCapture.postMessage({
                                        bearerToken: bearer.replace('Bearer ', ''),
                                        clientToken: clientToken || ''
                                    });
                                }
                            }
                        } catch(e) {}
                        return response;
                    });
                };

                const origXHROpen = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function(method, url) {
                    this._spotifyUrl = url;
                    return origXHROpen.apply(this, arguments);
                };
                const origXHRSetHeader = XMLHttpRequest.prototype.setRequestHeader;
                XMLHttpRequest.prototype.setRequestHeader = function(header, value) {
                    if (header.toLowerCase() === 'authorization' && value.startsWith('Bearer ')) {
                        window.webkit.messageHandlers.spotifyTokenCapture.postMessage({
                            bearerToken: value.replace('Bearer ', ''),
                            clientToken: ''
                        });
                    }
                    return origXHRSetHeader.apply(this, arguments);
                };
            })();
            """
        }
    }
#else
    struct SpotifyLoginWKWebView: NSViewRepresentable {
        let url: URL
        let onCredentialsFound: (SpotifyCredentials) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onCredentialsFound: onCredentialsFound)
        }

        func makeNSView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()

            let script = WKUserScript(
                source: captureScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            config.userContentController.addUserScript(script)
            config.userContentController.add(context.coordinator, name: "spotifyTokenCapture")

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

            webView.load(URLRequest(url: url))
            return webView
        }

        func updateNSView(_: WKWebView, context _: Context) {}

        class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
            let onCredentialsFound: (SpotifyCredentials) -> Void
            private var captured = false
            private var pendingBearerToken: String?
            private var pendingClientToken: String?
            private weak var webView: WKWebView?

            init(onCredentialsFound: @escaping (SpotifyCredentials) -> Void) {
                self.onCredentialsFound = onCredentialsFound
            }

            func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
                guard !captured, let body = message.body as? [String: String] else { return }
                guard let bearerToken = body["bearerToken"] else { return }
                pendingBearerToken = bearerToken
                pendingClientToken = body["clientToken"]
                tryExtractCredentials()
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                self.webView = webView
                tryExtractCredentials()
            }

            func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
                guard let url = navigationAction.request.url, url.host == "open.spotify.com" else {
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
                self.webView = webView
                tryExtractCredentials()
            }

            private func tryExtractCredentials() {
                guard !captured, let bearer = pendingBearerToken, let view = webView else { return }

                view.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                    guard let self, !self.captured else { return }
                    let spDC = cookies.first(where: { $0.name == "sp_dc" })?.value ?? ""
                    let spT = cookies.first(where: { $0.name == "sp_t" })?.value ?? ""
                    guard !spDC.isEmpty, !spT.isEmpty else { return }

                    self.captured = true
                    let creds = SpotifyCredentials(
                        bearerToken: bearer,
                        clientToken: self.pendingClientToken ?? "",
                        spDC: spDC,
                        spT: spT,
                        username: nil
                    )
                    DispatchQueue.main.async {
                        self.onCredentialsFound(creds)
                    }
                }
            }
        }

        private var captureScript: String {
            """
            (function() {
                const origFetch = window.fetch;
                window.fetch = function(...args) {
                    return origFetch.apply(this, args).then(response => {
                        try {
                            const reqHeaders = args[1]?.headers;
                            if (reqHeaders) {
                                let bearer = null;
                                let clientToken = null;
                                if (reqHeaders instanceof Headers) {
                                    bearer = reqHeaders.get('authorization');
                                    clientToken = reqHeaders.get('client-token');
                                } else if (typeof reqHeaders === 'object') {
                                    for (const [k, v] of Object.entries(reqHeaders)) {
                                        if (k.toLowerCase() === 'authorization') bearer = v;
                                        if (k.toLowerCase() === 'client-token') clientToken = v;
                                    }
                                }
                                if (bearer && bearer.startsWith('Bearer ')) {
                                    window.webkit.messageHandlers.spotifyTokenCapture.postMessage({
                                        bearerToken: bearer.replace('Bearer ', ''),
                                        clientToken: clientToken || ''
                                    });
                                }
                            }
                        } catch(e) {}
                        return response;
                    });
                };
            })();
            """
        }
    }
#endif
