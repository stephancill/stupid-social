import StupidSocialCore
import SwiftUI

/// LinkedIn's login page; finishes once the store holds the `li_at` session cookie and its `JSESSIONID`.
struct LinkedInLoginWebView: View {
    @Environment(\.dismiss) private var dismiss
    let onLoginSuccess: (LinkedInCredentials) -> Void

    var body: some View {
        LoginSheet(title: "Log in to LinkedIn") {
            CookieLoginWebView(
                url: URL(string: "https://www.linkedin.com/login")!,
                sessionCookies: ["li_at", "JSESSIONID"],
                domainSuffix: "linkedin.com",
                userAgent: LinkedInClient.userAgent,
                credentials: LinkedInCredentials.init(cookies:),
            ) { credentials in
                onLoginSuccess(credentials)
                dismiss()
            }
            .ignoresSafeArea()
        }
    }
}
