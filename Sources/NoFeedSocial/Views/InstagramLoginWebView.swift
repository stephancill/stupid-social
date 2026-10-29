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
        LoginSheet(title: "Log in to Instagram") {
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
        Coordinator(onCookiesFound: onCookiesFound)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let onCookiesFound: ([HTTPCookie]) -> Void
        private var hasNotified = false
        /// The challenge opens once; reopening it from every page it passes through would loop.
        private var hasOpenedChallenge = false

        init(onCookiesFound: @escaping ([HTTPCookie]) -> Void) {
            self.onCookiesFound = onCookiesFound
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            guard !hasNotified else { return }
            if isLoginOrChallengePage(url: webView.url) { return }
            checkForAuthCookies(webView: webView)
        }

        private func isLoginOrChallengePage(url: URL?) -> Bool {
            guard let path = url?.path else { return false }
            // `/challenge/` hands off to Meta's `/auth_platform/` pages, which run the checkpoint.
            return path.contains("login") || path.contains("challenge") || path.contains("emailsignup") || path.hasPrefix("/auth_platform/")
        }

        private func checkForAuthCookies(webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                guard hasRequiredInstagramCookies(cookies) else { return }
                Task { @MainActor in
                    // The homepage still renders signed in for a session under a security checkpoint, so its
                    // cookies would be saved again and fail every API call. Resolve the checkpoint here first.
                    if let challenge = await self.pendingChallengeURL(webView: webView) {
                        // Still locked after the challenge ran: stay put rather than save cookies that can't work.
                        guard !self.hasOpenedChallenge else { return }
                        self.hasOpenedChallenge = true
                        webView.load(URLRequest(url: challenge))
                        return
                    }
                    guard !self.hasNotified else { return }
                    self.hasNotified = true
                    self.onCookiesFound(cookies)
                }
            }
        }

        /// Calls the API from the page, which answers `checkpoint_required` with the challenge URL for a session
        /// Instagram has locked, or a logged-out page (validated with `instagram-web-client.py session-check`).
        @MainActor private func pendingChallengeURL(webView: WKWebView) async -> URL? {
            let script = """
            const response = await fetch('/api/v1/accounts/edit/web_form_data/', {
                credentials: 'include',
                headers: { 'X-IG-App-ID': '\(InstagramClient.webAppID)', 'X-Requested-With': 'XMLHttpRequest' },
            });
            const text = await response.text();
            try {
                const body = JSON.parse(text);
                return [body.message || '', body.checkpoint || ''];
            } catch {
                return [/class="[^"]*\\bnot-logged-in\\b/.test(text.slice(0, 4096)) ? 'login_required' : '', ''];
            }
            """
            guard let result = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [String],
                  result.count == 2, ["checkpoint_required", "challenge_required", "login_required"].contains(result[0])
            else { return nil }
            if let url = URL(string: result[1]), url.host()?.hasSuffix("instagram.com") == true {
                return url
            }
            return URL(string: "https://www.instagram.com/accounts/login/")
        }
    }
}
