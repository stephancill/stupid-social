import AuthenticationServices
import StupidSocialCore
import UIKit

/// A sign-in session (`ASWebAuthenticationSession`) over the key window, for OAuth sign-in pages: Bluesky, and an
/// Apron server's passkey and sign-in pages. Never an embedded web view (PROTOCOL.md §4.12.2).
final class WebAuthenticationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let session: ASWebAuthenticationSession

    /// `completion` gets the URL the page redirected to, or `nil` when the user closed the sheet or it failed.
    init(url: URL, callbackURLScheme: String, completion: @escaping (URL?) -> Void) {
        session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme) { callbackURL, _ in
            completion(callbackURL)
        }
        super.init()
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
    }

    /// `false` when the session couldn't be shown, and then `completion` is never called.
    @discardableResult
    func start() -> Bool {
        session.start()
    }

    func cancel() {
        session.cancel()
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    /// Opens an Apron server's page and returns the URL it redirected to; closing the sheet is
    /// `ApronError.signInDeclined`.
    @MainActor
    static func openApronPage(_ url: URL) async throws -> URL {
        var webSession: WebAuthenticationSession?
        let callbackURL: URL? = try await withCheckedThrowingContinuation { continuation in
            webSession = WebAuthenticationSession(url: url, callbackURLScheme: ApronPageSignIn.callbackScheme) { callbackURL in
                continuation.resume(returning: callbackURL)
            }
            if webSession?.start() != true {
                continuation.resume(throwing: ApronError.signInFailed)
            }
        }
        // Kept until the page is done: the session ends when its provider goes away.
        withExtendedLifetime(webSession) {}
        guard let callbackURL else { throw ApronError.signInDeclined }
        return callbackURL
    }
}
