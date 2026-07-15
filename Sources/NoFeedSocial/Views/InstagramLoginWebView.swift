import NoFeedSocialCore
import SwiftUI
import WebKit

private func hasRequiredInstagramCookies(_ cookies: [HTTPCookie]) -> Bool {
    let names = Set(cookies.map(\.name))
    return names.isSuperset(of: ["sessionid", "csrftoken", "ds_user_id", "mid", "rur", "ig_did"])
}

struct InstagramLoginWebView: View {
    @Environment(\.dismiss) private var dismiss

    var initialCredentials: InstagramCredentials?
    var onLoginSuccess: (InstagramCredentials) -> Void

    var body: some View {
        NavigationStack {
            InstagramLoginWKWebView(
                url: URL(string: initialCredentials == nil ? "https://www.instagram.com/accounts/login/" : "https://www.instagram.com/")!,
                initialCredentials: initialCredentials,
                onCookiesFound: { cookies in
                    for cookie in cookies {
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                    guard let creds = extractCredentials(from: cookies) else { return }
                    onLoginSuccess(creds)
                    dismiss()
                },
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
        let cookieDict = cookies.reduce(into: [String: String]()) { values, cookie in
            values[cookie.name] = cookie.value
        }
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
            igDid: cookieDict["ig_did"],
        )
    }
}

private func cookies(from credentials: InstagramCredentials?) -> [HTTPCookie] {
    guard let credentials else { return [] }
    let values: [(String, String?)] = [
        ("sessionid", credentials.sessionId),
        ("csrftoken", credentials.csrfToken),
        ("ds_user_id", credentials.dsUserId),
        ("mid", credentials.mid),
        ("rur", credentials.rur),
        ("ig_did", credentials.igDid),
    ]
    return values.compactMap { name, value in
        guard let value, !value.isEmpty else { return nil }
        return HTTPCookie(properties: [
            .domain: ".instagram.com",
            .path: "/",
            .name: name,
            .value: value,
            .secure: "TRUE",
            .expires: Date(timeIntervalSinceNow: 60 * 60 * 24 * 365),
        ])
    }
}

@MainActor private func loadInstagramLogin(url: URL, initialCredentials: InstagramCredentials?, webView: WKWebView) {
    let seededCookies = cookies(from: initialCredentials)
    guard !seededCookies.isEmpty else {
        webView.load(URLRequest(url: url))
        return
    }

    let group = DispatchGroup()
    let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
    for cookie in seededCookies {
        group.enter()
        cookieStore.setCookie(cookie) {
            group.leave()
        }
    }
    group.notify(queue: .main) {
        webView.load(URLRequest(url: url))
    }
}

#if os(iOS)
    private struct InstagramLoginWKWebView: UIViewRepresentable {
        let url: URL
        let initialCredentials: InstagramCredentials?
        let onCookiesFound: ([HTTPCookie]) -> Void

        func makeUIView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            loadInstagramLogin(url: url, initialCredentials: initialCredentials, webView: webView)
            return webView
        }

        func updateUIView(_: WKWebView, context _: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(skipInitialCookieCheck: initialCredentials != nil, onCookiesFound: onCookiesFound)
        }

        class Coordinator: NSObject, WKNavigationDelegate {
            let onCookiesFound: ([HTTPCookie]) -> Void
            private var hasNotified = false
            private var skipInitialCookieCheck: Bool

            init(skipInitialCookieCheck: Bool, onCookiesFound: @escaping ([HTTPCookie]) -> Void) {
                self.skipInitialCookieCheck = skipInitialCookieCheck
                self.onCookiesFound = onCookiesFound
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                guard !hasNotified else { return }
                if skipInitialCookieCheck {
                    skipInitialCookieCheck = false
                    return
                }
                checkForAuthCookies(webView: webView)
            }

            private func checkForAuthCookies(webView: WKWebView) {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    guard hasRequiredInstagramCookies(cookies) else { return }
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
        let initialCredentials: InstagramCredentials?
        let onCookiesFound: ([HTTPCookie]) -> Void

        func makeNSView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            loadInstagramLogin(url: url, initialCredentials: initialCredentials, webView: webView)
            return webView
        }

        func updateNSView(_: WKWebView, context _: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(skipInitialCookieCheck: initialCredentials != nil, onCookiesFound: onCookiesFound)
        }

        class Coordinator: NSObject, WKNavigationDelegate {
            let onCookiesFound: ([HTTPCookie]) -> Void
            private var hasNotified = false
            private var skipInitialCookieCheck: Bool

            init(skipInitialCookieCheck: Bool, onCookiesFound: @escaping ([HTTPCookie]) -> Void) {
                self.skipInitialCookieCheck = skipInitialCookieCheck
                self.onCookiesFound = onCookiesFound
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                guard !hasNotified else { return }
                if skipInitialCookieCheck {
                    skipInitialCookieCheck = false
                    return
                }
                checkForAuthCookies(webView: webView)
            }

            private func checkForAuthCookies(webView: WKWebView) {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    guard hasRequiredInstagramCookies(cookies) else { return }
                    self.hasNotified = true
                    DispatchQueue.main.async {
                        self.onCookiesFound(cookies)
                    }
                }
            }
        }
    }
#endif
