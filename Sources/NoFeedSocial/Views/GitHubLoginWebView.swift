import NoFeedSocialCore
import SwiftUI

struct GitHubLoginWebView: View {
    @Environment(\.dismiss) private var dismiss
    let onLoginSuccess: (GitHubCredentials) -> Void

    var body: some View {
        LoginSheet(title: "Log in to GitHub") {
            CookieLoginWebView(
                url: URL(string: "https://github.com/login")!,
                sessionCookies: ["user_session", "__Host-user_session_same_site", "logged_in", "dotcom_user"],
                domainSuffix: "github.com",
                credentials: Self.credentials(from:),
            ) { credentials in
                onLoginSuccess(credentials)
                dismiss()
            }
            .ignoresSafeArea()
        }
    }

    private static func credentials(from cookies: [HTTPCookie]) -> GitHubCredentials? {
        let values = Dictionary(
            cookies
                .filter { $0.domain == "github.com" || $0.domain.hasSuffix(".github.com") }
                .map { ($0.name, $0.value) },
            uniquingKeysWith: { _, latest in latest },
        )
        guard let session = values["user_session"], let sameSite = values["__Host-user_session_same_site"] else { return nil }
        return GitHubCredentials(
            userSession: session,
            sameSiteUserSession: sameSite,
            username: values["dotcom_user"],
            additionalCookies: values.filter { $0.key != "user_session" && $0.key != "__Host-user_session_same_site" },
        )
    }
}
