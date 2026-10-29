import UIKit

/// Stable per-user accent, like Telegram's name colors. `hashValue` is seeded per launch, so sum the scalars.
public enum ChatUserColor {
    private static let palette: [UIColor] = [.systemRed, .systemOrange, .systemPurple, .systemGreen, .systemTeal, .systemBlue, .systemPink]

    public static func color(for userId: String) -> UIColor {
        palette[userId.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]
    }
}

/// The picture that stands in for a missing photo, in chats and in notifications alike: the first letters of up
/// to two words of the name, in white on the accent color of `colorKey`.
public enum InitialsAvatar {
    public static func initials(of name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// A square PNG, which a notification crops to a circle.
    public static func png(name: String, colorKey: String, size: CGFloat = 120) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(bounds: bounds, format: format).pngData { _ in
            ChatUserColor.color(for: colorKey).setFill()
            UIRectFill(bounds)
            let text = NSAttributedString(string: initials(of: name), attributes: [
                .font: UIFont.systemFont(ofSize: size * 0.39, weight: .semibold),
                .foregroundColor: UIColor.white,
            ])
            let textSize = text.size()
            text.draw(at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2))
        }
    }
}
