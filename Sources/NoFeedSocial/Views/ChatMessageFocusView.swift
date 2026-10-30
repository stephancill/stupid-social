import SwiftUI
import UIKit

/// A message's long-press menu: quick reactions, then actions. Shown as a context menu, or by
/// `ChatMessageFocusController` for a message too tall to lift whole.
@MainActor
struct ChatMessageMenu {
    struct Action {
        var title: String
        var image: UIImage?
        var isOn = false
        var handler: @MainActor () -> Void
    }

    enum Item {
        case action(Action)
        case submenu(title: String, image: UIImage?, children: [Action])
    }

    /// Emoji, ending in More Reactions.
    var reactions: [Action] = []
    var items: [Item] = []

    var isEmpty: Bool {
        reactions.isEmpty && items.isEmpty
    }

    var uiMenu: UIMenu {
        var children: [UIMenuElement] = []
        if !reactions.isEmpty {
            // In a row of small elements an action shows its image alone; the title stays for VoiceOver.
            children.append(UIMenu(options: .displayInline, preferredElementSize: .small, children: reactions.map(Self.uiAction)))
        }
        children.append(UIMenu(options: .displayInline, children: items.map { item in
            switch item {
            case let .action(action): Self.uiAction(action)
            case let .submenu(title, image, actions): UIMenu(title: title, image: image, children: actions.map(Self.uiAction))
            }
        }))
        return UIMenu(children: children)
    }

    private static func uiAction(_ action: Action) -> UIAction {
        UIAction(title: action.title, image: action.image, state: action.isOn ? .on : .off) { _ in action.handler() }
    }
}

/// A message's bubble as drawn, for `ChatMessageFocusController` to lift.
struct ChatFocusSnapshot {
    let image: UIImage
    let cornerRadius: CGFloat
    /// The text as laid out in the bubble, selectable over the image; `nil` when the message has none.
    let text: NSAttributedString?
    /// Where the text sits in the bubble.
    let textFrame: CGRect
}

/// A message lifted out of the chat on long press, in place of a context menu, whose preview takes no touches and
/// so can't scroll or select. The bubble rises from where it was over the blurred chat, with the reactions above it
/// and the actions below; one taller than the space between them runs past the screen's edges and scrolls, the
/// panels then staying at the top and bottom over it. The text is selectable. Closing puts the bubble back.
final class ChatMessageFocusController: UIViewController, UITextViewDelegate {
    private let snapshot: ChatFocusSnapshot
    /// The bubble's frame in the window when the press lifted it.
    private let sourceFrame: CGRect
    /// Where the bubble is in the window now, to settle back to; `nil` when it scrolled away.
    private let currentSourceFrame: () -> CGRect?
    private let isOwn: Bool
    private let menu: ChatMessageMenu
    private let openLink: (URL) -> Void
    /// The lifted bubble is on screen, so the chat can hide its own without a frame showing neither.
    private let didLift: () -> Void
    private let didClose: () -> Void

    private let blur = UIVisualEffectView(effect: nil)
    private let scrollView = UIScrollView()
    private let lifted = UIView()
    private let textView = UITextView()
    private var reactions: UIView?
    private var actions: UIView?
    private var hasLaidOut = false
    private var isClosing = false

    private static let gap: CGFloat = 8
    /// The press shrinks the bubble to this, so the lift starts from it.
    private static let pressedScale: CGFloat = 0.96

    init(snapshot: ChatFocusSnapshot, sourceFrame: CGRect, currentSourceFrame: @escaping () -> CGRect?, isOwn: Bool, menu: ChatMessageMenu, openLink: @escaping (URL) -> Void, didLift: @escaping () -> Void, didClose: @escaping () -> Void) {
        self.snapshot = snapshot
        self.sourceFrame = sourceFrame
        self.currentSourceFrame = currentSourceFrame
        self.isOwn = isOwn
        self.menu = menu
        self.openLink = openLink
        self.didLift = didLift
        self.didClose = didClose
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        blur.frame = view.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(blur)

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapOutside))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)
        view.addSubview(scrollView)

        let image = UIImageView(image: snapshot.image)
        image.frame = CGRect(origin: .zero, size: sourceFrame.size)
        image.layer.cornerRadius = snapshot.cornerRadius
        image.layer.cornerCurve = .continuous
        image.clipsToBounds = true
        lifted.addSubview(image)
        lifted.layer.cornerRadius = snapshot.cornerRadius
        lifted.layer.cornerCurve = .continuous
        lifted.layer.shadowColor = UIColor.black.cgColor
        lifted.layer.shadowOpacity = 0.12
        lifted.layer.shadowRadius = 16
        lifted.layer.shadowOffset = CGSize(width: 0, height: 6)
        lifted.layer.shadowPath = UIBezierPath(roundedRect: image.frame, cornerRadius: snapshot.cornerRadius).cgPath
        if let text = snapshot.text {
            // Laid out as the bubble's label lays it out, but invisible: the image shows the text, this selects it.
            textView.attributedText = Self.invisible(text)
            textView.isEditable = false
            textView.isScrollEnabled = false
            textView.backgroundColor = .clear
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            textView.linkTextAttributes = [:]
            textView.delegate = self
            textView.frame = snapshot.textFrame
            // Set after the frame: the container keeps the size it had, which cut off the last lines.
            textView.textContainer.size = CGSize(width: snapshot.textFrame.width, height: .greatestFiniteMagnitude)
            lifted.addSubview(textView)
        }
        scrollView.addSubview(lifted)

        if !menu.reactions.isEmpty {
            reactions = reactionsRow()
        }
        if !menu.items.isEmpty {
            actions = actionsPanel()
        }
        for panel in [reactions, actions].compactMap(\.self) {
            panel.frame.size = panel.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            view.addSubview(panel)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !hasLaidOut, view.bounds.width > 0 else { return }
        hasLaidOut = true
        layOut()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didLift()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UIViewPropertyAnimator(duration: 0.5, dampingRatio: 0.78) { [self] in
            blur.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            lifted.transform = .identity
            for panel in [reactions, actions].compactMap(\.self) {
                panel.alpha = 1
                panel.transform = .identity
            }
        }.startAnimation()
    }

    /// Keeps the bubble where it was when it fits between the panels, moving it only as far as they need, as a
    /// context menu moves its preview. Then sets everything back to where the press left it, for the lift to animate.
    private func layOut() {
        let safe = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 0, dy: 8)
        let height = sourceFrame.height
        let above = reactions.map { $0.frame.height + Self.gap } ?? 0
        let below = actions.map { $0.frame.height + Self.gap } ?? 0
        let top = safe.minY + above
        let bottom = safe.maxY - below

        lifted.frame = CGRect(x: sourceFrame.minX, y: 0, width: sourceFrame.width, height: height)
        scrollView.contentSize = CGSize(width: view.bounds.width, height: height)
        let liftedY: CGFloat
        if height <= bottom - top {
            liftedY = min(max(sourceFrame.minY, top), bottom - height)
            scrollView.contentInset = UIEdgeInsets(top: liftedY, left: 0, bottom: view.bounds.height - liftedY - height, right: 0)
            scrollView.contentOffset = CGPoint(x: 0, y: -liftedY)
            reactions?.frame.origin.y = liftedY - Self.gap - (reactions?.frame.height ?? 0)
            actions?.frame.origin.y = liftedY + height + Self.gap
        } else {
            scrollView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: view.bounds.height - bottom, right: 0)
            scrollView.alwaysBounceVertical = true
            // The part of the message that was on screen stays there; the rest is a scroll away.
            let offset = min(max(-sourceFrame.minY, -top), height - bottom)
            scrollView.contentOffset = CGPoint(x: 0, y: offset)
            liftedY = -offset
            reactions?.frame.origin.y = safe.minY
            actions?.frame.origin.y = safe.maxY - (actions?.frame.height ?? 0)
        }
        for panel in [reactions, actions].compactMap(\.self) {
            panel.frame.origin.x = isOwn
                ? min(sourceFrame.maxX, safe.maxX - 12) - panel.frame.width
                : max(sourceFrame.minX, safe.minX + 12)
        }

        lifted.transform = CGAffineTransform(translationX: 0, y: sourceFrame.minY - liftedY).scaledBy(x: Self.pressedScale, y: Self.pressedScale)
        for (panel, isAbove) in [(reactions, true), (actions, false)] {
            guard let panel else { continue }
            panel.alpha = 0
            panel.transform = Self.collapsed(panel, towards: isAbove ? .bottom : .top, isOwn: isOwn)
        }
    }

    /// A panel shrunk towards the corner nearest the bubble, so it grows out of it.
    private static func collapsed(_ panel: UIView, towards edge: UIRectEdge, isOwn: Bool) -> CGAffineTransform {
        let scale: CGFloat = 0.4
        let dx = (isOwn ? 1 : -1) * panel.frame.width * (1 - scale) / 2
        let dy = (edge == .bottom ? 1 : -1) * panel.frame.height * (1 - scale) / 2
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    }

    /// Settles the bubble back into the chat, then runs `completion`, so what an action presents comes from the chat.
    private func close(then completion: (() -> Void)? = nil) {
        guard !isClosing else { return }
        isClosing = true
        textView.selectedTextRange = nil
        let current = lifted.superview?.convert(lifted.frame, to: view) ?? .zero
        let target = currentSourceFrame()
        let animator = UIViewPropertyAnimator(duration: 0.4, dampingRatio: 0.9) { [self] in
            blur.effect = nil
            for (panel, isAbove) in [(reactions, true), (actions, false)] {
                guard let panel else { continue }
                panel.alpha = 0
                panel.transform = Self.collapsed(panel, towards: isAbove ? .bottom : .top, isOwn: isOwn)
            }
            if let target {
                lifted.transform = CGAffineTransform(translationX: target.minX - current.minX, y: target.minY - current.minY)
                lifted.layer.shadowOpacity = 0
            } else {
                lifted.alpha = 0
            }
        }
        animator.addCompletion { [self] _ in
            didClose()
            dismiss(animated: false, completion: completion)
        }
        animator.startAnimation()
    }

    /// Taps beside the message close it; taps on it are the text's.
    @objc private func tapOutside(_ gesture: UITapGestureRecognizer) {
        guard !lifted.frame.contains(gesture.location(in: scrollView)) else { return }
        close()
    }

    private func perform(_ action: ChatMessageMenu.Action) {
        close { action.handler() }
    }

    /// The text clear, with custom emoji images blanked but kept at their size, so it lays out as shown and draws nothing.
    private static func invisible(_ text: NSAttributedString) -> NSAttributedString {
        let clear = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: clear.length)
        clear.addAttribute(.foregroundColor, value: UIColor.clear, range: range)
        clear.enumerateAttribute(.attachment, in: range) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let blank = NSTextAttachment()
            blank.image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
            blank.bounds = attachment.bounds
            clear.addAttribute(.attachment, value: blank, range: range)
        }
        return clear
    }

    private func reactionsRow() -> UIView {
        let row = UIStackView(arrangedSubviews: menu.reactions.map { reaction in
            var configuration = UIButton.Configuration.plain()
            if let image = reaction.image {
                configuration.image = image
            } else {
                configuration.title = reaction.title
                configuration.attributedTitle = AttributedString(reaction.title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 26)]))
            }
            configuration.baseForegroundColor = .label
            configuration.background.backgroundColor = reaction.isOn ? .tertiarySystemFill : .clear
            configuration.background.cornerRadius = 20
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.perform(reaction) })
            button.accessibilityLabel = reaction.title
            return button
        })
        row.spacing = 4
        return panel(row, cornerRadius: 26, insets: NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
    }

    private func actionsPanel() -> UIView {
        let rows = UIStackView(arrangedSubviews: menu.items.map { item in
            switch item {
            case let .action(action):
                return row(title: action.title, image: action.image, primaryAction: UIAction { [weak self] _ in self?.perform(action) })
            case let .submenu(title, image, children):
                let button = row(title: title, image: image, chevron: true)
                button.menu = UIMenu(children: children.map { child in
                    UIAction(title: child.title, image: child.image) { [weak self] _ in self?.perform(child) }
                })
                button.showsMenuAsPrimaryAction = true
                // Opening upward from the bottom row would otherwise reverse the order.
                button.preferredMenuElementOrder = .fixed
                return button
            }
        })
        rows.axis = .vertical
        return panel(rows, cornerRadius: 18, insets: NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
    }

    private func row(title: String, image: UIImage?, chevron: Bool = false, primaryAction: UIAction? = nil) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = image
        configuration.imagePadding = 12
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
        let button = UIButton(configuration: configuration, primaryAction: primaryAction)
        button.contentHorizontalAlignment = .leading
        button.widthAnchor.constraint(equalToConstant: 240).isActive = true
        if chevron {
            let arrow = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)))
            arrow.tintColor = .secondaryLabel
            arrow.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(arrow)
            NSLayoutConstraint.activate([
                arrow.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16),
                arrow.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
        return button
    }

    private func panel(_ content: UIView, cornerRadius: CGFloat, insets: NSDirectionalEdgeInsets) -> UIView {
        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        background.layer.cornerRadius = cornerRadius
        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true
        // The message scrolls under the panels; the material alone lets its text show through.
        background.contentView.backgroundColor = .systemBackground.withAlphaComponent(0.6)
        content.translatesAutoresizingMaskIntoConstraints = false
        background.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: background.contentView.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: background.contentView.bottomAnchor, constant: -insets.bottom),
            content.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor, constant: insets.leading),
            content.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor, constant: -insets.trailing),
        ])
        return background
    }

    /// Links open the way they do in the chat, which checks them, rather than straight in a browser.
    func textView(_: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case let .link(url) = textItem.content else { return defaultAction }
        let openLink = openLink
        return UIAction { [weak self] _ in
            self?.close { openLink(url) }
        }
    }
}

/// A gesture delegate that lets its recognizers begin only where `shouldBegin` says, and together, so the press
/// that shrinks a bubble and the long press that lifts it both track one touch.
@MainActor
final class ChatGestureFilter: NSObject, UIGestureRecognizerDelegate {
    private let isPassive: Bool
    private let shouldBegin: (UIGestureRecognizer) -> Bool

    /// A passive recognizer only shows feedback, so it recognizes alongside every other one: once begun it would
    /// otherwise stop a slower tap on an image or link in the bubble.
    init(isPassive: Bool = false, shouldBegin: @escaping (UIGestureRecognizer) -> Bool) {
        self.isPassive = isPassive
        self.shouldBegin = shouldBegin
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        shouldBegin(gestureRecognizer)
    }

    /// With the list's scrolling too: a press that has begun would otherwise stop the list from scrolling.
    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        isPassive || other.delegate is ChatGestureFilter || other is UIPanGestureRecognizer
    }
}

/// Picks when a custom reminder is due.
struct ChatReminderDatePicker: View {
    let onSet: (Date) -> Void
    let onCancel: () -> Void
    @State private var date = Date().addingTimeInterval(60 * 60)

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Remind Me", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
            }
            .navigationTitle("Remind Me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { onSet(date) }
                }
            }
        }
    }
}
