import UIKit

final class ChatActionTapGesture: UITapGestureRecognizer {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(tapped))
    }

    @objc private func tapped() {
        handler()
    }
}

final class ChatLinkTapGesture: UITapGestureRecognizer {
    let link: URL

    init(link: URL) {
        self.link = link
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(open))
    }

    @objc private func open() {
        // Apron links open in the app, never in a browser.
        guard !NotificationRouter.shared.open(link) else { return }
        UIApplication.shared.open(link)
    }
}

/// The composer. Return on a hardware keyboard sends and Shift-Return adds a line; the on-screen keyboard's
/// Return still adds a line. While an input method is composing, Return confirms the composition instead.
final class ChatComposerTextView: UITextView {
    var onReturn: () -> Void = {}
    /// The Return press taken for sending, whose end and cancel are kept from the text view too.
    private var sendPress: UIPress?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.count == 1, let press = presses.first, let key = press.key, markedTextRange == nil,
              key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter,
              key.modifierFlags.isDisjoint(with: [.shift, .alternate, .command, .control])
        else {
            super.pressesBegan(presses, with: event)
            return
        }
        sendPress = press
        onReturn()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forward(presses, with: event, to: super.pressesEnded)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forward(presses, with: event, to: super.pressesCancelled)
    }

    private func forward(_ presses: Set<UIPress>, with event: UIPressesEvent?, to handler: (Set<UIPress>, UIPressesEvent?) -> Void) {
        guard let sendPress, presses.contains(sendPress) else {
            handler(presses, event)
            return
        }
        self.sendPress = nil
        let others = presses.subtracting([sendPress])
        if !others.isEmpty {
            handler(others, event)
        }
    }
}

/// A label whose `.chatLink` runs open on tap and whose `.chatMention` runs show the user. Taps elsewhere
/// pass through, so long-press menus and swipe-to-reply on the bubble still work.
final class ChatLinkLabel: UILabel {
    private enum Target {
        case link(URL)
        case mention(String)
        case spoiler
    }

    var showMention: (String) -> Void = { _ in }
    var openLink: (URL) -> Void = { _ in }
    var revealSpoilers: () -> Void = {}
    private lazy var linkTap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        addGestureRecognizer(linkTap)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// UIKit also asks the touched view about its ancestors' recognizers, such as the list's scroll pan, so
    /// only the link tap is gated; anything else would stop drags that start on text from scrolling.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === linkTap else { return super.gestureRecognizerShouldBegin(gesture) }
        return target(at: gesture.location(in: self)) != nil
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        switch target(at: gesture.location(in: self)) {
        case let .link(url):
            openLink(url)
        case let .mention(userId):
            showMention(userId)
        case .spoiler:
            revealSpoilers()
        case nil:
            break
        }
    }

    /// One bar beside each run of quoted lines. Layers, because UILabel no longer reliably calls `drawText(in:)`.
    private var quoteBars: [CALayer] = []

    override var attributedText: NSAttributedString? {
        didSet {
            setNeedsLayout()
            accessibilityLabel = attributedText.flatMap(Self.spokenText)
        }
    }

    /// Hidden spoilers are read as "spoiler" rather than their text; `nil` when there are none.
    private static func spokenText(_ text: NSAttributedString) -> String? {
        let spoken = NSMutableString(string: text.string)
        var hasSpoiler = false
        text.enumerateAttribute(.chatSpoiler, in: NSRange(location: 0, length: text.length), options: .reverse) { value, range, _ in
            guard value != nil else { return }
            hasSpoiler = true
            spoken.replaceCharacters(in: range, with: "spoiler")
        }
        return hasSpoiler ? spoken as String : nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutQuoteBars()
        layoutSpoilers()
    }

    /// Dotted patches over hidden spoiler text, one per line it spans.
    private var spoilerPatches: [CALayer] = []

    private func layoutSpoilers() {
        var patches: [(CGRect, UIColor)] = []
        if let text = attributedText, text.length > 0 {
            var spoilers: [(NSRange, UIColor)] = []
            text.enumerateAttribute(.chatSpoiler, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if let color = value as? UIColor { spoilers.append((range, color)) }
            }
            if !spoilers.isEmpty, let (storage, layoutManager, container, offset) = layout(in: text) {
                defer { withExtendedLifetime(storage) {} }
                for (range, color) in spoilers {
                    let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                        patches.append((rect.offsetBy(dx: 0, dy: offset).insetBy(dx: -1, dy: 1), color))
                    }
                }
            }
        }
        while spoilerPatches.count < patches.count {
            let patch = CALayer()
            patch.cornerRadius = 4
            patch.masksToBounds = true
            layer.addSublayer(patch)
            spoilerPatches.append(patch)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, patch) in spoilerPatches.enumerated() {
            patch.isHidden = index >= patches.count
            guard index < patches.count else { continue }
            patch.frame = patches[index].0
            patch.backgroundColor = Self.dots(patches[index].1).cgColor
        }
        CATransaction.commit()
    }

    /// A pattern of small dots in `color`, like Telegram's spoiler dust.
    private static func dots(_ color: UIColor) -> UIColor {
        let size = CGSize(width: 5, height: 5)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            color.withAlphaComponent(0.55).setFill()
            UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 1.6, height: 1.6)).fill()
            color.withAlphaComponent(0.3).setFill()
            UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 1.4, height: 1.4)).fill()
        }
        return UIColor(patternImage: image)
    }

    /// Lays the bars out as `target(at:)` lays out the text.
    private func layoutQuoteBars() {
        var rects: [CGRect] = []
        var color: UIColor?
        if let text = attributedText, text.length > 0 {
            var quotes: [NSRange] = []
            text.enumerateAttribute(.chatQuote, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if value != nil { quotes.append(range) }
            }
            if let first = quotes.first, let (storage, layoutManager, _, offset) = layout(in: text) {
                defer { withExtendedLifetime(storage) {} }
                color = text.attribute(.foregroundColor, at: first.location, effectiveRange: nil) as? UIColor
                for quote in quotes {
                    let glyphs = layoutManager.glyphRange(forCharacterRange: quote, actualCharacterRange: nil)
                    var lines = CGRect.null
                    layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, _, _ in
                        lines = lines.union(lineRect)
                    }
                    if !lines.isNull {
                        rects.append(CGRect(x: 0, y: lines.minY + offset, width: 3, height: lines.height).insetBy(dx: 0, dy: 1))
                    }
                }
            }
        }
        while quoteBars.count < rects.count {
            let bar = CALayer()
            bar.cornerRadius = 1.5
            layer.addSublayer(bar)
            quoteBars.append(bar)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in quoteBars.enumerated() {
            bar.isHidden = index >= rects.count
            guard index < rects.count else { continue }
            bar.frame = rects[index]
            bar.backgroundColor = (color ?? textColor).cgColor
        }
        CATransaction.commit()
    }

    /// TextKit at the label's size, and the vertical offset UILabel adds by centering its text. The storage is
    /// returned so the caller keeps it alive; the layout manager holds it weakly.
    private func layout(in text: NSAttributedString) -> (NSTextStorage, NSLayoutManager, NSTextContainer, CGFloat)? {
        guard bounds.width > 0 else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = numberOfLines
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let used = layoutManager.usedRect(for: container)
        return (storage, layoutManager, container, max(0, (bounds.height - used.height) / 2))
    }

    /// Lays the text out with TextKit at the label's size to find the character under the point.
    private func target(at point: CGPoint) -> Target? {
        guard let text = attributedText, text.length > 0, let (storage, layoutManager, container, offset) = layout(in: text) else { return nil }
        defer { withExtendedLifetime(storage) {} }
        let location = CGPoint(x: point.x, y: point.y - offset)
        let glyph = layoutManager.glyphIndex(for: location, in: container)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.insetBy(dx: -6, dy: -4).contains(location) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        if text.attribute(.chatSpoiler, at: index, effectiveRange: nil) != nil {
            return .spoiler
        }
        // A link wins over a mention inside it, such as `https://example.com/@bob`.
        if let url = text.attribute(.chatLink, at: index, effectiveRange: nil) as? URL {
            return .link(url)
        }
        return (text.attribute(.chatMention, at: index, effectiveRange: nil) as? String).map(Target.mention)
    }
}
