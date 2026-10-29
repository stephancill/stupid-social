import NoFeedSocialCore
import SwiftUI

/// Adds a GitHub account (`accountId` nil), or shows one account's settings.
struct GitHubConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let accountId: String?
    let onDone: () -> Void

    var body: some View {
        LoginConnectionForm(viewModel: viewModel, network: .github, accountId: accountId, onDone: onDone) {
            TextField("Cookie header", text: $viewModel.githubCookieHeader, axis: .vertical)
                .lineLimit(2 ... 4)
                .textFieldStyle(.plain)
        } saveManual: {
            await viewModel.addGitHubCookieHeader()
        } login: { complete in
            GitHubLoginWebView { credentials in
                complete { await viewModel.addGitHub(credentials, reconnecting: accountId) }
            }
        }
    }
}
