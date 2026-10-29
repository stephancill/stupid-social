import NoFeedSocialCore
import SwiftUI

struct XLoginWebView: View {
    @Environment(\.dismiss) private var dismiss

    var onLoginSuccess: (XCredentials) -> Void

    var body: some View {
        LoginSheet(title: "Log in to X") {
            // Device cookies stay, which keeps X from limiting the login.
            CookieLoginWebView(
                url: URL(string: "https://x.com/i/flow/login")!,
                sessionCookies: ["auth_token", "ct0", "twid", "att"],
                domainSuffix: "x.com",
                credentials: Self.credentials(from:),
            ) { credentials in
                onLoginSuccess(credentials)
                dismiss()
            }
            .ignoresSafeArea()
        }
    }

    private static func credentials(from cookies: [HTTPCookie]) -> XCredentials? {
        let values = cookies.reduce(into: [String: String]()) { values, cookie in
            values[cookie.name] = cookie.value
        }
        guard let authToken = values["auth_token"], let ct0 = values["ct0"] else {
            return nil
        }
        return XCredentials(authToken: authToken, ct0: ct0)
    }
}
