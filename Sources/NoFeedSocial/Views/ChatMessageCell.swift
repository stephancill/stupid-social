import NoFeedSocialCore
import NoFeedSocialPush
import UIKit

/// A day's date in a small glass capsule, heading its messages. Headers pin to the top while their day scrolls
/// past, as in Telegram, and the pinned one fades out once scrolling stops.
final class ChatDateHeaderView: UICollectionReusableView {
    private let glass = ChatGlass.make(cornerRadius: 13)
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(label)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -5),
            label.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -10),
            glass.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            glass.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(day: Date) {
        label.text = Self.title(for: day)
        accessibilityLabel = label.text
    }

    /// "Today", "Yesterday", "October 12", or with the year when it isn't this one, as Telegram does.
    static func title(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if calendar.isDate(day, equalTo: now, toGranularity: .year) {
            return day.formatted(.dateTime.month(.wide).day())
        }
        return day.formatted(.dateTime.month(.wide).day().year())
    }
}

/// The boundary above the first unread message: a hairline either side of a "New Messages" label.
final class ChatUnreadDividerCell: UICollectionViewListCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        let label = UILabel()
        label.text = "New Messages"
        label.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        label.textColor = .systemBlue
        label.setContentHuggingPriority(.required, for: .horizontal)
        let leading = Self.line()
        let trailing = Self.line()
        let row = UIStackView(arrangedSubviews: [leading, label, trailing])
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            leading.widthAnchor.constraint(equalTo: trailing.widthAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "New Messages"
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func line() -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.45)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}

/// Others typing, as the last row: an incoming bubble with three pulsing dots, like Messages. Chats that head
/// bubbles with names say who above it.
final class ChatTypingCell: UICollectionViewListCell {
    private let nameLabel = UILabel()
    private let bubble = UIView()
    private let dots = (0 ..< 3).map { _ in UIView() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        nameLabel.font = .preferredFont(forTextStyle: .footnote)
        nameLabel.textColor = .secondaryLabel
        nameLabel.lineBreakMode = .byTruncatingTail
        bubble.backgroundColor = .secondarySystemBackground
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        let dotRow = UIStackView(arrangedSubviews: dots)
        dotRow.spacing = 5
        dotRow.translatesAutoresizingMaskIntoConstraints = false
        for dot in dots {
            dot.backgroundColor = .secondaryLabel
            dot.layer.cornerRadius = 4
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        }
        bubble.addSubview(dotRow)
        let column = UIStackView(arrangedSubviews: [nameLabel, bubble])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            dotRow.centerXAnchor.constraint(equalTo: bubble.centerXAnchor),
            dotRow.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            bubble.widthAnchor.constraint(equalToConstant: 60),
            bubble.heightAnchor.constraint(equalToConstant: 38),
            // In the incoming bubbles' column, past the avatar.
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 48),
            column.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -40),
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(names: [String], showsNames: Bool) {
        let names = names.map { DebugRedaction.name($0) }
        let who = switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: "\(names[0]) and \(names.count - 1) others"
        }
        nameLabel.text = who
        nameLabel.isHidden = !showsNames || names.isEmpty
        accessibilityLabel = names.count > 1 ? "\(who) are typing" : "\(who) is typing"
    }

    /// Core Animation drops animations when a view leaves the window, so they start again each time it returns.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        for (index, dot) in dots.enumerated() {
            dot.layer.removeAllAnimations()
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.35, 1, 0.35, 0.35]
            let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
            lift.values = [0, -3, 0, 0]
            let pulse = CAAnimationGroup()
            pulse.animations = reduceMotion ? [fade] : [fade, lift]
            for animation in [fade, lift] {
                animation.keyTimes = [0, 0.25, 0.5, 1]
                animation.duration = 1.2
                animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
            }
            pulse.duration = 1.2
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.18
            pulse.fillMode = .backwards
            // Kept through the app going to the background and back.
            pulse.isRemovedOnCompletion = false
            dot.layer.opacity = 0.35
            dot.layer.add(pulse, forKey: "typing")
        }
    }
}

/// What a reply quote shows: the target when loaded, otherwise a loading or unavailable placeholder.
struct ChatReplyQuote: Equatable {
    let name: String
    let text: String
    let accentUserId: String?
}

struct ChatBubbleLayout: Hashable, CustomStringConvertible {
    let isOwn: Bool
    let isSystem: Bool
    let showsName: Bool
    let showsAvatar: Bool
    let startsGroup: Bool

    var description: String {
        [isOwn, isSystem, showsName, showsAvatar, startsGroup].map { $0 ? "1" : "0" }.joined()
    }
}

/// Telegram-style message: a bubble with the sender's avatar beside the last message of a group,
/// the name atop the first, the time inline at the bottom-right, and system notices as centered captions.
/// What a bubble shows of the user's message's progress in a chat with receipts.
enum ChatMessageStatus: Equatable {
    case sending
    case sent
    case seen
}

final class ChatMessageCell: UICollectionViewListCell, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    struct Actions {
        var canReply = false
        var reply: () -> Void = {}
        var toggleReaction: (String) -> Void = { _ in }
        var showReplyTarget: () -> Void = {}
        /// Who reacted, for a chip's long-press menu.
        var reactionMenu: (String) -> UIMenu? = { _ in nil }
        var showProfile: () -> Void = {}
        /// An uploaded image was tapped: its URL, alt text, and the image if it has loaded.
        var showImage: (URL, String?, UIImage?) -> Void = { _, _, _ in }
        /// A video was tapped: it plays full screen.
        var playVideo: (URL) -> Void = { _ in }
        /// A file was tapped: it loads, then opens in Quick Look; the card shows a spinner until this returns.
        var openFile: (URL, String) async -> Void = { _, _ in }
        /// Plays `.audio` previews; the chat owns it so only one plays at a time.
        var audioPlayer: ChatAudioPreviewPlayer?
        var previewURL: (String) async -> URL? = { _ in nil }
        var showMentionedUser: (String) -> Void = { _ in }
        var openLink: (URL) -> Void = { _ in }
        var revealSpoilers: () -> Void = {}
        /// Whether the message embed at an index is open to its full text.
        var isEmbedExpanded: (Int) -> Bool = { _ in false }
        var toggleEmbed: (Int) -> Void = { _ in }
        /// The chat's custom emoji for a reaction key, shown as its image.
        var customEmoji: (String) -> ChatCustomEmoji? = { _ in nil }
        var customEmojiImageDidLoad: () -> Void = {}
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    private static let avatarSize: CGFloat = 34
    private static let timeFont = UIFont.preferredFont(forTextStyle: .caption2)

    private let avatarView = ChatAvatarView()
    private let bubble = UIView()

    /// The bubble alone, for the context menu's targeted preview.
    var bubbleView: UIView {
        bubble
    }

    /// Shrinks the bubble while a press may become a long press, as a context menu does.
    func setPressed(_ pressed: Bool) {
        UIView.animate(withDuration: pressed ? 0.35 : 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.bubble.transform = pressed ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
        }
    }

    /// Whether a long press here lifts the message: on the bubble, not on its reaction chips, which have their own menu.
    func isFocusTarget(at point: CGPoint) -> Bool {
        guard !bubble.isHidden, bubble.frame.contains(point) else { return false }
        return !isOnReactions(at: point)
    }

    /// Whether the point is on the reaction chips, whose own menu lists who reacted.
    func isOnReactions(at point: CGPoint) -> Bool {
        !bubble.isHidden && !reactionsContainer.isHidden && reactionsContainer.convert(reactionsContainer.bounds, to: self).contains(point)
    }

    /// The bubble as drawn, for the focus overlay to lift, with its text and where it sits so it can be selected.
    func focusSnapshot() -> ChatFocusSnapshot {
        // Rendered from the layer tree rather than snapshotted, so a bubble taller than the screen comes out whole.
        // Unlike `drawHierarchy(afterScreenUpdates: true)` it needs no screen update, which stalled the lift, and it
        // ignores the press's shrink.
        let image = UIGraphicsImageRenderer(bounds: bubble.bounds).image { context in
            bubble.layer.render(in: context.cgContext)
        }
        let hasText = !bodyLabel.isHidden && bodyLabel.attributedText != nil
        return ChatFocusSnapshot(
            image: image,
            cornerRadius: bubble.layer.cornerRadius,
            text: hasText ? bodyLabel.attributedText : nil,
            textFrame: bodyLabel.convert(bodyLabel.bounds, to: bubble),
        )
    }

    private let nameLabel = UILabel()
    /// "Due in …" on a message with a reminder.
    private let reminderLabel = UILabel()
    private let replyView = ChatReplyQuoteView()
    private let bodyLabel = ChatLinkLabel()
    private let embedsStack = UIStackView()
    /// Uploaded images, edge to edge at the bubble's top like Telegram, between the header and the caption.
    private let mediaStack = UIStackView()
    private let headerStack = UIStackView()
    private let contentStack = UIStackView()
    /// Behind the time when it sits on an image.
    private let timeBackground = UIView()
    private let timeSpacer = UIView()
    private let timeLabel = UILabel()
    /// After the time in chats with receipts: the clock while sending, then one check, then two, each in place
    /// so the time never moves.
    private let statusSlot = UIView()
    private let slotClock = UIImageView(image: ChatMessageCell.clockImage)
    private let firstCheck = UIImageView(image: ChatMessageCell.checkImage)
    private let secondCheck = UIImageView(image: ChatMessageCell.checkImage)
    /// Before the time while sending in chats without receipts, where nothing follows the time.
    private let leadingClock = UIImageView(image: ChatMessageCell.clockImage)
    private var statusSlotWidth: NSLayoutConstraint!
    private var statusSlotGap: NSLayoutConstraint!
    private var timeBackgroundToLabel: NSLayoutConstraint!
    private var timeBackgroundToClock: NSLayoutConstraint!
    private let systemLabel = UILabel()
    private let reactionsRow = UIStackView()
    private let reactionsContainer = UIView()
    private let replyIcon = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill"))
    private var imageTasks: [Task<Void, Never>] = []
    /// The images this cell shows by URL. A reconfigure rebuilds the image views, and starts them on these so a
    /// photo never blanks while it reloads.
    private var shownImages: [URL: UIImage] = [:]
    private var previousImages: [URL: UIImage] = [:]
    private var actions = Actions()
    /// The emoji each chip's long-press menu describes.
    private var chipEmojis: [ObjectIdentifier: (emoji: String, chip: UIView)] = [:]
    private var isOwn = false
    /// The sender's color, which link and file embeds take on in incoming bubbles, as in Telegram.
    private var accent = UIColor.systemBlue
    /// The row and status last shown, so a reconfigure can animate the change. Keyed by the row rather than the
    /// message, since a sending copy and the network's message have different ids.
    private var shownStatus: (key: String, status: ChatMessageStatus?, leadingClock: Bool)?
    /// The message and reactions last shown, so a reconfigure can tell which chips are new.
    private var shownReactions: (messageId: String, emojis: Set<String>)?
    /// Copies of removed chips while they shrink out.
    private var outgoingChips: [UIView] = []

    // Swipe to reply: a pan drags the bubble left; past the threshold a haptic fires and release replies.
    private static let replyThreshold: CGFloat = 64
    private static let maxSwipe: CGFloat = 110
    private let replyHaptic = UIImpactFeedbackGenerator(style: .medium)
    private var swipeAnimator: UIViewPropertyAnimator?
    private var swipeStartOffset: CGFloat = 0
    private var swipeOffset: CGFloat = 0
    private var isPastReplyThreshold = false

    private var bubbleTop: NSLayoutConstraint!
    private var bubbleWidth: NSLayoutConstraint!
    private var systemTop: NSLayoutConstraint!
    private var incomingConstraints: [NSLayoutConstraint] = []
    private var ownConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()

        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubble)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatarView)

        nameLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        reminderLabel.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        bodyLabel.numberOfLines = 0
        embedsStack.axis = .vertical
        // Embeds always span the bubble, which takes its full width when it has any.
        embedsStack.alignment = .fill
        embedsStack.spacing = 6
        timeSpacer.heightAnchor.constraint(equalToConstant: 12).isActive = true

        reactionsRow.spacing = 8
        reactionsRow.translatesAutoresizingMaskIntoConstraints = false
        reactionsContainer.addSubview(reactionsRow)
        // A reaction is configured at the cell's old height and the cell grows inside an animation. The row keeps
        // its full height while the container is squeezed, so the chips sit at their final size as the bubble grows
        // around them rather than stretching open.
        let rowBottom = reactionsRow.bottomAnchor.constraint(equalTo: reactionsContainer.bottomAnchor)
        rowBottom.priority = .defaultLow
        NSLayoutConstraint.activate([
            reactionsRow.topAnchor.constraint(equalTo: reactionsContainer.topAnchor, constant: 4),
            rowBottom,
            reactionsRow.leadingAnchor.constraint(equalTo: reactionsContainer.leadingAnchor),
            // Leave room for the time, which sits at the bubble's bottom-right.
            reactionsRow.trailingAnchor.constraint(lessThanOrEqualTo: reactionsContainer.trailingAnchor, constant: -40),
        ])
        replyView.isUserInteractionEnabled = true
        replyView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(replyQuoteTapped)))
        avatarView.isUserInteractionEnabled = true
        avatarView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(avatarTapped)))

        // Header (name, quote), media, then content (text, other embeds, reactions); each section sets its own
        // margins in `configure`, so images can run to the bubble's edges while text keeps its padding.
        for (section, views) in [(headerStack, [reminderLabel, nameLabel, replyView]), (contentStack, [bodyLabel, embedsStack, reactionsContainer, timeSpacer])] {
            views.forEach(section.addArrangedSubview)
            section.axis = .vertical
            section.spacing = 4
            section.isLayoutMarginsRelativeArrangement = true
        }
        mediaStack.axis = .vertical
        mediaStack.spacing = 2
        mediaStack.isLayoutMarginsRelativeArrangement = true
        let stack = UIStackView(arrangedSubviews: [headerStack, mediaStack, contentStack])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(stack)

        timeBackground.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        timeBackground.layer.cornerRadius = 9
        timeBackground.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(timeBackground)
        timeLabel.font = Self.timeFont
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(timeLabel)
        statusSlot.translatesAutoresizingMaskIntoConstraints = false
        statusSlot.isUserInteractionEnabled = false
        bubble.addSubview(statusSlot)
        for view in [slotClock, firstCheck, secondCheck] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.alpha = 0
            statusSlot.addSubview(view)
        }
        leadingClock.translatesAutoresizingMaskIntoConstraints = false
        leadingClock.alpha = 0
        bubble.addSubview(leadingClock)

        systemLabel.numberOfLines = 0
        systemLabel.textAlignment = .center
        systemLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(systemLabel)

        replyIcon.tintColor = .white
        replyIcon.contentMode = .center
        replyIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        replyIcon.backgroundColor = UIColor.label.withAlphaComponent(0.25)
        replyIcon.layer.cornerRadius = 16
        replyIcon.clipsToBounds = true
        replyIcon.alpha = 0
        replyIcon.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(replyIcon)
        NSLayoutConstraint.activate([
            replyIcon.widthAnchor.constraint(equalToConstant: 32),
            replyIcon.heightAnchor.constraint(equalToConstant: 32),
            replyIcon.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            replyIcon.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
        ])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        pan.delegate = self
        // A two-finger horizontal scroll on a trackpad, such as on a Mac, swipes too.
        pan.allowedScrollTypesMask = .continuous
        contentView.addGestureRecognizer(pan)

        bubbleTop = bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2)
        systemTop = systemLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10)
        let bubbleBottom = bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        bubbleBottom.priority = .defaultHigh
        // The bubble's width is computed from its content in `configure`; Auto Layout alone kept newly
        // inserted cells at their estimated (maximum) width.
        statusSlotWidth = statusSlot.widthAnchor.constraint(equalToConstant: 0)
        statusSlotGap = statusSlot.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor)
        timeBackgroundToLabel = timeBackground.leadingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -6)
        timeBackgroundToClock = timeBackground.leadingAnchor.constraint(equalTo: leadingClock.leadingAnchor, constant: -6)
        bubbleWidth = bubble.widthAnchor.constraint(equalToConstant: 0)
        bubbleWidth.priority = UILayoutPriority(999)
        bubbleWidth.isActive = true
        NSLayoutConstraint.activate([
            bubbleTop,
            bubbleBottom,
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.8),

            stack.topAnchor.constraint(equalTo: bubble.topAnchor),
            stack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),

            statusSlot.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10),
            statusSlot.topAnchor.constraint(equalTo: timeLabel.topAnchor),
            statusSlot.bottomAnchor.constraint(equalTo: timeLabel.bottomAnchor),
            statusSlotWidth,
            statusSlotGap,
            timeLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -6),
            slotClock.leadingAnchor.constraint(equalTo: statusSlot.leadingAnchor),
            slotClock.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
            firstCheck.leadingAnchor.constraint(equalTo: statusSlot.leadingAnchor),
            firstCheck.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
            secondCheck.leadingAnchor.constraint(equalTo: statusSlot.leadingAnchor, constant: Self.secondCheckOffset),
            secondCheck.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
            leadingClock.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -Self.statusGap),
            leadingClock.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            timeBackgroundToLabel,
            timeBackground.trailingAnchor.constraint(equalTo: statusSlot.trailingAnchor, constant: 6),
            timeBackground.topAnchor.constraint(equalTo: timeLabel.topAnchor, constant: -2),
            timeBackground.bottomAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 2),

            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            avatarView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),

            systemTop,
            systemLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            systemLabel.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.85),
        ])
        incomingConstraints = [
            bubble.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 6),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -40),
        ]
        ownConstraints = [
            bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 60),
        ]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTasks.forEach { $0.cancel() }
        imageTasks = []
        shownImages = [:]
        shownReactions = nil
        shownStatus = nil
        outgoingChips.forEach { $0.removeFromSuperview() }
        outgoingChips = []
        avatarView.reset()
        swipeAnimator?.stopAnimation(true)
        swipeAnimator = nil
        setSwipeOffset(0)
    }

    // MARK: Swipe to reply

    /// Only a leftward, mostly horizontal drag starts a reply, so vertical scrolling and the back swipe still work.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard actions.canReply else { return false }
        let velocity = pan.velocity(in: contentView)
        return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.2
    }

    @objc private func handleSwipe(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            // Interruptible: grabbing the bubble mid-spring continues from where it is.
            if let swipeAnimator, swipeAnimator.state == .active {
                swipeAnimator.stopAnimation(true)
            }
            swipeAnimator = nil
            swipeStartOffset = swipeOffset
            isPastReplyThreshold = swipeOffset <= -Self.replyThreshold
            replyHaptic.prepare()
        case .changed:
            let raw = min(0, swipeStartOffset + pan.translation(in: contentView).x)
            setSwipeOffset(Self.rubberBand(raw))
            let past = swipeOffset <= -Self.replyThreshold
            if past != isPastReplyThreshold {
                isPastReplyThreshold = past
                if past {
                    replyHaptic.impactOccurred()
                }
            }
        case .ended, .cancelled, .failed:
            if pan.state == .ended, isPastReplyThreshold {
                actions.reply()
            }
            isPastReplyThreshold = false
            springBack(velocity: pan.velocity(in: contentView).x)
        default:
            break
        }
    }

    private func springBack(velocity: CGFloat) {
        let distance = swipeOffset
        guard distance != 0 else { return }
        let relative = distance == 0 ? 0 : -velocity / distance
        let timing = UISpringTimingParameters(dampingRatio: 0.82, initialVelocity: CGVector(dx: relative, dy: 0))
        let animator = UIViewPropertyAnimator(duration: 0.45, timingParameters: timing)
        animator.isUserInteractionEnabled = true
        animator.addAnimations { [weak self] in self?.setSwipeOffset(0) }
        animator.startAnimation()
        swipeAnimator = animator
    }

    private func setSwipeOffset(_ offset: CGFloat) {
        swipeOffset = offset
        let transform = CGAffineTransform(translationX: offset, y: 0)
        bubble.transform = transform
        avatarView.transform = transform
        let progress = min(1, -offset / Self.replyThreshold)
        replyIcon.alpha = progress
        let scale = 0.5 + 0.5 * progress
        replyIcon.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    /// Follows the finger up to the threshold, then resists, like Telegram.
    private static func rubberBand(_ raw: CGFloat) -> CGFloat {
        guard raw < -replyThreshold else { return raw }
        let extra = -raw - replyThreshold
        return -min(maxSwipe, replyThreshold + extra * 0.35)
    }

    @objc private func replyQuoteTapped() {
        actions.showReplyTarget()
    }

    @objc private func avatarTapped() {
        actions.showProfile()
    }

    /// Briefly highlights the bubble, after jumping to it from a reply quote.
    func flash() {
        let original = bubble.backgroundColor
        UIView.animate(withDuration: 0.2, animations: {
            self.bubble.backgroundColor = original?.withAlphaComponent(0.55)
        }, completion: { _ in
            UIView.animate(withDuration: 0.4) { self.bubble.backgroundColor = original }
        })
    }

    func configure(
        message: ChatMessage,
        layout: ChatBubbleLayout,
        reply: ChatReplyQuote?,
        avatarURL: URL?,
        body: NSAttributedString?,
        embeds: [ChatEmbed],
        reactions: [ChatReaction],
        actions: Actions,
        status: ChatMessageStatus? = nil,
        statusKey: String? = nil,
        reminderDue: Date? = nil,
        availableWidth: CGFloat,
    ) {
        self.actions = actions
        bodyLabel.showMention = { [weak self] userId in self?.actions.showMentionedUser(userId) }
        bodyLabel.revealSpoilers = { [weak self] in self?.actions.revealSpoilers() }
        bodyLabel.openLink = { [weak self] url in self?.actions.openLink(url) }
        isOwn = layout.isOwn
        imageTasks.forEach { $0.cancel() }
        imageTasks = []
        previousImages = shownImages
        shownImages = [:]
        defer { previousImages = [:] }
        embedsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        mediaStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if layout.isSystem {
            configureSystem(message: message, body: body, startsGroup: layout.startsGroup)
            return
        }
        systemLabel.isHidden = true
        systemTop.isActive = false
        bubble.isHidden = false
        bubbleTop.isActive = true
        bubbleTop.constant = layout.startsGroup ? 8 : 2

        NSLayoutConstraint.deactivate(layout.isOwn ? incomingConstraints : ownConstraints)
        NSLayoutConstraint.activate(layout.isOwn ? ownConstraints : incomingConstraints)
        bubble.backgroundColor = layout.isOwn ? .systemBlue : .secondarySystemBackground
        let accent = ChatUserColor.color(for: message.sender.id)
        self.accent = accent

        // Incoming messages keep the avatar column so a group's bubbles line up.
        avatarView.isHidden = layout.isOwn || !layout.showsAvatar
        if layout.showsAvatar {
            avatarView.configure(name: DebugRedaction.name(message.sender.name), color: accent, url: avatarURL)
        }

        configureReminder(due: reminderDue, isOwn: layout.isOwn)
        nameLabel.isHidden = !layout.showsName
        nameLabel.text = DebugRedaction.name(message.sender.name)
        nameLabel.textColor = accent

        if let reply {
            replyView.isHidden = false
            replyView.configure(
                name: reply.name,
                text: reply.text,
                accent: layout.isOwn ? .white : reply.accentUserId.map(ChatUserColor.color(for:)) ?? .secondaryLabel,
                onBubbleColor: layout.isOwn,
            )
        } else {
            replyView.isHidden = true
        }

        let shownTime = message.timestamp.map(Self.timeFormatter.string(from:)) ?? ""
        timeLabel.text = shownTime
        timeLabel.textColor = layout.isOwn ? UIColor.white.withAlphaComponent(0.75) : .secondaryLabel
        let showsLeadingClock = message.isSending && status == nil
        configureStatus(status, leadingClock: showsLeadingClock, key: statusKey ?? message.id)
        timeLabel.accessibilityLabel = switch status {
        case .sending: "Sending"
        case .sent: "\(shownTime), Sent"
        case .seen: "\(shownTime), Seen"
        case nil: showsLeadingClock ? "Sending" : nil
        }
        // The text keeps room for the time and what sits beside it.
        let timeRowWidth = ceil(timeLabel.intrinsicContentSize.width) + Self.statusWidth(status: status, leadingClock: showsLeadingClock)

        let text: NSAttributedString? = if message.isDeleted {
            NSAttributedString(string: "Message deleted", attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body).withTraits(.traitItalic),
                .foregroundColor: layout.isOwn ? UIColor.white.withAlphaComponent(0.8) : UIColor.secondaryLabel,
            ])
        } else {
            body
        }
        // The time sits beside the text's last line when the text ends the bubble, and on a line of its own after
        // cards and reactions.
        let media = embeds.enumerated().filter { Self.isMedia($0.element) }
        let otherEmbeds = embeds.count - media.count
        let endsWithText = otherEmbeds == 0 && reactions.isEmpty
        if let text {
            bodyLabel.isHidden = false
            bodyLabel.attributedText = endsWithText ? Self.reservingTimeSpace(in: text, width: timeRowWidth) : text
        } else {
            bodyLabel.isHidden = true
            bodyLabel.attributedText = nil
        }

        if media.count > 1 {
            mediaStack.addArrangedSubview(mediaGrid(media))
        } else if let (index, embed) = media.first {
            mediaStack.addArrangedSubview(makeView(for: embed, index: index))
        }
        for (index, embed) in embeds.enumerated() where !Self.isMedia(embed) {
            embedsStack.addArrangedSubview(makeView(for: embed, index: index))
        }
        embedsStack.isHidden = otherEmbeds == 0
        configureReactions(reactions, messageId: message.id)

        let hasHeader = layout.showsName || reply != nil || reminderDue != nil
        let hasMedia = !mediaStack.arrangedSubviews.isEmpty
        let hasContent = text != nil || otherEmbeds > 0 || !reactions.isEmpty || !hasMedia
        // After cards the time needs its own line; reactions leave it room beside them, and on a lone image it sits on it.
        // A lone voice message has room for the time beside its length, as in Telegram.
        let isLoneVoice = text == nil && reactions.isEmpty && embeds.count == 1 && embeds.allSatisfy(Self.fitsContent)
        timeSpacer.isHidden = (text != nil && endsWithText) || !reactions.isEmpty || !hasContent || isLoneVoice
        headerStack.isHidden = !hasHeader
        mediaStack.isHidden = !hasMedia
        contentStack.isHidden = !hasContent
        headerStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: hasMedia ? 6 : hasContent ? 4 : 7, trailing: 12)
        mediaStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: hasHeader ? 0 : 2, leading: 2, bottom: hasContent ? 0 : 2, trailing: 2)
        contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: hasMedia ? 6 : hasHeader ? 0 : 7, leading: 12, bottom: 7, trailing: 12)
        // Images follow the bubble's corners where they touch its edge, and meet text with square corners.
        let images = mediaStack.arrangedSubviews
        for (index, image) in images.enumerated() {
            var corners: CACornerMask = []
            if index == 0, !hasHeader { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
            if index == images.count - 1, !hasContent { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
            image.layer.cornerRadius = 16
            image.layer.maskedCorners = corners
            image.clipsToBounds = true
        }
        // The views above are rebuilt on every configure and start with a zero frame. A reconfigure inside an
        // animation, such as a reaction arriving, would grow them from the corner, so they take their frames first.
        UIView.performWithoutAnimation {
            for stack in [mediaStack, embedsStack, reactionsRow] {
                stack.layoutIfNeeded()
            }
        }
        let timeOnImage = hasMedia && !hasContent
        timeBackground.isHidden = !timeOnImage
        if timeOnImage {
            timeLabel.textColor = .white
        }
        for view in [slotClock, firstCheck, secondCheck, leadingClock] {
            view.tintColor = timeLabel.textColor
        }

        if hasMedia {
            // The images set the width, as in Telegram; a longer name or caption wraps or truncates.
            bubbleWidth.constant = ceil(images.map(Self.fittingWidth).max() ?? 0) + 4
            return
        }
        bubbleWidth.constant = Self.bubbleWidth(
            availableWidth: availableWidth,
            isOwn: layout.isOwn,
            parts: [
                nameLabel.isHidden ? nil : nameLabel.intrinsicContentSize.width,
                reminderLabel.isHidden ? nil : reminderLabel.intrinsicContentSize.width,
                replyView.isHidden ? nil : replyView.naturalWidth,
                bodyLabel.attributedText.map { Self.textWidth($0, max: Self.maxContentWidth(availableWidth: availableWidth, isOwn: layout.isOwn)) },
                embedsStack.isHidden ? nil : embeds.allSatisfy(Self.fitsContent)
                    ? Self.fittingWidth(embedsStack) : Self.maxContentWidth(availableWidth: availableWidth, isOwn: layout.isOwn),
                reactionsContainer.isHidden ? nil : reactionsRowWidth + 40,
                timeSpacer.isHidden ? nil : timeRowWidth,
            ].compactMap(\.self),
        )
    }

    // MARK: Width

    /// The widest a bubble may be: 80% of the row, leaving the avatar column (incoming) or a left gutter (own).
    private static func maxContentWidth(availableWidth: CGFloat, isOwn: Bool) -> CGFloat {
        let gutter: CGFloat = isOwn ? 70 : 8 + avatarSize + 6 + 40
        return min(availableWidth * 0.8, availableWidth - gutter) - 24
    }

    private static func bubbleWidth(availableWidth: CGFloat, isOwn: Bool, parts: [CGFloat]) -> CGFloat {
        let content = min(parts.max() ?? 0, maxContentWidth(availableWidth: availableWidth, isOwn: isOwn))
        return ceil(content) + 24
    }

    private static func textWidth(_ text: NSAttributedString, max: CGFloat) -> CGFloat {
        let bounds = text.boundingRect(
            with: CGSize(width: max, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil,
        )
        return ceil(bounds.width)
    }

    /// The chips' natural single-line widths. A compressed fitting size let a chip's title wrap, so the
    /// bubble could come out narrower than its chips (seen after toggling a reaction).
    private var reactionsRowWidth: CGFloat {
        let views = reactionsRow.arrangedSubviews
        let widths = views.map(\.intrinsicContentSize.width).reduce(0, +)
        return ceil(widths + reactionsRow.spacing * CGFloat(max(0, views.count - 1)))
    }

    private static func fittingWidth(_ view: UIView) -> CGFloat {
        view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
    }

    /// Reaction chips inside the bubble: filled when you reacted, tinted otherwise. Tapping toggles yours (§4.7).
    /// A message with a reminder is outlined, with when it is due above its text.
    private func configureReminder(due: Date?, isOwn: Bool) {
        reminderLabel.isHidden = due == nil
        bubble.layer.borderWidth = due == nil ? 0 : 2
        bubble.layer.borderColor = UIColor.systemOrange.cgColor
        guard let due else { return }
        let color: UIColor = isOwn ? .white : .systemOrange
        let icon = NSTextAttachment(image: UIImage(systemName: "alarm.fill")!.withTintColor(color, renderingMode: .alwaysOriginal))
        let text = NSMutableAttributedString(attachment: icon)
        text.append(NSAttributedString(string: " " + Self.reminderText(due: due)))
        text.addAttributes([.foregroundColor: color, .font: reminderLabel.font!], range: NSRange(location: 0, length: text.length))
        reminderLabel.attributedText = text
    }

    private static let dueFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter
    }()

    static func reminderText(due: Date, now: Date = Date()) -> String {
        let interval = due.timeIntervalSince(now)
        guard interval > 0 else { return "Reminder due" }
        // Rounded up, so a reminder 30 seconds away reads "1 min" rather than nothing.
        return "Due in " + (dueFormatter.string(from: max(60, (interval / 60).rounded(.up) * 60)) ?? "")
    }

    private func configureReactions(_ reactions: [ChatReaction], messageId: String) {
        // Like Telegram, a reaction that arrives on a shown message pops in, one that goes shrinks out, and the
        // rest just move.
        let previous = shownReactions?.messageId == messageId ? shownReactions?.emojis : nil
        let emojis = Set(reactions.map(\.emoji))
        shownReactions = (messageId, emojis)
        if previous != nil {
            for (emoji, chip) in chipEmojis.values where !emojis.contains(emoji) && chip.window != nil {
                popOut(chip)
            }
        }
        reactionsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chipEmojis = [:]
        reactionsContainer.isHidden = reactions.isEmpty
        let visible = reactions.prefix(5)
        for reaction in visible {
            var configuration = UIButton.Configuration.filled()
            configuration.cornerStyle = .capsule
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 11)
            var count = AttributedString(" \(reaction.count)")
            count.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            count.baselineOffset = 1
            let custom = actions.customEmoji(reaction.emoji)
            if let custom {
                // About the height of the 20 pt emoji glyphs in other chips.
                configuration.image = ChatCustomEmojiImages.shared.image(for: custom, height: 22, onLoad: actions.customEmojiImageDidLoad)
                configuration.imagePadding = 0
                configuration.attributedTitle = count
            } else {
                var emojiTitle = AttributedString(reaction.emoji)
                emojiTitle.font = UIFont.systemFont(ofSize: 20)
                configuration.attributedTitle = emojiTitle + count
            }
            // Your reactions are highlighted blue; everyone else's stay neutral. On your own blue bubble,
            // yours invert to white with blue text so they still stand out.
            if reaction.includesYou {
                configuration.baseBackgroundColor = isOwn ? .white : .systemBlue
                configuration.baseForegroundColor = isOwn ? .systemBlue : .white
            } else {
                configuration.baseBackgroundColor = isOwn ? UIColor.white.withAlphaComponent(0.22) : UIColor.label.withAlphaComponent(0.08)
                configuration.baseForegroundColor = isOwn ? .white : .label
            }
            // One line always: the count never wraps under the emoji in a narrow bubble.
            configuration.titleLineBreakMode = .byClipping
            let chip = UIButton(configuration: configuration)
            chip.titleLabel?.numberOfLines = 1
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            chip.accessibilityLabel = "\(custom?.label ?? reaction.emoji), \(reaction.count)\(reaction.includesYou ? ", including you" : "")"
            // Interactive even where you can't react, so a long press or right-click still lists who reacted. A
            // tap asks whether you can react when it happens: cells shown from the snapshot are configured
            // before the chat connects and says it accepts reactions, and aren't configured again for that.
            let emoji = reaction.emoji
            chip.addAction(UIAction { [weak self] _ in self?.actions.toggleReaction(emoji) }, for: .primaryActionTriggered)
            // Long press or right-click lists who reacted; it takes precedence over the bubble's own menu.
            let interaction = UIContextMenuInteraction(delegate: self)
            chip.addInteraction(interaction)
            chipEmojis[ObjectIdentifier(interaction)] = (emoji, chip)
            reactionsRow.addArrangedSubview(chip)
            if let previous, !previous.contains(emoji) {
                Self.popIn(chip.layer)
            }
        }
        if reactions.count > visible.count {
            let more = UILabel()
            more.text = "+\(reactions.count - visible.count)"
            more.font = .preferredFont(forTextStyle: .footnote)
            more.textColor = isOwn ? .white : .secondaryLabel
            reactionsRow.addArrangedSubview(more)
        }
    }

    /// Shrinks a copy of a removed chip where it was, over the bubble, since the chip itself leaves the row now.
    /// The copy is a still image: a `snapshotView` mirrors the chip live, and goes blank once it is removed.
    private func popOut(_ chip: UIView) {
        let image = UIGraphicsImageRenderer(bounds: chip.bounds).image { _ in
            chip.drawHierarchy(in: chip.bounds, afterScreenUpdates: false)
        }
        let copy = UIImageView(image: image)
        copy.frame = chip.convert(chip.bounds, to: bubble)
        bubble.addSubview(copy)
        outgoingChips.append(copy)
        // Layer animations, as in `popIn`: configure runs inside `apply`'s `performWithoutAnimation`, which would
        // finish a UIView animation at once.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            copy.removeFromSuperview()
            self?.outgoingChips.removeAll { $0 === copy }
        }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 0.01
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        for animation in [scale, fade] {
            animation.duration = 0.2
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            copy.layer.add(animation, forKey: animation.keyPath)
        }
        CATransaction.commit()
    }

    private static func popIn(_ layer: CALayer) {
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.01
        scale.toValue = 1
        scale.damping = 18
        scale.initialVelocity = 0
        scale.duration = scale.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        layer.add(scale, forKey: "popIn.scale")
        layer.add(fade, forKey: "popIn.opacity")
    }

    // MARK: Reaction chip menu

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation _: CGPoint) -> UIContextMenuConfiguration? {
        guard let emoji = chipEmojis[ObjectIdentifier(interaction)]?.emoji, let menu = actions.reactionMenu(emoji) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in menu })
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration _: UIContextMenuConfiguration, highlightPreviewForItemWithIdentifier _: NSCopying) -> UITargetedPreview? {
        chipPreview(for: interaction)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration _: UIContextMenuConfiguration, dismissalPreviewForItemWithIdentifier _: NSCopying) -> UITargetedPreview? {
        chipPreview(for: interaction)
    }

    /// Lifts the chip alone, in its capsule shape, like the bubble's long press.
    private func chipPreview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
        guard let chip = chipEmojis[ObjectIdentifier(interaction)]?.chip, chip.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: chip.bounds, cornerRadius: chip.bounds.height / 2)
        return UITargetedPreview(view: chip, parameters: parameters)
    }

    private func configureSystem(message: ChatMessage, body: NSAttributedString?, startsGroup: Bool) {
        bubble.isHidden = true
        avatarView.isHidden = true
        bubbleTop.isActive = false
        NSLayoutConstraint.deactivate(incomingConstraints + ownConstraints)
        systemLabel.isHidden = false
        systemTop.isActive = true
        systemTop.constant = startsGroup ? 10 : 4
        systemLabel.attributedText = body ?? NSAttributedString(string: message.sender.name, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote),
            .foregroundColor: UIColor.secondaryLabel,
        ])
    }

    /// Appends the time again in clear text, so the visible time label sits on the last line when it fits
    /// and the placeholder wraps to its own line when it doesn't, the way Telegram lays out bubbles.
    /// Appends clear space as wide as the time row, so the visible time sits on the last line when it fits and
    /// the space wraps to its own line when it doesn't, the way Telegram lays out bubbles.
    private static func reservingTimeSpace(in text: NSAttributedString, width: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.append(NSAttributedString(string: "   ", attributes: [.font: timeFont]))
        // An attachment without an image draws a placeholder.
        let space = NSTextAttachment(image: clearImage)
        space.bounds = CGRect(x: 0, y: 0, width: width, height: 1)
        result.append(NSAttributedString(attachment: space))
        return result
    }

    private static let clearImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    // MARK: Status

    private static let statusGap: CGFloat = 3
    private static let symbolConfiguration = UIImage.SymbolConfiguration(font: timeFont, scale: .small)
    private static let clockImage = UIImage(systemName: "clock", withConfiguration: symbolConfiguration)?.withRenderingMode(.alwaysTemplate)
    private static let checkImage = UIImage(systemName: "checkmark", withConfiguration: symbolConfiguration)?.withRenderingMode(.alwaysTemplate)
    /// The second check overlaps the first, as Telegram draws two.
    private static let secondCheckOffset = ((checkImage?.size.width ?? 10) * 0.45).rounded()
    /// One width for the clock and both checks, so a message keeps its size as its status changes.
    private static let statusSlotContentWidth = ceil(max((checkImage?.size.width ?? 10) + secondCheckOffset, clockImage?.size.width ?? 10))

    private static func statusWidth(status: ChatMessageStatus?, leadingClock: Bool) -> CGFloat {
        if status != nil { return statusGap + statusSlotContentWidth }
        if leadingClock { return ceil(clockImage?.size.width ?? 10) + statusGap }
        return 0
    }

    /// Shows the status in place. On the same row, a change animates as Telegram's does: the clock fades, a check
    /// pops in beside it, and the second check pops in beside the first. Layer animations, as for reaction chips,
    /// since configure runs inside `apply`'s `performWithoutAnimation`.
    private func configureStatus(_ status: ChatMessageStatus?, leadingClock showsLeadingClock: Bool, key: String) {
        let previous = shownStatus?.key == key ? shownStatus : nil
        shownStatus = (key, status, showsLeadingClock)

        statusSlotWidth.constant = status == nil ? 0 : Self.statusSlotContentWidth
        statusSlotGap.constant = status == nil ? 0 : Self.statusGap
        timeBackgroundToLabel.isActive = !showsLeadingClock
        timeBackgroundToClock.isActive = showsLeadingClock

        let animates = previous != nil && window != nil
        setVisible(slotClock, status == .sending, animated: animates)
        setVisible(firstCheck, status == .sent || status == .seen, animated: animates)
        setVisible(secondCheck, status == .seen, animated: animates)
        setVisible(leadingClock, showsLeadingClock, animated: animates)

        // A row that stops showing a status, such as a message to yourself, slides its time into the space.
        if animates, let previous, previous.status != nil, status == nil {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = -Self.statusWidth(status: previous.status, leadingClock: false)
            slide.toValue = 0
            slide.duration = 0.25
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for layer in [timeLabel.layer, statusSlot.layer] {
                layer.add(slide, forKey: "status.slide")
            }
        }
    }

    private func setVisible(_ view: UIView, _ visible: Bool, animated: Bool) {
        let wasVisible = view.alpha > 0
        view.alpha = visible ? 1 : 0
        guard animated, visible != wasVisible else { return }
        if visible {
            Self.popIn(view.layer)
        } else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.2
            view.layer.add(fade, forKey: "status.fade")
        }
    }

    private func makeView(for embed: ChatEmbed, index: Int) -> UIView {
        switch embed {
        case let .image(url, aspectRatio, alt, link, opensViewer):
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 12
            imageView.layer.cornerCurve = .continuous
            imageView.backgroundColor = .secondarySystemFill
            imageView.accessibilityLabel = alt
            imageView.isAccessibilityElement = alt != nil
            // Sizing from the server's `og` dimensions keeps the cell height stable while the image loads.
            let ratio = CGFloat(min(max(aspectRatio ?? 4 / 3, 0.5), 2))
            if opensViewer {
                Self.sizeAsMedia(imageView, aspectRatio: aspectRatio)
            } else {
                // A preview spans the bubble; a tall one is cropped so it doesn't take over the screen.
                imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 1 / max(ratio, 0.75)).isActive = true
            }
            loadImage(url, into: imageView)
            if opensViewer {
                imageView.isUserInteractionEnabled = true
                imageView.addGestureRecognizer(ChatActionTapGesture { [weak self, weak imageView] in
                    self?.actions.showImage(url, alt, imageView?.image)
                })
            } else if let link {
                imageView.isUserInteractionEnabled = true
                imageView.addGestureRecognizer(ChatLinkTapGesture(link: link))
            }
            return imageView
        case let .pending(title):
            let row = fileRow(filename: title, subtitle: "Uploading…", thumbnailURL: nil)
            row.isLoading = true
            return row
        case let .audio(previewId, title, subtitle, detail, imageURL, link):
            let card = ChatAudioCardView(
                previewId: previewId,
                title: title,
                subtitle: subtitle,
                detail: detail,
                link: link,
                hasArtwork: imageURL != nil,
                isOwn: isOwn,
                player: actions.audioPlayer ?? ChatAudioPreviewPlayer(),
                resolveURL: actions.previewURL,
            )
            if let imageURL {
                loadImage(imageURL, into: card.artworkView)
            }
            return card
        case let .voice(previewId, duration, waveform):
            return ChatVoiceView(
                previewId: previewId,
                duration: duration,
                waveform: waveform,
                isOwn: isOwn,
                player: actions.audioPlayer ?? ChatAudioPreviewPlayer(),
                resolveURL: actions.previewURL,
            )
        case let .card(title, subtitle, systemImage, imageURL, link):
            return linkCard(title: title, subtitle: subtitle, systemImage: systemImage, imageURL: imageURL, link: link)
        case let .message(title, text, link):
            return messageCard(title: title, text: text, link: link, index: index)
        case let .video(url, posterURL, aspectRatio, duration, isGIF):
            let video = ChatVideoView(url: url, duration: duration, isGIF: isGIF)
            Self.sizeAsMedia(video, aspectRatio: aspectRatio)
            if let posterURL {
                loadImage(posterURL, into: video.posterView)
            }
            video.addGestureRecognizer(ChatActionTapGesture { [weak self] in self?.actions.playVideo(url) })
            return video
        case let .file(url, filename, subtitle, thumbnailURL):
            let row = fileRow(filename: filename, subtitle: subtitle, thumbnailURL: thumbnailURL)
            row.accessibilityTraits = .button
            row.addGestureRecognizer(ChatActionTapGesture { [weak self, weak row] in
                guard let self, let row, !row.isLoading else { return }
                row.isLoading = true
                Task {
                    await self.actions.openFile(url, filename)
                    row.isLoading = false
                }
            })
            return row
        }
    }

    /// Embeds as wide as their content, such as a voice message; with only these, the bubble fits them rather than
    /// taking the widest a bubble may be.
    private static func fitsContent(_ embed: ChatEmbed) -> Bool {
        if case .voice = embed { true } else { false }
    }

    /// Photos and videos fill the bubble's media area; other embeds sit under the text.
    private static func isMedia(_ embed: ChatEmbed) -> Bool {
        switch embed {
        case .image(_, _, _, _, true), .video: true
        default: false
        }
    }

    /// Media that fills the bubble gets Telegram's larger size. Portrait media is sized by height, like Telegram, so
    /// it doesn't squeeze a caption.
    private static func sizeAsMedia(_ view: UIView, aspectRatio: Double?) {
        let ratio = CGFloat(min(max(aspectRatio ?? 4 / 3, 0.5), 2))
        let width: CGFloat = ratio >= 1 ? 264 : max(200, min(264, 340 * ratio))
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            view.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 1 / ratio),
        ])
    }

    /// An album: an odd one out on a row of its own first, then pairs of square tiles, 2 points apart.
    private func mediaGrid(_ media: [(offset: Int, element: ChatEmbed)]) -> UIView {
        let width: CGFloat = 264
        let spacing: CGFloat = 2
        var rows: [[(offset: Int, element: ChatEmbed)]] = []
        var rest = media[...]
        if media.count % 2 == 1, let first = rest.popFirst() {
            rows.append([first])
        }
        while !rest.isEmpty {
            rows.append(Array(rest.prefix(2)))
            rest = rest.dropFirst(2)
        }
        let grid = UIStackView(arrangedSubviews: rows.map { row in
            let tiles = row.map { item in
                let tile = makeView(for: item.element, index: item.offset)
                // The tile's own size gives way to the grid's.
                tile.constraints.filter { $0.firstItem === tile && [.width, .height].contains($0.firstAttribute) }.forEach { $0.isActive = false }
                // Only the grid's outer corners are rounded.
                tile.layer.cornerRadius = 0
                return tile
            }
            let stack = UIStackView(arrangedSubviews: tiles)
            stack.axis = .horizontal
            stack.spacing = spacing
            stack.distribution = .fillEqually
            let height = row.count == 1 ? width / Self.tileRatio(row[0].element) : (width - spacing) / 2
            stack.heightAnchor.constraint(equalToConstant: height).isActive = true
            return stack
        })
        grid.axis = .vertical
        grid.spacing = spacing
        grid.clipsToBounds = true
        grid.widthAnchor.constraint(equalToConstant: width).isActive = true
        return grid
    }

    private static func tileRatio(_ embed: ChatEmbed) -> CGFloat {
        let ratio: Double? = switch embed {
        case let .image(_, aspectRatio, _, _, _): aspectRatio
        case let .video(_, _, aspectRatio, _, _): aspectRatio
        default: nil
        }
        return CGFloat(min(max(ratio ?? 4 / 3, 1), 2))
    }

    /// A message from elsewhere, drawn like a reply quote: who sent it where, then its text, three lines until
    /// tapped open. The name opens the message.
    private func messageCard(title: String, text: String, link: URL?, index: Int) -> UIView {
        let isExpanded = actions.isEmbedExpanded(index)
        let quote = ChatReplyQuoteView()
        quote.configure(
            name: DebugRedaction.name(title),
            text: text,
            accent: isOwn ? .white : ChatUserColor.color(for: title),
            onBubbleColor: isOwn,
            lines: isExpanded ? 0 : 3,
        )
        quote.onTaps(
            name: link.map(ChatLinkTapGesture.init(link:)),
            text: ChatActionTapGesture { [weak self] in self?.actions.toggleEmbed(index) },
        )
        quote.accessibilityHint = isExpanded ? "Shows less" : "Shows the whole message"
        return quote
    }

    private func loadImage(_ url: URL, into imageView: UIImageView) {
        if let shown = previousImages[url] ?? ChatMediaImageCache.shared.image(for: url) {
            imageView.image = shown
            shownImages[url] = shown
            return
        }
        imageTasks.append(Task { [weak self, weak imageView] in
            guard let image = await ChatMediaImageCache.shared.load(url), !Task.isCancelled else { return }
            imageView?.image = image
            self?.shownImages[url] = image
        })
    }

    /// A link preview or shared item, like Telegram's: a bar in the accent beside the site (or a symbol saying
    /// what it is), a bold title and a few lines of description, with a thumbnail at the trailing edge, on a faint
    /// wash of the accent. Tapping it opens the link.
    private func linkCard(title: String, subtitle: String?, systemImage: String, imageURL: URL?, link: URL?) -> UIView {
        let color = isOwn ? UIColor.white : accent
        let site = link.flatMap { $0.host() }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        let symbol = UIImageView(image: UIImage(systemName: systemImage, withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)))
        symbol.tintColor = color
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        symbol.setContentCompressionResistancePriority(.required, for: .horizontal)
        let siteLabel = UILabel()
        siteLabel.text = site
        siteLabel.font = UIFont.preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        siteLabel.textColor = color
        siteLabel.isHidden = site == nil
        let header = UIStackView(arrangedSubviews: [symbol, siteLabel])
        header.spacing = 4
        header.alignment = .center

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.textColor = isOwn ? .white : .label
        titleLabel.numberOfLines = 2
        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = isOwn ? UIColor.white.withAlphaComponent(0.85) : .secondaryLabel
        subtitleLabel.numberOfLines = 3
        subtitleLabel.isHidden = subtitle == nil
        let text = UIStackView(arrangedSubviews: [header, titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 2
        text.alignment = .leading
        text.isLayoutMarginsRelativeArrangement = true
        text.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)

        let bar = UIView()
        bar.backgroundColor = color
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
        let row = UIStackView(arrangedSubviews: [bar, text])
        row.spacing = 8
        row.alignment = .fill
        if let imageURL {
            let thumbnail = UIImageView()
            thumbnail.contentMode = .scaleAspectFill
            thumbnail.clipsToBounds = true
            thumbnail.layer.cornerRadius = 6
            thumbnail.layer.cornerCurve = .continuous
            thumbnail.backgroundColor = color.withAlphaComponent(0.15)
            thumbnail.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                thumbnail.widthAnchor.constraint(equalToConstant: 56),
                thumbnail.heightAnchor.constraint(equalToConstant: 56),
            ])
            loadImage(imageURL, into: thumbnail)
            // Top-aligned beside the text, which may run longer.
            let column = UIStackView(arrangedSubviews: [thumbnail, UIView()])
            column.axis = .vertical
            column.isLayoutMarginsRelativeArrangement = true
            column.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
            // A stack has no intrinsic width, so without this the row may widen the column and squeeze the text.
            column.translatesAutoresizingMaskIntoConstraints = false
            column.widthAnchor.constraint(equalToConstant: 56).isActive = true
            row.addArrangedSubview(column)
        }
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8)
        row.backgroundColor = color.withAlphaComponent(isOwn ? 0.18 : 0.1)
        row.layer.cornerRadius = 6
        row.layer.cornerCurve = .continuous
        row.clipsToBounds = true
        row.isAccessibilityElement = true
        row.accessibilityLabel = [site, title, subtitle].compactMap(\.self).joined(separator: ", ")
        if let link {
            row.accessibilityTraits = .link
            row.addGestureRecognizer(ChatLinkTapGesture(link: link))
        }
        return row
    }

    /// A file, like Telegram's and WhatsApp's: a tile in the type's color with its extension (or its thumbnail),
    /// then the name and the size. The tile shows a spinner while the file loads.
    private func fileRow(filename: String, subtitle: String?, thumbnailURL: URL?) -> ChatFileRow {
        let row = ChatFileRow(filename: filename, subtitle: subtitle, isOwn: isOwn)
        if let thumbnailURL {
            row.showsThumbnail()
            loadImage(thumbnailURL, into: row.tile)
        }
        return row
    }
}

/// Circular avatar that falls back to initials on the user's accent color (§4.8.6).
final class ChatAvatarView: UIView {
    private let imageView = UIImageView()
    private let initialsLabel = UILabel()
    private var task: Task<Void, Never>?
    private var url: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        initialsLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        initialsLabel.textColor = .white
        initialsLabel.textAlignment = .center
        imageView.contentMode = .scaleAspectFill
        for view in [initialsLabel, imageView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
    }

    func reset() {
        task?.cancel()
        task = nil
        url = nil
        imageView.image = nil
    }

    func configure(name: String, color: UIColor, url: URL?) {
        backgroundColor = color
        initialsLabel.text = InitialsAvatar.initials(of: name)
        guard url != self.url else { return }
        reset()
        self.url = url
        guard let url else { return }
        if let cached = StoryImageCache.shared.image(for: url) {
            imageView.image = cached
            return
        }
        task = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data), !Task.isCancelled
            else { return }
            StoryImageCache.shared.setImage(image, for: url)
            if self?.url == url {
                self?.imageView.image = image
            }
        }
    }
}

/// The quoted message inside a reply bubble: an accent bar, the author, and one line of text.
final class ChatReplyQuoteView: UIView {
    private let bar = UIView()
    private let nameLabel = UILabel()
    private let textLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        clipsToBounds = true
        nameLabel.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        textLabel.font = .preferredFont(forTextStyle: .footnote)
        let labels = UIStackView(arrangedSubviews: [nameLabel, textLabel])
        labels.axis = .vertical
        labels.spacing = 1
        for view in [bar, labels] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 3),
            labels.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// One line of the quote, plus the bar and padding; the bubble caps it at its maximum width.
    var naturalWidth: CGFloat {
        max(nameLabel.intrinsicContentSize.width, textLabel.intrinsicContentSize.width) + 3 + 8 + 8
    }

    /// `lines` above one keeps the text's line breaks, as for a linked message; `0` shows all of it.
    func configure(name: String, text: String, accent: UIColor, onBubbleColor: Bool, lines: Int = 1) {
        bar.backgroundColor = accent
        backgroundColor = accent.withAlphaComponent(onBubbleColor ? 0.2 : 0.12)
        nameLabel.text = name
        nameLabel.textColor = accent
        textLabel.text = lines == 1 ? text.replacingOccurrences(of: "\n", with: " ") : text
        textLabel.numberOfLines = lines
        textLabel.textColor = onBubbleColor ? .white : .label
    }

    /// Separate taps on the name and the text, such as opening a linked message and showing all of it.
    func onTaps(name: UIGestureRecognizer?, text: UIGestureRecognizer) {
        for (label, gesture) in [(nameLabel, name), (textLabel, text)] {
            guard let gesture else { continue }
            label.isUserInteractionEnabled = true
            label.addGestureRecognizer(gesture)
        }
    }
}

/// Photos, artwork and card icons shown in chat bubbles, decoded once off the main thread. Kept apart from
/// `StoryImageCache`, whose few entries the chat's avatars would evict, blanking photos on every reconfigure.
@MainActor
final class ChatMediaImageCache {
    static let shared = ChatMediaImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    /// Loads outlive the cell that asked: a reconfigure mid-load picks up the same load instead of restarting it.
    private var loading: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        cache.totalCostLimit = 150 * 1024 * 1024
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async -> UIImage? {
        if let image = image(for: url) { return image }
        if let task = loading[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            let data = try? await URLSession.shared.data(from: url).0
            let image = await Task.detached { data.flatMap(UIImage.init(data:))?.preparingForDisplay() }.value
            if let image {
                let pixels = image.size.width * image.scale * image.size.height * image.scale
                cache.setObject(image, forKey: url as NSURL, cost: Int(pixels) * 4)
            }
            loading[url] = nil
            return image
        }
        loading[url] = task
        return await task.value
    }
}
