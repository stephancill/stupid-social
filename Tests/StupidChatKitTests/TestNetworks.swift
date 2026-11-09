import StupidChatKit

/// Networks the tests name, as an app would declare its own.
extension ChatNetwork {
    static let apron = ChatNetwork(rawValue: "apron")
    static let telegram = ChatNetwork(rawValue: "telegram")
    static let spotify = ChatNetwork(rawValue: "spotify")
    static let x = ChatNetwork(rawValue: "x")
    static let discord = ChatNetwork(rawValue: "discord")
}
