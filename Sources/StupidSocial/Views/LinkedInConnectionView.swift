import StupidSocialCore
import SwiftUI

/// Adds a LinkedIn account (`accountId` nil), or shows one account's settings.
struct LinkedInConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let accountId: String?
    let onDone: () -> Void
    @State private var liAt = ""
    @State private var jsessionId = ""

    var body: some View {
        LoginConnectionForm(viewModel: viewModel, network: .linkedin, accountId: accountId, onDone: onDone) {
            SecureField("li_at", text: $liAt)
            SecureField("JSESSIONID", text: $jsessionId)
        } saveManual: {
            let credentials = LinkedInCredentials(
                liAt: liAt.trimmingCharacters(in: .whitespacesAndNewlines),
                jsessionId: jsessionId.trimmingCharacters(in: .whitespacesAndNewlines),
            )
            liAt = ""
            jsessionId = ""
            return await viewModel.addLinkedIn(credentials, reconnecting: accountId)
        } login: { complete in
            LinkedInLoginWebView { credentials in
                complete { await viewModel.addLinkedIn(credentials, reconnecting: accountId) }
            }
        }
    }
}
