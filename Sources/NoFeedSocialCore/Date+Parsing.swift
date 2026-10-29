import Foundation

extension Date {
    /// Formatters are costly to create and safe to share for parsing, so each is made once.
    private nonisolated(unsafe) static let twitterFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter
    }()

    private nonisolated(unsafe) static let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// X's REST date, such as "Wed Oct 10 20:19:24 +0000 2018".
    static func twitter(_ value: String) -> Date? {
        twitterFormatter.date(from: value)
    }

    /// An ISO 8601 date and time, with or without fractional seconds.
    static func iso8601(_ value: String) -> Date? {
        fractionalISO8601Formatter.date(from: value) ?? iso8601Formatter.date(from: value)
    }
}
