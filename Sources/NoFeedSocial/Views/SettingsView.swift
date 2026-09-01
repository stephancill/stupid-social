import NoFeedSocialCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var onLoadDemoData: (() -> Void)?
    var onClearDemoData: (() -> Void)?
    @Environment(\.openURL) private var openURL
    @AppStorage("devModeEnabled") private var devModeEnabled = false
    @AppStorage("redactionEnabled") private var redactionEnabled = false

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

                NavigationLink {
                    GitHubConnectionView(viewModel: viewModel)
                } label: {
                    connectionRow(
                        name: "GitHub",
                        subtitle: viewModel.githubConnectionLabel,
                        isInvalid: viewModel.githubStatus == .invalidCredentials,
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

            #if DEBUG
                if devModeEnabled {
                    Section("Demo Data") {
                        Button {
                            onLoadDemoData?()
                        } label: {
                            Label("Load preview content", systemImage: "sparkles")
                        }
                        Button(role: .destructive) {
                            onClearDemoData?()
                        } label: {
                            Label("Unload preview content", systemImage: "minus.rectangle")
                        }
                        Toggle("Redact names", isOn: $redactionEnabled)
                    }
                }
            #endif

            if viewModel.hasLocalOnlyCredentials {
                Section {
                    #if targetEnvironment(simulator)
                        Text("Simulator credentials stay on this Mac and do not sync through iCloud Keychain.")
                    #else
                        Text("Some credentials are stored only on this device. Enable iCloud Keychain in System Settings; the app will retry when it next becomes active.")
                    #endif
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
        .onChange(of: devModeEnabled) { _, enabled in
            #if DEBUG
                if enabled {
                    onLoadDemoData?()
                } else {
                    onClearDemoData?()
                }
            #endif
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
        guard redactionEnabled, subtitle.hasPrefix("@") else { return subtitle }
        return "Redacted"
    }
}
