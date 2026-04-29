import NoFeedSocialCore
import SwiftUI

struct NotificationDetailView: View {
    let displayItem: DisplayNotificationItem

    var body: some View {
        Form {
            Section {
                LabeledContent("Network", value: displayItem.item.network.displayName)
                LabeledContent("Username", value: usernames)
                LabeledContent("Content") {
                    Text(content)
                }
            }
        }
        .navigationTitle("Detail")
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
}
