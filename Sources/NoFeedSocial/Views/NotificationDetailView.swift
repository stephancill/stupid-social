import NoFeedSocialCore
import SwiftUI

struct NotificationDetailView: View {
    let displayItem: DisplayNotificationItem

    var body: some View {
        Form {
            Section {
                LabeledContent("Network", value: displayItem.item.network.displayName)
                LabeledContent("Content") {
                    if let targetURL {
                        Link(content, destination: targetURL)
                    } else {
                        Text(content)
                    }
                }
            }

            if !displayItem.item.actors.isEmpty {
                Section("People") {
                    ForEach(displayItem.item.actors, id: \.id) { actor in
                        if let url = profileURL(for: actor) {
                            Link(actor.username.map { "@\($0)" } ?? actor.id, destination: url)
                        } else {
                            Text(actor.username.map { "@\($0)" } ?? actor.id)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .navigationTitle(title)
    }

    private var title: String {
        switch displayItem.item.type {
        case .mention: "Mention"
        case .reply: "Reply"
        case .reaction:
            displayItem.item.text.localizedCaseInsensitiveContains("retweet") ? "Retweet" : "Like"
        case .follow: "Follow"
        case .unknown: "Notification"
        }
    }

    private var usernames: String {
        let names = displayItem.item.actors.map { actor in
            actor.username.map { "@\($0)" } ?? actor.id
        }
        return names.isEmpty ? "Unknown" : names.joined(separator: ", ")
    }

    private var content: String {
        displayItem.item.target?.text ?? displayItem.item.text
    }

    private var targetURL: URL? {
        guard let sourceId = displayItem.item.sourceId else { return nil }
        switch displayItem.item.network {
        case .farcaster:
            let hash = sourceId.hasPrefix("0x") ? sourceId : "0x\(sourceId)"
            guard hash.range(of: #"^0x[0-9a-fA-F]+$"#, options: .regularExpression) != nil else {
                return nil
            }
            return URL(string: "https://farcaster.xyz/~/conversations/\(hash)")
        case .x:
            return URL(string: "https://x.com/i/status/\(sourceId)")
        }
    }

    private func profileURL(for actor: NotificationActor) -> URL? {
        guard let username = actor.username else { return nil }
        switch actor.network {
        case .farcaster:
            return URL(string: "https://farcaster.xyz/\(username)")
        case .x:
            return URL(string: "https://x.com/\(username)")
        }
    }
}
