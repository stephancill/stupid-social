import NoFeedSocialCore
import SwiftUI
import WebKit

struct XLoginWebView: View {
    @Environment(\.dismiss) private var dismiss

    var onLoginSuccess: (XCredentials) -> Void

    var body: some View {
        NavigationStack {
            XLoginWKWebView(
                url: URL(string: "https://x.com/i/flow/login")!,
                onCookiesFound: { cookies in
                    guard let creds = extractCredentials(from: cookies) else { return }
                    onLoginSuccess(creds)
                    dismiss()
                },
            )
            .ignoresSafeArea()
            .navigationTitle("Log in to X")
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

    private func extractCredentials(from cookies: [HTTPCookie]) -> XCredentials? {
        let cookieDict = cookies.reduce(into: [String: String]()) { values, cookie in
            values[cookie.name] = cookie.value
        }
        guard let authToken = cookieDict["auth_token"], let ct0 = cookieDict["ct0"] else {
            return nil
        }
        return XCredentials(authToken: authToken, ct0: ct0)
    }
}

#if os(iOS)
    private struct XLoginWKWebView: UIViewRepresentable {
        let url: URL
        let onCookiesFound: ([HTTPCookie]) -> Void

        func makeUIView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            context.coordinator.webView = webView
            webView.configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
            #if DEBUG
                if #available(iOS 16.4, *) {
                    webView.isInspectable = true
                }
            #endif
            webView.load(URLRequest(url: url))
            return webView
        }

        func updateUIView(_: WKWebView, context _: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(onCookiesFound: onCookiesFound)
        }

        class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
            let onCookiesFound: ([HTTPCookie]) -> Void
            weak var webView: WKWebView?
            private var hasNotified = false

            init(onCookiesFound: @escaping ([HTTPCookie]) -> Void) {
                self.onCookiesFound = onCookiesFound
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                guard !hasNotified else { return }
                checkForAuthCookies(webView: webView)
            }

            func cookiesDidChange(in _: WKHTTPCookieStore) {
                guard let webView, !hasNotified else { return }
                checkForAuthCookies(webView: webView)
            }

            private func checkForAuthCookies(webView: WKWebView) {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let cookieNames = Set(cookies.map(\.name))
                    guard cookieNames.contains("auth_token"), cookieNames.contains("ct0") else { return }
                    self.hasNotified = true
                    DispatchQueue.main.async {
                        self.onCookiesFound(cookies)
                    }
                }
            }
        }
    }
#else
    private struct XLoginWKWebView: NSViewRepresentable {
        let url: URL
        let onCookiesFound: ([HTTPCookie]) -> Void

        func makeNSView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            context.coordinator.webView = webView
            webView.configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
            #if DEBUG
                if #available(macOS 13.3, *) {
                    webView.isInspectable = true
                }
            #endif
            webView.load(URLRequest(url: url))
            return webView
        }

        func updateNSView(_: WKWebView, context _: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(onCookiesFound: onCookiesFound)
        }

        class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
            let onCookiesFound: ([HTTPCookie]) -> Void
            weak var webView: WKWebView?
            private var hasNotified = false

            init(onCookiesFound: @escaping ([HTTPCookie]) -> Void) {
                self.onCookiesFound = onCookiesFound
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                guard !hasNotified else { return }
                checkForAuthCookies(webView: webView)
            }

            func cookiesDidChange(in _: WKHTTPCookieStore) {
                guard let webView, !hasNotified else { return }
                checkForAuthCookies(webView: webView)
            }

            private func checkForAuthCookies(webView: WKWebView) {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let cookieNames = Set(cookies.map(\.name))
                    guard cookieNames.contains("auth_token"), cookieNames.contains("ct0") else { return }
                    self.hasNotified = true
                    DispatchQueue.main.async {
                        self.onCookiesFound(cookies)
                    }
                }
            }
        }
    }
#endif
