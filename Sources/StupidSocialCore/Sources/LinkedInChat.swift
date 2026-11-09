import Foundation

extension LinkedInClient: ChatListProvider {
    public var chatNetwork: ChatNetwork {
        .linkedin
    }

    /// The newest 40 chats of the primary inbox, as LinkedIn's Messaging page lists them; chats filed elsewhere,
    /// such as spam, are left out. LinkedIn's archive isn't read.
    public func chatList() async throws -> ChatListPage {
        let viewerUrn = try await me().profileUrn
        var (conversations, cursor) = try await conversations()
        if let cursor {
            try await conversations += self.conversations(cursor: cursor).conversations
        }
        return ChatListPage(chats: conversations.map { Self.chatSummary($0, viewerUrn: viewerUrn) }, archived: [])
    }

    static func chatSummary(_ conversation: LinkedInConversation, viewerUrn: String) -> ChatSummary {
        let isGroup = conversation.isGroup(viewerUrn: viewerUrn)
        let other = conversation.others(viewerUrn: viewerUrn).first
        var preview: String?
        if let last = conversation.messages?.elements.first {
            if last.sender.hostIdentityUrn == viewerUrn {
                preview = "You: \(last.preview)"
            } else if isGroup, let sender = conversation.conversationParticipants.first(where: { $0.hostIdentityUrn == last.sender.hostIdentityUrn }) {
                preview = "\(sender.name): \(last.preview)"
            } else {
                preview = last.preview
            }
        }
        return ChatSummary(
            id: "linkedin:\(conversation.entityUrn)",
            network: .linkedin,
            title: conversation.displayTitle(viewerUrn: viewerUrn),
            avatarURL: isGroup ? nil : other?.avatarURL,
            avatarColorKey: isGroup ? conversation.entityUrn : other?.hostIdentityUrn,
            preview: preview,
            timestamp: conversation.messages?.elements.first?.deliveredAt ?? conversation.lastActivityDate,
            unreadCount: conversation.unreadCount ?? 0,
            destination: .linkedin(conversationUrn: conversation.entityUrn),
            namesSenderInPreview: isGroup,
            titleNamesPeople: conversation.title?.isEmpty != false,
            isMuted: conversation.notificationStatus == "MUTE",
        )
    }
}
