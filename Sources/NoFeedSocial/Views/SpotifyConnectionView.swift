import NoFeedSocialCore
import SwiftUI

/// Adds a Spotify account (`accountId` nil), or shows one account's settings.
struct SpotifyConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let accountId: String?
    let onDone: () -> Void

    var body: some View {
        LoginConnectionForm(viewModel: viewModel, network: .spotify, accountId: accountId, onDone: onDone) {
            TextField("Bearer token", text: $viewModel.spotifyBearerToken, axis: .vertical)
                .lineLimit(2 ... 4)
                .textFieldStyle(.plain)
            TextField("Client token", text: $viewModel.spotifyClientToken, axis: .vertical)
                .lineLimit(2 ... 4)
                .textFieldStyle(.plain)
            TextField("sp_dc cookie", text: $viewModel.spotifySpDC, axis: .vertical)
                .lineLimit(1 ... 2)
                .textFieldStyle(.plain)
        } saveManual: {
            await viewModel.addSpotifyManualCredentials()
        } login: { complete in
            SpotifyLoginWebView { credentials in
                complete { await viewModel.addSpotify(credentials, reconnecting: accountId) }
            }
        }
    }
}
