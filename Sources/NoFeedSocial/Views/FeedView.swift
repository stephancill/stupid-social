import NoFeedSocialCore
import SwiftUI

struct FeedView: View {
    @ObservedObject var viewModel: FeedViewModel

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.items.isEmpty {
                    ContentUnavailableView(
                        "No Notifications",
                        systemImage: "bell.slash",
                        description: Text("Manual refresh will fetch Farcaster notifications and X once its endpoint spike is complete.")
                    )
                } else {
                    List {
                        if !unreadItems.isEmpty {
                            Section {
                                ForEach(unreadItems) { displayItem in
                                    NotificationLink(displayItem: displayItem)
                                }
                            }
                        }

                        if !unreadItems.isEmpty && !readItems.isEmpty {
                            NewSeparatorRow()
                        }

                        if !readItems.isEmpty {
                            Section {
                                ForEach(readItems) { displayItem in
                                    NotificationLink(displayItem: displayItem)
                                }
                            }
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    .listSectionSpacing(6)
                    #endif
                    .refreshable {
                        await viewModel.refresh()
                    }
                }
            }
            .navigationTitle("Notifications")
            .alert("Refresh Issue", isPresented: errorBinding) {
                Button("OK", role: .cancel) {
                    viewModel.errorMessage = nil
                }
            } message: {
                Text(viewModel.errorMessage ?? "Refresh failed.")
            }
        }
    }

    private var unreadItems: [DisplayNotificationItem] {
        viewModel.items.filter(\.isUnread)
    }

    private var readItems: [DisplayNotificationItem] {
        viewModel.items.filter { !$0.isUnread }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

private struct NotificationLink: View {
    let displayItem: DisplayNotificationItem

    var body: some View {
        NavigationLink {
            NotificationDetailView(displayItem: displayItem)
        } label: {
            NotificationRow(displayItem: displayItem)
        }
    }
}

private struct NewSeparatorRow: View {
    var body: some View {
        HStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(height: 1)
            Text("New")
                .font(.caption)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(height: 1)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowSeparator(.hidden)
        .environment(\.defaultMinListRowHeight, 24)
    }
}


private struct NotificationRow: View {
    let displayItem: DisplayNotificationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(displayItem.item.network.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(compactRelativeTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(summaryText)
                .font(.body)
                .fontWeight(displayItem.isUnread ? .semibold : .regular)
                .lineLimit(2)

            if let previewText {
                Text(previewText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var summaryText: String {
        switch displayItem.item.type {
        case .mention:
            "\(actorSummary) mentioned you"
        case .reply:
            "\(actorSummary) replied to you"
        case .reaction:
            displayItem.item.text
        case .follow:
            "\(actorSummary) followed you"
        case .unknown:
            displayItem.item.text
        }
    }

    private var previewText: String? {
        if displayItem.item.type == .reaction, let targetText = displayItem.item.target?.text, !targetText.isEmpty {
            return targetText
        }

        if let actor = displayItem.item.actors.first {
            return actor.username.map { "@\($0)" } ?? actor.id
        }

        return nil
    }

    private var actorSummary: String {
        guard let first = displayItem.item.actors.first else { return "Someone" }
        let firstName = first.username.map { "@\($0)" } ?? first.id
        let remainingCount = displayItem.item.actors.count - 1
        guard remainingCount > 0 else { return firstName }
        return "\(firstName) and \(remainingCount) other\(remainingCount == 1 ? "" : "s")"
    }

    private var compactRelativeTime: String {
        let seconds = max(0, Int(Date().timeIntervalSince(displayItem.item.timestamp)))
        if seconds < 60 { return "now" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 7 { return "\(days)d" }

        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w" }

        let months = days / 30
        if months < 12 { return "\(months)mo" }

        return "\(days / 365)y"
    }
}
