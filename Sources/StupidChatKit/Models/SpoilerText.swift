import Foundation

/// Spoilers: text hidden until tapped. Ranges are UTF-16, as `NSString` counts and networks' entity offsets do.
public enum SpoilerText {
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
