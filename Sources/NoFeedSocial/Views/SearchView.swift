import NoFeedSocialCore
import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: ProfileSearchViewModel
    @AppStorage("devModeEnabled") private var devModeEnabled = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if viewModel.results.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    Section("Profiles") {
                        ForEach(viewModel.results, id: \.self) { profile in
                            NavigationLink {
                                ProfileDetailView(
                                    actor: actor(from: profile),
                                    feedService: viewModel.service,
                                    initialProfile: profile,
                                )
                            } label: {
                                ProfileSearchRow(profile: profile, devModeEnabled: devModeEnabled)
                            }
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("Search")
            .searchable(text: $viewModel.query, prompt: "Search profiles")
            .onChange(of: viewModel.query) { _, _ in
                viewModel.scheduleSearch()
            }
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .searchFocused($isSearchFocused)
            .onSubmit(of: .search) {
                Task { await viewModel.search() }
            }
            #endif
            .onAppear {
                isSearchFocused = true
            }
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
}

private struct ProfileSearchRow: View {
    let profile: NetworkProfile
    let devModeEnabled: Bool

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
                        Text(devModeEnabled ? "Redacted" : "@\(username)")
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
        return DebugRedaction.username(value, enabled: devModeEnabled)
    }

    private var initial: String {
        let value = profile.username ?? profile.displayName ?? profile.id
        return value.first.map { String($0).uppercased() } ?? "?"
    }
}
