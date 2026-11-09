import Foundation
import StupidChatKit

public extension SpoilerText {
    /// Telegram's service account, whose login codes are hidden like spoilers so they don't show at a glance.
    static let telegramServiceUserId: Int64 = 777_000

    /// The service account's codes carry no entity, so they're found by shape: the token after "code:", such as
    /// "Login code: 12345." or my.telegram.org's "This is your login code: 9y4P-bD6a".
    private static let loginCode = try! NSRegularExpression(pattern: "(?i)code:\\s*([A-Za-z0-9_-]{5,})")

    /// The login codes in a message from Telegram's service account.
    static func loginCodeRanges(in text: String) -> [NSRange] {
        loginCode.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map { $0.range(at: 1) }
    }
}
