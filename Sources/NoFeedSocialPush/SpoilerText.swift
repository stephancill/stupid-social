import Foundation

/// Spoilers: text hidden until tapped. Ranges are UTF-16, as Telegram's entity offsets and `NSString` count.
public enum SpoilerText {
    /// Telegram's service account, whose login codes are hidden like spoilers so they don't show at a glance.
    public static let telegramServiceUserId: Int64 = 777_000

    /// The service account's codes carry no entity, so they're found by shape: the token after "code:", such as
    /// "Login code: 12345." or my.telegram.org's "This is your login code: 9y4P-bD6a".
    private static let loginCode = try! NSRegularExpression(pattern: "(?i)code:\\s*([A-Za-z0-9_-]{5,})")

    /// The login codes in a message from Telegram's service account.
    public static func loginCodeRanges(in text: String) -> [NSRange] {
        loginCode.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map { $0.range(at: 1) }
    }

    /// The text with each spoiler replaced by dots, for previews and notifications that can't hide text.
    public static func mask(_ text: String, ranges: [NSRange]) -> String {
        let string = NSMutableString(string: text)
        // Back to front, so a replacement doesn't move the ranges before it.
        for range in ranges.sorted(by: { $0.location > $1.location }) where NSMaxRange(range) <= string.length {
            string.replaceCharacters(in: range, with: String(repeating: "⠿", count: max(3, min(range.length, 8))))
        }
        return string as String
    }
}
