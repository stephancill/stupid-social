import NoFeedSocialCore
import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: ProfileSearchViewModel
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    @FocusState private var isSearchFocused: Bool

    private static let searchNetworks: [SocialNetwork] = [
        .x, .instagram, .farcaster, .spotify, .bluesky,
    ]

    var body: some View {
        NavigationStack {
            List {
                if viewModel.filteredResults.isEmpty {
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
            .safeAreaInset(edge: .top, spacing: 0) {
                searchField
            }
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(Self.searchNetworks, id: \.self) { network in
                            Toggle(network.displayName, isOn: networkBinding(network))
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                }
            }
            .onChange(of: viewModel.query) { _, _ in
                viewModel.scheduleSearch()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search profiles", text: $viewModel.query)
                .focused($isSearchFocused)
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
                .autocorrectionDisabled()
                .onSubmit {
                    Task { await viewModel.search() }
                }
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, 8)
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
