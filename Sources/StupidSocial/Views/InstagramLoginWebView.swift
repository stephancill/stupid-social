import StupidSocialCore
import SwiftUI
import WebKit

/// The cookies the app can't work without. `mid`, `rur` and `ig_did` are kept when present, but a login isn't held
/// back for them: Instagram sets `rur` only after some logins, and waiting for it left the page sitting signed in.
private let requiredInstagramCookies: Set<String> = ["sessionid", "csrftoken", "ds_user_id"]

/// Why a login can't finish, shown below the page.
enum InstagramLoginProblem: Equatable {
    /// Instagram still asks to verify the login after its check ran here.
    case checkpoint
    /// Signed in, but without the session cookies the app needs.
    case missingCookies

    var message: String {
        switch self {
        case .checkpoint:
            "Instagram wants to verify this login. Finish the check in the Instagram app or at instagram.com, then try again."
        case .missingCookies:
            "Instagram signed in but didn't share the session this app needs. Try again."
        }
    }
}

/// Retries the page the login is on and holds what stopped it.
@MainActor
final class InstagramLoginController: ObservableObject {
    @Published var problem: InstagramLoginProblem?
    weak var webView: WKWebView?
    var onRetry: () -> Void = {}

    func retry() {
        problem = nil
        onRetry()
        webView?.load(URLRequest(url: URL(string: "https://www.instagram.com/")!))
    }
}

struct InstagramLoginWebView: View {
    @Environment(\.dismiss) private var dismiss

    var initialCredentials: InstagramCredentials?
    var onLoginSuccess: (InstagramCredentials) -> Void

    @StateObject private var controller = InstagramLoginController()

    var body: some View {
        LoginSheet(title: "Log in to Instagram") {
            InstagramLoginWKWebView(
                url: URL(string: initialCredentials == nil ? "https://www.instagram.com/accounts/login/" : "https://www.instagram.com/")!,
                initialCredentials: initialCredentials,
                controller: controller,
                onCookiesFound: { cookies in
                    for cookie in cookies {
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                    guard let creds = extractCredentials(from: cookies) else { return }
                    onLoginSuccess(creds)
                    dismiss()
                },
            )
            .ignoresSafeArea(edges: controller.problem == nil ? .all : [.top, .horizontal])
            .safeAreaInset(edge: .bottom) {
                if let problem = controller.problem {
                    VStack(spacing: 12) {
                        Text(problem.message)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                        Button("Try Again") { controller.retry() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.bar)
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

private struct InstagramLoginWKWebView: UIViewRepresentable {
    let url: URL
    let initialCredentials: InstagramCredentials?
    let controller: InstagramLoginController
    let onCookiesFound: ([HTTPCookie]) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        controller.webView = webView
        controller.onRetry = { [coordinator = context.coordinator] in coordinator.reset() }
        loadInstagramLogin(url: url, initialCredentials: initialCredentials, webView: webView)
        return webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onCookiesFound: onCookiesFound)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let controller: InstagramLoginController
        let onCookiesFound: ([HTTPCookie]) -> Void
        private var hasNotified = false
        /// The challenge opens once per try; reopening it from every page it passes through would loop.
        private var hasOpenedChallenge = false

        init(controller: InstagramLoginController, onCookiesFound: @escaping ([HTTPCookie]) -> Void) {
            self.controller = controller
            self.onCookiesFound = onCookiesFound
        }

        /// Try Again: the challenge may open once more.
        @MainActor func reset() {
            hasOpenedChallenge = false
        }

        /// Shows a problem and counts it once while it stays shown.
        @MainActor private func show(_ problem: InstagramLoginProblem) {
            guard controller.problem != problem else { return }
            controller.problem = problem
            AppMetrics.instagramLogin(outcome: problem == .checkpoint ? "checkpoint_unresolved" : "missing_cookies")
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
                let names = Set(cookies.map(\.name))
                // Without a session the page is still on the way to signing in (sign-up, password reset).
                guard names.contains("sessionid") else { return }
                Task { @MainActor in
                    guard names.isSuperset(of: requiredInstagramCookies) else {
                        self.show(.missingCookies)
                        return
                    }
                    // The homepage still renders signed in for a session under a security checkpoint, so its
                    // cookies would be saved again and fail every API call. Resolve the checkpoint here first.
                    if let challenge = await self.pendingChallengeURL(webView: webView) {
                        // Still locked after the challenge ran: say so rather than save cookies that can't work.
                        guard !self.hasOpenedChallenge else {
                            self.show(.checkpoint)
                            return
                        }
                        self.hasOpenedChallenge = true
                        AppMetrics.instagramLogin(outcome: "checkpoint")
                        webView.load(URLRequest(url: challenge))
                        return
                    }
                    guard !self.hasNotified else { return }
                    self.hasNotified = true
                    self.controller.problem = nil
                    AppMetrics.instagramLogin(outcome: "ok")
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
