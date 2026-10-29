import NoFeedSocialCore
import UIKit

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

/// Stable per-user accent, like Telegram's name colors. `hashValue` is seeded per launch, so sum the scalars.
enum ChatUserColor {
    private static let palette: [UIColor] = [.systemRed, .systemOrange, .systemPurple, .systemGreen, .systemTeal, .systemBlue, .systemPink]

    static func color(for userId: String) -> UIColor {
        palette[userId.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]
    }
}

/// Telegram-style message: a bubble with the sender's avatar beside the last message of a group,
/// the name atop the first, the time inline at the bottom-right, and system notices as centered captions.
final class ChatMessageCell: UICollectionViewListCell, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    struct Actions {
        var canReply = false
        var canReact = false
        var reply: () -> Void = {}
        var toggleReaction: (String) -> Void = { _ in }
        var showReplyTarget: () -> Void = {}
        /// Who reacted, for a chip's long-press menu.
        var reactionMenu: (String) -> UIMenu? = { _ in nil }
        var showProfile: () -> Void = {}
        /// An uploaded image was tapped: its URL, alt text, and the image if it has loaded.
        var showImage: (URL, String?, UIImage?) -> Void = { _, _, _ in }
        /// Plays `.audio` previews; the chat owns it so only one plays at a time.
        var audioPlayer: ChatAudioPreviewPlayer?
        var previewURL: (String) async -> URL? = { _ in nil }
        var showMentionedUser: (String) -> Void = { _ in }
        var openLink: (URL) -> Void = { _ in }
        var revealSpoilers: () -> Void = {}
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

    private let nameLabel = UILabel()
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
    private let systemLabel = UILabel()
    private let reactionsRow = UIStackView()
    private let reactionsContainer = UIView()
    private let replyIcon = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill"))
    private var imageTasks: [Task<Void, Never>] = []
    private var actions = Actions()
    /// The emoji each chip's long-press menu describes.
    private var chipEmojis: [ObjectIdentifier: (emoji: String, chip: UIView)] = [:]
    private var isOwn = false

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
        bodyLabel.numberOfLines = 0
        embedsStack.axis = .vertical
        // Embeds always span the bubble, which takes its full width when it has any.
        embedsStack.alignment = .fill
        embedsStack.spacing = 6
        timeSpacer.heightAnchor.constraint(equalToConstant: 12).isActive = true

        reactionsRow.spacing = 8
        reactionsRow.translatesAutoresizingMaskIntoConstraints = false
        reactionsContainer.addSubview(reactionsRow)
        NSLayoutConstraint.activate([
            reactionsRow.topAnchor.constraint(equalTo: reactionsContainer.topAnchor, constant: 4),
            reactionsRow.bottomAnchor.constraint(equalTo: reactionsContainer.bottomAnchor),
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
        for (section, views) in [(headerStack, [nameLabel, replyView]), (contentStack, [bodyLabel, embedsStack, reactionsContainer, timeSpacer])] {
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

            timeLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10),
            timeLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -6),
            timeBackground.leadingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -6),
            timeBackground.trailingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 6),
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
        availableWidth: CGFloat,
    ) {
        self.actions = actions
        bodyLabel.showMention = { [weak self] userId in self?.actions.showMentionedUser(userId) }
        bodyLabel.revealSpoilers = { [weak self] in self?.actions.revealSpoilers() }
        bodyLabel.openLink = { [weak self] url in self?.actions.openLink(url) }
        isOwn = layout.isOwn
        imageTasks.forEach { $0.cancel() }
        imageTasks = []
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

        // Incoming messages keep the avatar column so a group's bubbles line up.
        avatarView.isHidden = layout.isOwn || !layout.showsAvatar
        if layout.showsAvatar {
            avatarView.configure(name: DebugRedaction.name(message.sender.name), color: accent, url: avatarURL)
        }

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

        // The clock takes about the width of two digits, so the reserved space covers it.
        let time = (message.isSending ? "00 " : "") + (message.timestamp.map(Self.timeFormatter.string(from:)) ?? "")
        timeLabel.attributedText = Self.timeText(message.timestamp.map(Self.timeFormatter.string(from:)) ?? "", isSending: message.isSending)
        timeLabel.textColor = layout.isOwn ? UIColor.white.withAlphaComponent(0.75) : .secondaryLabel
        timeLabel.accessibilityLabel = message.isSending ? "Sending" : nil

        let text: NSAttributedString? = if message.isDeleted {
            NSAttributedString(string: "Message deleted", attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body).withTraits(.traitItalic),
                .foregroundColor: layout.isOwn ? UIColor.white.withAlphaComponent(0.8) : UIColor.secondaryLabel,
            ])
        } else {
            body
        }
        if let text {
            bodyLabel.isHidden = false
            bodyLabel.attributedText = Self.reservingTimeSpace(in: text, time: time)
        } else {
            bodyLabel.isHidden = true
            bodyLabel.attributedText = nil
        }

        var otherEmbeds = 0
        for embed in embeds {
            if case .image(_, _, _, _, true) = embed {
                mediaStack.addArrangedSubview(makeView(for: embed))
            } else {
                embedsStack.addArrangedSubview(makeView(for: embed))
                otherEmbeds += 1
            }
        }
        embedsStack.isHidden = otherEmbeds == 0
        configureReactions(reactions, canReact: actions.canReact)

        let hasHeader = layout.showsName || reply != nil
        let hasMedia = !mediaStack.arrangedSubviews.isEmpty
        let hasContent = text != nil || otherEmbeds > 0 || !reactions.isEmpty || !hasMedia
        // Without text or reactions the time needs its own line under the embeds; on a lone image it sits on it.
        timeSpacer.isHidden = text != nil || !reactions.isEmpty || !hasContent
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
                replyView.isHidden ? nil : replyView.naturalWidth,
                bodyLabel.attributedText.map { Self.textWidth($0, max: Self.maxContentWidth(availableWidth: availableWidth, isOwn: layout.isOwn)) },
                embedsStack.isHidden ? nil : Self.maxContentWidth(availableWidth: availableWidth, isOwn: layout.isOwn),
                reactionsContainer.isHidden ? nil : reactionsRowWidth + 40,
                timeSpacer.isHidden ? nil : timeLabel.intrinsicContentSize.width,
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
    private func configureReactions(_ reactions: [ChatReaction], canReact: Bool) {
        reactionsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chipEmojis = [:]
        reactionsContainer.isHidden = reactions.isEmpty
        let visible = reactions.prefix(5)
        for reaction in visible {
            var configuration = UIButton.Configuration.filled()
            configuration.cornerStyle = .capsule
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 11)
            var emojiTitle = AttributedString(reaction.emoji)
            emojiTitle.font = UIFont.systemFont(ofSize: 20)
            var count = AttributedString(" \(reaction.count)")
            count.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            count.baselineOffset = 1
            configuration.attributedTitle = emojiTitle + count
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
            chip.accessibilityLabel = "\(reaction.emoji), \(reaction.count)\(reaction.includesYou ? ", including you" : "")"
            chip.isUserInteractionEnabled = canReact
            let emoji = reaction.emoji
            chip.addAction(UIAction { [weak self] _ in self?.actions.toggleReaction(emoji) }, for: .primaryActionTriggered)
            // Long press lists who reacted; it takes precedence over the bubble's own menu.
            let interaction = UIContextMenuInteraction(delegate: self)
            chip.addInteraction(interaction)
            chipEmojis[ObjectIdentifier(interaction)] = (emoji, chip)
            reactionsRow.addArrangedSubview(chip)
        }
        if reactions.count > visible.count {
            let more = UILabel()
            more.text = "+\(reactions.count - visible.count)"
            more.font = .preferredFont(forTextStyle: .footnote)
            more.textColor = isOwn ? .white : .secondaryLabel
            reactionsRow.addArrangedSubview(more)
        }
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
    /// The time, after a clock while the message is sending, as Telegram shows it. The clock is a template
    /// symbol, so it takes the label's color, including white over an image.
    private static func timeText(_ time: String, isSending: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if isSending, let clock = UIImage(systemName: "clock", withConfiguration: UIImage.SymbolConfiguration(font: timeFont, scale: .small)) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: clock)))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: time))
        text.addAttribute(.font, value: timeFont, range: NSRange(location: 0, length: text.length))
        return text
    }

    private static func reservingTimeSpace(in text: NSAttributedString, time: String) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.append(NSAttributedString(string: "   \(time)", attributes: [.font: timeFont, .foregroundColor: UIColor.clear]))
        return result
    }

    private func makeView(for embed: ChatEmbed) -> UIView {
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
                // Uploads fill the bubble, so they get Telegram's larger size. Portrait uploads are sized by
                // height, like Telegram, so they don't squeeze a caption.
                let width: CGFloat = ratio >= 1 ? 264 : max(200, min(264, 340 * ratio))
                NSLayoutConstraint.activate([
                    imageView.widthAnchor.constraint(equalToConstant: width),
                    imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 1 / ratio),
                ])
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
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            return card(leading: spinner, title: "Uploading \(title)…", subtitle: nil, link: nil)
        case let .audio(previewId, title, subtitle, detail, imageURL, link):
            let card = ChatAudioCardView(
                previewId: previewId,
                title: title,
                subtitle: subtitle,
                detail: detail,
                link: link,
                player: actions.audioPlayer ?? ChatAudioPreviewPlayer(),
                resolveURL: actions.previewURL,
            )
            if let imageURL {
                loadImage(imageURL, into: card.artworkView)
            }
            return card
        case let .card(title, subtitle, systemImage, imageURL, link):
            let icon = UIImageView(image: UIImage(systemName: systemImage))
            icon.tintColor = .secondaryLabel
            icon.contentMode = .scaleAspectFit
            icon.setContentHuggingPriority(.required, for: .horizontal)
            // A long title truncates instead; without this it squeezed the symbol to a sliver.
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
            icon.translatesAutoresizingMaskIntoConstraints = false
            if let imageURL {
                // A thumbnail, such as album artwork, replaces the symbol once it loads.
                icon.contentMode = .scaleAspectFill
                icon.clipsToBounds = true
                icon.layer.cornerRadius = 6
                icon.layer.cornerCurve = .continuous
                NSLayoutConstraint.activate([
                    icon.widthAnchor.constraint(equalToConstant: 48),
                    icon.heightAnchor.constraint(equalToConstant: 48),
                ])
                loadImage(imageURL, into: icon)
            } else {
                NSLayoutConstraint.activate([
                    icon.widthAnchor.constraint(equalToConstant: 22),
                    icon.heightAnchor.constraint(equalToConstant: 22),
                ])
            }
            return card(leading: icon, title: title, subtitle: subtitle, link: link)
        }
    }

    private func loadImage(_ url: URL, into imageView: UIImageView) {
        if let cached = StoryImageCache.shared.image(for: url) {
            imageView.image = cached
            return
        }
        imageTasks.append(Task { [weak imageView] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data), !Task.isCancelled
            else { return }
            StoryImageCache.shared.setImage(image, for: url)
            imageView?.image = image
        })
    }

    private func card(leading: UIView, title: String, subtitle: String?, link: URL?) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = link == nil ? .label : .tintColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.isHidden = subtitle == nil
        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [leading, text])
        row.spacing = 10
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        row.backgroundColor = .systemBackground.withAlphaComponent(0.6)
        row.layer.cornerRadius = 12
        row.layer.cornerCurve = .continuous
        row.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        if let link {
            row.addGestureRecognizer(ChatLinkTapGesture(link: link))
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
        initialsLabel.text = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
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

    func configure(name: String, text: String, accent: UIColor, onBubbleColor: Bool) {
        bar.backgroundColor = accent
        backgroundColor = accent.withAlphaComponent(onBubbleColor ? 0.2 : 0.12)
        nameLabel.text = name
        nameLabel.textColor = accent
        textLabel.text = text.replacingOccurrences(of: "\n", with: " ")
        textLabel.textColor = onBubbleColor ? .white : .label
    }
}
