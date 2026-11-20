import StupidSocialCore
import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: ProfileSearchViewModel
    @AppStorage("redactionEnabled") private var redactionEnabled = false

    private static let searchNetworks: [SocialNetwork] = [
        .x, .instagram, .farcaster, .spotify, .bluesky,
    ]

    var body: some View {
        List {
            if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !viewModel.recentProfiles.isEmpty {
                recentSection
            } else if viewModel.filteredResults.isEmpty {
                emptyState
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                Section("Profiles") {
                    ForEach(viewModel.filteredResults, id: \.self) { profile in
                        NavigationLink {
                            ProfileDetailView(
                                actor: actor(from: profile),
                                feedService: viewModel.service,
                                initialProfile: profile,
                            )
                            .onAppear { viewModel.recordVisit(profile) }
                        } label: {
                            ProfileSearchRow(profile: profile, redactionEnabled: redactionEnabled)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Search")
        // Under the title, as in Chats: the field `.automatic` floats at the bottom stayed under the keyboard in the
        // home pager, whose pages don't follow the keyboard themselves (`HomePagerController`).
        .searchBar(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                filterMenu
            }
        }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.scheduleSearch()
        }
    }

    /// Profiles opened from search, while the field is empty: swipe one away, or clear them all.
    private var recentSection: some View {
        Section {
            ForEach(viewModel.recentProfiles) { recent in
                NavigationLink {
                    ProfileDetailView(actor: recent.actor, feedService: viewModel.service, initialProfile: recent.profile)
                        .onAppear { viewModel.recordVisit(recent.profile) }
                } label: {
                    ProfileSearchRow(profile: recent.profile, redactionEnabled: redactionEnabled)
                }
            }
            .onDelete { offsets in
                for recent in offsets.map({ viewModel.recentProfiles[$0] }) {
                    viewModel.removeRecent(recent)
                }
            }
        } header: {
            HStack {
                Text("Recent")
                Spacer()
                Button("Clear") { viewModel.clearRecents() }
                    .font(.subheadline)
                    .textCase(nil)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            ForEach(Self.searchNetworks, id: \.self) { network in
                Toggle(network.displayName, isOn: networkBinding(network))
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isSearching {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 320)
        } else if let errorMessage = viewModel.errorMessage {
            ContentUnavailableView(
                "No Results",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text(errorMessage),
            )
            .frame(minHeight: 320)
        } else {
            ContentUnavailableView(
                "Search Profiles",
                systemImage: "magnifyingglass",
                description: Text("Enter a handle to search connected networks."),
            )
            .frame(minHeight: 320)
        }
    }

    private func actor(from profile: NetworkProfile) -> NotificationActor {
        NotificationActor(
            id: profile.id,
            network: profile.network,
            username: profile.username,
            displayName: profile.displayName,
            avatarURL: profile.avatarURL,
        )
    }

    private func networkBinding(_ network: SocialNetwork) -> Binding<Bool> {
        Binding(
            get: { viewModel.enabledNetworks.contains(network) },
            set: { enabled in
                if enabled {
                    viewModel.enabledNetworks.insert(network)
                } else {
                    viewModel.enabledNetworks.remove(network)
                }
            },
        )
    }
}

private struct ProfileSearchRow: View {
    let profile: NetworkProfile
    let redactionEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            avatar
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(displayName)
                        .font(.body.weight(.medium))
                    if profile.isVerified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }

                HStack(spacing: 6) {
                    NetworkBadgeIcon(network: profile.network, size: 15)
                    if let username = profile.username, !username.isEmpty {
                        Text(redactionEnabled ? "Redacted" : "@\(username)")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var avatar: some View {
        if let avatarURL = profile.avatarURL {
            CachedAsyncImage(url: avatarURL) {
                avatarFallback
            } failure: {
                avatarFallback
            }
            .clipShape(Circle())
        } else {
            avatarFallback
        }
    }

    private var avatarFallback: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.18))
            Text(initial)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var displayName: String {
        let value = profile.displayName ?? profile.username ?? profile.id
        return DebugRedaction.username(value, enabled: redactionEnabled)
    }

    private var initial: String {
        let value = profile.username ?? profile.displayName ?? profile.id
        return value.first.map { String($0).uppercased() } ?? "?"
    }
}
