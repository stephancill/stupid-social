import NoFeedSocialCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("Connections") {
                NavigationLink {
                    XConnectionView(viewModel: viewModel)
                } label: {
                    connectionRow(
                        name: "X",
                        subtitle: viewModel.xConnectionLabel
                    )
                }

                NavigationLink {
                    FarcasterConnectionView(viewModel: viewModel)
                } label: {
                    connectionRow(
                        name: "Farcaster",
                        subtitle: viewModel.farcasterConnectionLabel
                    )
                }

                NavigationLink {
                    DebugConnectionView(viewModel: viewModel)
                } label: {
                    connectionRow(
                        name: "Debug",
                        subtitle: viewModel.debugConnectionLabel
                    )
                }
            }

            Section("About") {
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
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            viewModel.loadStatuses()
        }
    }

    private func connectionRow(name: String, subtitle: String) -> some View {
        HStack {
            Text(name)
                .font(.body)
            Spacer()
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

}
