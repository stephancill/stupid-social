import NoFeedSocialCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.openURL) private var openURL
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        Form {
            Section("Connections") {
                NavigationLink {
                    XConnectionView(viewModel: viewModel)
                } label: {
                    connectionRow(
                        name: "X",
                        subtitle: viewModel.xConnectionLabel,
                        isInvalid: viewModel.xStatus == .invalidCredentials,
                    )
                }

                NavigationLink {
                    FarcasterConnectionView(viewModel: viewModel)
                } label: {
                    connectionRow(
                        name: "Farcaster",
                        subtitle: viewModel.farcasterConnectionLabel,
                        isInvalid: viewModel.farcasterStatus == .invalidCredentials,
                    )
                }

                NavigationLink {
                    InstagramConnectionView(viewModel: viewModel)
                } label: {
                    connectionRow(
                        name: "Instagram",
                        subtitle: viewModel.instagramConnectionLabel,
                        isInvalid: viewModel.instagramStatus == .invalidCredentials,
                    )
                }

                NavigationLink {
                    SpotifyConnectionView(viewModel: viewModel)
                } label: {
                    connectionRow(
                        name: "Spotify",
                        subtitle: viewModel.spotifyConnectionLabel,
                        isInvalid: viewModel.spotifyStatus == .invalidCredentials,
                    )
                }

                NavigationLink {
                    BlueskyConnectionView(viewModel: viewModel)
                } label: {
                    connectionRow(
                        name: "Bluesky",
                        subtitle: viewModel.blueskyConnectionLabel,
                        isInvalid: viewModel.blueskyStatus == .invalidCredentials,
                    )
                }

                if devModeEnabled {
                    NavigationLink {
                        DebugConnectionView(viewModel: viewModel)
                    } label: {
                        connectionRow(
                            name: "Debug",
                            subtitle: viewModel.debugConnectionLabel,
                            isInvalid: viewModel.debugStatus == .invalidCredentials,
                        )
                    }
                }
            }

            Section {
                Button {
                    openURL(URL(string: "https://stupidtech.net")!)
                } label: {
                    HStack {
                        Text("stupidtech.net")
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    openURL(URL(string: "https://github.com/stephancill/stupid-social")!)
                } label: {
                    HStack {
                        Text("GitHub")
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("About")
                    .onTapGesture(count: 4) {
                        devModeEnabled.toggle()
                    }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            viewModel.loadStatuses()
        }
    }

    private func connectionRow(name: String, subtitle: String, isInvalid: Bool = false) -> some View {
        HStack {
            if isInvalid {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Invalid credentials")
            }
            Text(name)
                .font(.body)
            Spacer()
            Text(redactedSubtitle(subtitle))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func redactedSubtitle(_ subtitle: String) -> String {
        guard devModeEnabled, subtitle.hasPrefix("@") else { return subtitle }
        return "Redacted"
    }
}
