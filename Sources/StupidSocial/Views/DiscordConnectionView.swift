import StupidSocialCore
import SwiftUI

/// Adds a Discord account (`accountId` nil), or shows one account's settings.
struct DiscordConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let accountId: String?
    let onDone: () -> Void
    @State private var token = ""

    var body: some View {
        LoginConnectionForm(viewModel: viewModel, network: .discord, accountId: accountId, onDone: onDone) {
            SecureField("Token", text: $token)
        } saveManual: {
            let entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
            token = ""
            return await viewModel.addDiscord(token: entered, reconnecting: accountId)
        } login: { complete in
            DiscordLoginWebView { token in
                complete { await viewModel.addDiscord(token: token, reconnecting: accountId) }
            }
        }
    }
}
