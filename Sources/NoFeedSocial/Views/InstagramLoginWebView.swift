import NoFeedSocialCore
import SwiftUI
import WebKit

struct InstagramLoginWebView: View {
    @Environment(\.dismiss) private var dismiss

    var onLoginSuccess: (InstagramCredentials) -> Void

    var body: some View {
        NavigationStack {
            InstagramLoginWKWebView(
                url: URL(string: "https://www.instagram.com/accounts/login/")!,
                onCookiesFound: { cookies in
                    for cookie in cookies {
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                    guard let creds = extractCredentials(from: cookies) else { return }
                    onLoginSuccess(creds)
                    dismiss()
                }
            )
            .ignoresSafeArea()
            .navigationTitle("Log in to Instagram")
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

    private func extractCredentials(from cookies: [HTTPCookie]) -> InstagramCredentials? {
        let cookieDict = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0.value) })
        guard let sessionId = cookieDict["sessionid"],
              let csrfToken = cookieDict["csrftoken"],
              let dsUserId = cookieDict["ds_user_id"]
        else {
            return nil
        }
        return InstagramCredentials(
            sessionId: sessionId,
            csrfToken: csrfToken,
            dsUserId: dsUserId,
            mid: cookieDict["mid"],
            rur: cookieDict["rur"],
            igDid: cookieDict["ig_did"]
        )
    }
}

#if os(iOS)
    private struct InstagramLoginWKWebView: UIViewRepresentable {
        let url: URL
        let onCookiesFound: ([HTTPCookie]) -> Void

        func makeUIView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            webView.customUserAgent = "Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Mobile Safari/537.36"
            webView.load(URLRequest(url: url))
            return webView
        }

        func updateUIView(_: WKWebView, context _: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(onCookiesFound: onCookiesFound)
        }

        class Coordinator: NSObject, WKNavigationDelegate {
            let onCookiesFound: ([HTTPCookie]) -> Void
            private var hasNotified = false

            init(onCookiesFound: @escaping ([HTTPCookie]) -> Void) {
                self.onCookiesFound = onCookiesFound
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                guard !hasNotified else { return }
                checkForAuthCookies(webView: webView)
            }

            private func checkForAuthCookies(webView: WKWebView) {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let hasAuth = cookies.contains { $0.name == "sessionid" }
                    guard hasAuth else { return }
                    self.hasNotified = true
                    DispatchQueue.main.async {
                        self.onCookiesFound(cookies)
                    }
                }
            }
        }
    }
#else
    private struct InstagramLoginWKWebView: NSViewRepresentable {
        let url: URL
        let onCookiesFound: ([HTTPCookie]) -> Void

        func makeNSView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            webView.customUserAgent = "Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Mobile Safari/537.36"
            webView.load(URLRequest(url: url))
            return webView
        }

        func updateNSView(_: WKWebView, context _: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(onCookiesFound: onCookiesFound)
        }

        class Coordinator: NSObject, WKNavigationDelegate {
            let onCookiesFound: ([HTTPCookie]) -> Void
            private var hasNotified = false

            init(onCookiesFound: @escaping ([HTTPCookie]) -> Void) {
                self.onCookiesFound = onCookiesFound
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                guard !hasNotified else { return }
                checkForAuthCookies(webView: webView)
            }

            private func checkForAuthCookies(webView: WKWebView) {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let hasAuth = cookies.contains { $0.name == "sessionid" }
                    guard hasAuth else { return }
                    self.hasNotified = true
                    DispatchQueue.main.async {
                        self.onCookiesFound(cookies)
                    }
                }
            }
        }
    }
#endif
