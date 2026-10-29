import SwiftUI
import WebKit

/// A network's login page in a sheet, under an inline title and a Cancel button.
struct LoginSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

/// A login page in the persistent web store that finishes once the store's cookies hold a session.
/// The last login's session cookies are deleted first, so this login can be another account; the site's other
/// cookies stay, which keeps sites such as X from treating the login as a new device.
struct CookieLoginWebView<Credentials>: UIViewRepresentable {
    let url: URL
    /// The session cookies a previous login left, deleted before the page loads.
    let sessionCookies: Set<String>
    let domainSuffix: String
    /// The credentials in the store's cookies, or `nil` until the login has finished.
    let credentials: ([HTTPCookie]) -> Credentials?
    let onLogin: (Credentials) -> Void

    func makeCoordinator() -> CookieLoginCoordinator {
        CookieLoginCoordinator { cookies in
            guard let found = credentials(cookies) else { return false }
            onLogin(found)
            return true
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        #if DEBUG
            webView.isInspectable = true
        #endif
        let cookieStore = configuration.websiteDataStore.httpCookieStore
        Task { @MainActor [coordinator = context.coordinator, sessionCookies, domainSuffix, url] in
            await cookieStore.deleteCookies(named: sessionCookies, domainSuffix: domainSuffix)
            cookieStore.add(coordinator)
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}
}

/// Checks the store's cookies after each page load and cookie change until `capture` takes them.
@MainActor
final class CookieLoginCoordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    weak var webView: WKWebView?
    private let capture: ([HTTPCookie]) -> Bool
    private var captured = false

    init(capture: @escaping ([HTTPCookie]) -> Bool) {
        self.capture = capture
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
        Task { @MainActor in
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard !captured else { return }
            captured = capture(cookies)
        }
    }
}

extension WKHTTPCookieStore {
    /// Deletes the named cookies on the domain and its subdomains, such as a previous login's session.
    func deleteCookies(named names: Set<String>, domainSuffix: String) async {
        for cookie in await allCookies() where names.contains(cookie.name) && cookie.domain.hasSuffix(domainSuffix) {
            await deleteCookie(cookie)
        }
    }
}
