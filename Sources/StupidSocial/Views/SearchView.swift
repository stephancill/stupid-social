import StupidSocialCore
import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: ProfileSearchViewModel
    @AppStorage("redactionEnabled") private var redactionEnabled = false
    /// Whether the search field is focused; the network pills show (and apply) only then.
    @State private var isSearchPresented = false
    /// Follows `isSearchPresented` with an animation of its own: the field's focus changes without one, so the
    /// pills appeared at once and the navigation bar then slid the field up over them.
    @State private var showsFilter = false

    var body: some View {
        let showsRecents = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.filteredRecentProfiles.isEmpty

        List {
            // A row rather than a bar pinned under the field: any top `safeAreaBar`, even one with no height, made the
            // rows jump instead of sliding up with the field as the search took focus.
            if showsFilter, viewModel.searchableNetworks.count > 1 {
                // A header rather than a row, which the inset-grouped card clipped at its edge; out by the header's
                // inset, so the pills scroll to the screen's edges and line up with the search field.
                Section {} header: {
                    NetworkFilterBar(networks: viewModel.searchableNetworks, selection: $viewModel.selectedNetworks)
                        .textCase(nil)
                        .padding(.horizontal, -16)
                        .modifier(FadesInOnAppear())
                }
                .listSectionSpacing(.compact)
            }
            if showsRecents {
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
        .contentMargins(.top, 0, for: .scrollContent)
        .navigationTitle("Search")
        // Under the title, as in Chats: the field `.automatic` floats at the bottom stayed under the keyboard in the
        // home pager, whose pages don't follow the keyboard themselves (`HomePagerController`).
        .searchBar(text: $viewModel.query, isPresented: $isSearchPresented, placement: .navigationBarDrawer(displayMode: .always))
        .onAppear { viewModel.refreshSearchableNetworks() }
        // The pills are gone once the search ends, so a filter left on would hide recents with nothing to show why.
        .onChange(of: isSearchPresented) { _, presented in
            if !presented { viewModel.selectedNetworks = [] }
            // On the next turn of the run loop: changed in the same one as the field's own transition, the row's
            // removal wasn't animated, so the rows jumped up by its height.
            Task { @MainActor in
                withAnimation(.smooth(duration: 0.3)) { showsFilter = presented }
            }
        }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.scheduleSearch()
        }
    }

    /// Profiles opened from search, while the field is empty: swipe one away, or clear them all.
    private var recentSection: some View {
        Section {
            ForEach(viewModel.filteredRecentProfiles) { recent in
                NavigationLink {
                    ProfileDetailView(actor: recent.actor, feedService: viewModel.service, initialProfile: recent.profile)
                        .onAppear { viewModel.recordVisit(recent.profile) }
                } label: {
                    ProfileSearchRow(profile: recent.profile, redactionEnabled: redactionEnabled)
                }
            }
            .onDelete { offsets in
                for recent in offsets.map({ viewModel.filteredRecentProfiles[$0] }) {
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

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isSearching {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 320)
        } else if !viewModel.results.isEmpty {
            ContentUnavailableView(
                "No Results",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("No matching profiles on the selected networks."),
            )
            .frame(minHeight: 320)
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

/// Fades its content in once it has appeared: a list's section header shows at once, without the insertion's
/// transition, over the rows below as they move down to make room; an animation started in `onAppear` itself was
/// dropped.
private struct FadesInOnAppear: ViewModifier {
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(.smooth(duration: 0.25)) { isShown = true }
            }
    }
}
