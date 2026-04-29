import NoFeedSocialCore
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct FeedView: View {
    @ObservedObject var viewModel: FeedViewModel
    let settingsViewModel: SettingsViewModel

    var body: some View {
        NavigationStack {
            List {
                if viewModel.items.isEmpty {
                    VStack {
                        Spacer(minLength: 0)
                        ContentUnavailableView(
                            "No Notifications",
                            systemImage: "bell.slash",
                            description: Text("Set up X and Farcaster in Settings, then pull to refresh.")
                        )
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 600)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    if !unreadItems.isEmpty {
                        Section {
                            ForEach(Array(unreadItems.enumerated()), id: \.element.id) { index, displayItem in
                                NotificationLink(displayItem: displayItem)
                                    .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                            }
                        }
                        .listSectionSeparator(.hidden)
                    }

                    if !unreadItems.isEmpty && !readItems.isEmpty {
                        NewSeparatorRow()
                    }

                    if !readItems.isEmpty {
                        Section {
                            ForEach(Array(readItems.enumerated()), id: \.element.id) { index, displayItem in
                                NotificationLink(displayItem: displayItem)
                                    .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                            }
                        }
                        .listSectionSeparator(.hidden)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.plain)
            .listSectionSpacing(0)
            .scrollContentBackground(.hidden)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .refreshable {
                await viewModel.refresh()
            }
            .navigationTitle("Notifications")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SettingsView(viewModel: settingsViewModel)
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
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
        HStack(alignment: .top, spacing: 12) {
            NotificationTypeIcon(type: displayItem.item.type)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    if !displayItem.item.actors.isEmpty {
                        AvatarStrip(actors: displayItem.item.actors)
                    }

                    Spacer()

                    Text(compactRelativeTime)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                summaryView

                if let previewText {
                    Text(previewText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
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
            sanitizedItemText
        case .follow:
            "\(actorSummary) followed you"
        case .unknown:
            sanitizedItemText
        }
    }

    @ViewBuilder
    private var summaryView: some View {
        if displayItem.item.actors.first != nil, summaryText.hasPrefix(actorSummary) {
            HStack(alignment: .top, spacing: 4) {
                NetworkUsernameBadge(network: displayItem.item.network)
                    .padding(.top, 3)

                Text(summaryAttributedString)
                    .font(.body)
                    .lineLimit(2)
            }
        } else {
            Text(summaryText)
                .font(.body)
                .lineLimit(2)
        }
    }

    private var summaryAttributedString: AttributedString {
        var summary = AttributedString(summaryText)
        guard let actorRange = summary.range(of: actorSummary) else { return summary }
        summary[actorRange].font = .body.bold()
        return summary
    }

    private var previewText: String? {
        if (displayItem.item.type == .reaction
            || displayItem.item.type == .reply
            || displayItem.item.type == .mention),
           let targetText = displayItem.item.target?.text, !targetText.isEmpty {
            return targetText
        }

        if let actor = displayItem.item.actors.first {
            return actor.username ?? actor.id
        }

        return nil
    }

    private var sanitizedItemText: String {
        displayItem.item.actors.reduce(displayItem.item.text) { text, actor in
            guard let username = actor.username else { return text }
            return text.replacingOccurrences(of: "@\(username)", with: username)
        }
    }

    private var actorSummary: String {
        guard let first = displayItem.item.actors.first else { return "Someone" }
        let firstName = first.username ?? first.id
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

private struct NetworkUsernameBadge: View {
    let network: SocialNetwork

    var body: some View {
        Group {
            if let image = networkBadgeImage(named: network.badgeAssetName) {
                image
                    .resizable()
                    .interpolation(.high)
            } else {
                Text(network.badgeFallbackText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(network.badgeForegroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(network.badgeBackgroundColor)
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }
}

private extension SocialNetwork {
    var badgeAssetName: String {
        switch self {
        case .x:
            "XBadge"
        case .farcaster:
            "FarcasterBadge"
        }
    }

    var badgeFallbackText: String {
        switch self {
        case .x:
            "X"
        case .farcaster:
            "F"
        }
    }

    var badgeForegroundColor: Color {
        switch self {
        case .x:
            .black
        case .farcaster:
            .white
        }
    }

    var badgeBackgroundColor: Color {
        switch self {
        case .x:
            .white
        case .farcaster:
            Color(red: 0.52, green: 0.36, blue: 0.80)
        }
    }
}

private func networkBadgeImage(named name: String) -> Image? {
    guard let path = Bundle.main.path(forResource: name, ofType: "png") else { return nil }

    #if os(iOS)
    guard let image = UIImage(contentsOfFile: path) else { return nil }
    return Image(uiImage: image)
    #elseif os(macOS)
    guard let image = NSImage(contentsOfFile: path) else { return nil }
    return Image(nsImage: image)
    #else
    return nil
    #endif
}

private struct NotificationTypeIcon: View {
    let type: NotificationType

    var body: some View {
        Image(systemName: systemName)
            .font(.title2.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 32)
            .accessibilityLabel(accessibilityLabel)
    }

    private var systemName: String {
        switch type {
        case .reaction:
            "heart.fill"
        case .reply:
            "arrowshape.turn.up.left.fill"
        case .mention:
            "at"
        case .follow:
            "person.fill.badge.plus"
        case .unknown:
            "bell.fill"
        }
    }

    private var color: Color {
        switch type {
        case .reaction:
            .pink
        case .reply:
            .blue
        case .mention:
            .purple
        case .follow:
            .green
        case .unknown:
            .secondary
        }
    }

    private var accessibilityLabel: String {
        switch type {
        case .reaction:
            "Reaction"
        case .reply:
            "Reply"
        case .mention:
            "Mention"
        case .follow:
            "Follow"
        case .unknown:
            "Notification"
        }
    }
}

private struct AvatarStrip: View {
    let actors: [NotificationActor]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(Array(actors.prefix(5).enumerated()), id: \.element.id) { index, actor in
                ActorAvatar(actor: actor)
                    .zIndex(Double(5 - index))
            }

            if actors.count > 5 {
                Text("+")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.background, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    }
                    .padding(.leading, 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(avatarAccessibilityLabel)
    }

    private var avatarAccessibilityLabel: String {
        let visibleNames = actors.prefix(5).map { actor in
            actor.username ?? actor.displayName ?? actor.id
        }
        let suffix = actors.count > 5 ? ", and \(actors.count - 5) more" : ""
        return "Actors: \(visibleNames.joined(separator: ", "))\(suffix)"
    }
}

private struct ActorAvatar: View {
    let actor: NotificationActor

    var body: some View {
        Group {
            if let avatarURL = actor.avatarURL {
                AsyncImage(url: avatarURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty, .failure:
                        AvatarFallback(actor: actor)
                    @unknown default:
                        AvatarFallback(actor: actor)
                    }
                }
            } else {
                AvatarFallback(actor: actor)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .background(.background, in: Circle())
        .overlay {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
    }
}

private struct AvatarFallback: View {
    let actor: NotificationActor

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.18))

            Text(initial)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var initial: String {
        let value = actor.username ?? actor.displayName ?? actor.id
        return value.first.map { String($0).uppercased() } ?? "?"
    }
}
