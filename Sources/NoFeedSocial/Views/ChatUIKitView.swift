import Combine
import NoFeedSocialCore
import NoFeedSocialPush
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// UIKit chat shared by every network: a diffable list of self-sizing cells under a floating composer.
struct ChatUIKitView: UIViewControllerRepresentable {
    let viewModel: ChatViewModel
    /// A sender's avatar or a mention was tapped.
    var showProfile: (ChatUser) -> Void = { _ in }

    func makeUIViewController(context _: Context) -> ChatViewController {
        let controller = ChatViewController(viewModel: viewModel)
        controller.showProfile = showProfile
        return controller
    }

    func updateUIViewController(_ controller: ChatViewController, context _: Context) {
        controller.showProfile = showProfile
    }
}

final class ChatViewController: UIViewController, UICollectionViewDelegate, UITextViewDelegate,
    PHPickerViewControllerDelegate, UIDocumentPickerDelegate
{
    private enum Section {
        case messages
    }

    private enum Item: Hashable {
        case message(String)
        case unreadDivider
    }

    private let viewModel: ChatViewModel
    var showProfile: (ChatUser) -> Void = { _ in }
    private var cancellables = Set<AnyCancellable>()
    private var collectionView: UICollectionView!
    private var contentSizeObservation: NSKeyValueObservation?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var messagesById: [String: ChatMessage] = [:]
    private var orderedMessages: [ChatMessage] = []
    private var indexById: [String: Int] = [:]
    /// What each cell was configured from: its message and its place in a sender group.
    /// Keyed by item key (`itemKey(for:)`), so a sent message compares with its "sending" copy.
    private var renderedMessages: [String: (message: ChatMessage, layout: ChatBubbleLayout, reply: ChatReplyQuote?)] = [:]
    private var attributedCache: [String: NSAttributedString] = [:]
    /// Set while a re-render for newly loaded custom emoji images is waiting, so a burst of loads renders once.
    private var emojiReconfigurePending = false
    /// Item keys back to message ids; see `itemKey(for:)`.
    private var messageIdByKey: [String: String] = [:]
    /// Messages whose spoilers were tapped open; they stay open while the chat is.
    private var revealedSpoilers: Set<String> = []
    /// Messages in this chat with a reminder, by id, and when it is due.
    private var reminderDates: [String: Date] = [:]
    /// Message embeds tapped open to their full text, as `<message id>|<embed index>`; they stay open while the
    /// chat is.
    private var expandedEmbeds: Set<String> = []
    /// Read from the current layout: a list that fits on screen never scrolls, so a value kept from the last
    /// scroll could be one from before the view had its size.
    private var isNearBottom: Bool {
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return visibleBottom >= collectionView.contentSize.height - 80
    }

    /// Follows the newest message: set when the room opens at the bottom or the user scrolls back down,
    /// cleared when the user scrolls away. Layout changes while pinned re-anchor to the bottom.
    private var isPinnedToBottom = false
    /// Keeps the "New Messages" divider at the top while the room opens: history, reactions and quotes that
    /// arrive after the cached first frame change cell heights above it. Cleared once the user scrolls.
    private var isAnchoredToDivider = false
    private var hasScrolledInitially = false

    // Latest published composer state; @Published emits in willSet, so the view model still holds old values.
    private var state: ChatConnectionState = .connecting
    private var isSending = false
    private var draft = ""
    private var attachment: ChatAttachment?
    private var replyingTo: ChatMessage?
    private var hasLater = false
    private var hasEarlier = false
    private let historySpinner = UIActivityIndicatorView(style: .medium)
    private var pendingJumpTarget: String?
    /// While a jump's scroll animates, the messages it passes neither page in history nor count as seen.
    private var isAnimatingJump = false
    private let jumpToLatestButton = UIButton(type: .system)
    private let jumpToLatestGlass = ChatGlass.make(cornerRadius: 20)
    private let unreadBadge = UIView()
    private let unreadBadgeLabel = UILabel()
    private var unreadCount = 0
    private let unseenReactionsButton = UIButton(type: .system)
    private let unseenReactionsGlass = ChatGlass.make(cornerRadius: 20)
    private let unseenReactionsBadge = UIView()
    private let unseenReactionsBadgeLabel = UILabel()
    private var unseenReactionCount = 0
    /// The heart sits above the jump-to-latest button while that shows, and takes its place otherwise.
    private var unseenReactionsAboveJump: NSLayoutConstraint!
    private var unseenReactionsInJumpPlace: NSLayoutConstraint!
    private var userHasScrolled = false
    private var reactionTotals: [String: [ChatReaction]] = [:]
    /// Reaction changes made while a message's context menu is up wait for it to finish dismissing, so the
    /// bubble doesn't grow under the dismissal preview.
    private var isShowingContextMenu = false
    private var pendingReactionTotals: [String: [ChatReaction]]?
    private var avatarPrefetches = Set<URL>()
    private let reactionHaptic = UISelectionFeedbackGenerator()
    private let audioPlayer = ChatAudioPreviewPlayer()

    private let composer = UIStackView()
    private let typingView = ChatGlass.make(cornerRadius: 14)
    private let mentionGlass = ChatGlass.make(cornerRadius: 18)
    private let mentionStack = UIStackView()
    /// The `@query` or `:query` word being completed, in the text view's text, and the suggestions shown for it.
    private var mentionRange: NSRange?
    private var shownSuggestionIds: [String] = []
    private let typingLabel = UILabel()
    private let noticeView = ChatGlass.make(cornerRadius: 16)
    private let noticeLabel = UILabel()
    private let reconnectButton = UIButton(type: .system)
    private let attachButton = UIButton(type: .system)
    private let inputPill = ChatGlass.make(cornerRadius: 22)
    private let attachmentPreview = UIStackView()
    private let replyPreview = UIStackView()
    private let replyPreviewName = UILabel()
    private let replyPreviewText = UILabel()
    private let attachmentThumbnail = UIImageView()
    private let attachmentName = UILabel()
    private let textView = ChatComposerTextView()
    private let placeholderLabel = UILabel()
    private let sendButton = UIButton(configuration: .plain())
    private let pillStack = UIStackView()
    private var textViewHeight: NSLayoutConstraint!
    private let maxComposerLines: CGFloat = 5
    private let minimumTextHeight: CGFloat = 36

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureCollectionView()
        configureComposer()
        configureJumpToLatestButton()
        configureUnseenReactionsButton()
        configureTypingIndicator()
        configureMentionSuggestions()
        bind()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        audioPlayer.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        performInitialScrollIfNeeded()
        updateTextViewHeight()
        updateContentInsetForComposer()
        updateTopInsetForShortContent()
        reanchorIfPinned()
    }

    // MARK: - Layout

    private func configureCollectionView() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        // Tapping the messages dismisses the keyboard; touches still reach links, images and reactions.
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismissTap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(dismissTap)
        collectionView.addGestureRecognizer(messagePress)
        collectionView.addGestureRecognizer(messageLift)
        collectionView.showsVerticalScrollIndicator = false
        if #available(iOS 26.0, *) {
            // UIKit's equivalent of `.scrollEdgeEffectStyle(.soft, for: .top)`: messages soften under the bar.
            collectionView.topEdgeEffect.style = .soft
        }
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        contentSizeObservation = collectionView.observe(\.contentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateTopInsetForShortContent() }
        }

        let messageRegistration = UICollectionView.CellRegistration<ChatMessageCell, String> { [weak self] cell, _, id in
            guard let self, let message = messagesById[id], let index = indexById[id] else { return }
            let layout = bubbleLayout(at: index)
            let reply = message.replyToId.map(replyQuote(for:))
            prefetchReactorAvatars(on: message)
            cell.bubbleView.alpha = id == focusedMessageId ? 0 : 1
            cell.configure(
                message: message,
                layout: layout,
                reply: reply,
                avatarURL: layout.showsAvatar ? viewModel.avatarURL(for: message.sender) : nil,
                body: attributedBody(for: message, isOwn: layout.isOwn),
                embeds: message.isDeleted ? [] : message.embeds,
                reactions: message.isDeleted ? [] : reactionTotals[id] ?? [],
                actions: ChatMessageCell.Actions(
                    canReply: viewModel.canReply && message.isUserMessage && !message.isDeleted,
                    canReact: viewModel.canReact && !message.isNotice && !message.isDeleted,
                    reply: { [weak self] in self?.beginReply(to: id) },
                    toggleReaction: { [weak self] emoji in self?.toggleReaction(emoji, on: id) },
                    showReplyTarget: { [weak self] in
                        // A quote whose original the server no longer keeps has nowhere to go.
                        guard let self, let target = message.replyToId, !viewModel.isUnavailableReference(target) else { return }
                        Task { await self.viewModel.jump(to: target) }
                    },
                    reactionMenu: { [weak self] emoji in self?.reactionMenu(pressed: emoji, on: id) },
                    showProfile: { [weak self] in self?.showProfile(message.sender) },
                    showImage: { [weak self] url, alt, image in
                        self?.present(ChatImageViewerController(url: url, image: image, alt: alt), animated: true)
                    },
                    audioPlayer: audioPlayer,
                    previewURL: { [weak self] id in await self?.viewModel.audioPreviewURL(for: id) },
                    showMentionedUser: { [weak self] userId in
                        // The profile fills in what the network knows about the user.
                        self?.showProfile(ChatUser(id: userId, name: nil, avatarURL: nil))
                    },
                    openLink: { [weak self] url in self?.openLink(url) },
                    revealSpoilers: { [weak self] in self?.revealSpoilers(of: id) },
                    isEmbedExpanded: { [weak self] index in self?.expandedEmbeds.contains("\(id)|\(index)") ?? false },
                    toggleEmbed: { [weak self] index in self?.toggleEmbed(index, of: id) },
                    customEmoji: { [weak self] key in self?.viewModel.customEmojis[key] },
                    customEmojiImageDidLoad: { [weak self] in self?.customEmojiImagesDidLoad() },
                ),
                reminderDue: message.isDeleted ? nil : reminderDates[id],
                availableWidth: collectionView.bounds.width > 0 ? collectionView.bounds.width : view.bounds.width,
            )
        }
        let dividerRegistration = UICollectionView.CellRegistration<ChatUnreadDividerCell, Item> { _, _, _ in }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case let .message(key):
                collectionView.dequeueConfiguredReusableCell(using: messageRegistration, for: indexPath, item: self.messageId(forKey: key))
            case .unreadDivider:
                collectionView.dequeueConfiguredReusableCell(using: dividerRegistration, for: indexPath, item: item)
            }
        }

        // History loads as the user nears either end; a small spinner under the title shows it is coming.
        historySpinner.hidesWhenStopped = true
        historySpinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(historySpinner)
        NSLayoutConstraint.activate([
            historySpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            historySpinner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
    }

    private func configureComposer() {
        // Notice capsule for connection state and send errors, floating above the input row.
        noticeLabel.font = .preferredFont(forTextStyle: .footnote)
        noticeLabel.numberOfLines = 0
        reconnectButton.setTitle("Reconnect", for: .normal)
        reconnectButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        reconnectButton.setContentHuggingPriority(.required, for: .horizontal)
        reconnectButton.addAction(UIAction { [weak self] _ in
            Task { await self?.viewModel.connect() }
        }, for: .primaryActionTriggered)
        let noticeRow = UIStackView(arrangedSubviews: [noticeLabel, reconnectButton])
        noticeRow.spacing = 8
        noticeRow.alignment = .center
        noticeRow.isLayoutMarginsRelativeArrangement = true
        noticeRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        noticeView.contentView.addSubview(noticeRow)
        noticeRow.pinToEdges(of: noticeView.contentView)
        noticeView.isHidden = true

        // Attachments button: its own glass circle to the left of the input.
        attachButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        attachButton.tintColor = .label
        attachButton.accessibilityLabel = "Add Attachment"
        attachButton.showsMenuAsPrimaryAction = true
        attachButton.menu = UIMenu(children: [
            UIAction(title: "Photo Library", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.presentPhotoPicker() },
            UIAction(title: "Files", image: UIImage(systemName: "folder")) { [weak self] _ in self?.presentDocumentPicker() },
        ])
        let attachGlass = ChatGlass.make(cornerRadius: 22)
        attachGlass.contentView.addSubview(attachButton)
        attachButton.pinToEdges(of: attachGlass.contentView)
        NSLayoutConstraint.activate([
            attachGlass.widthAnchor.constraint(equalToConstant: 44),
            attachGlass.heightAnchor.constraint(equalToConstant: 44),
        ])
        attachGlass.setContentHuggingPriority(.required, for: .horizontal)
        attachGlass.isHidden = !viewModel.offersAttachments

        // Staged attachment shown inside the input pill, above the text.
        attachmentThumbnail.contentMode = .scaleAspectFill
        attachmentThumbnail.clipsToBounds = true
        attachmentThumbnail.layer.cornerRadius = 8
        attachmentThumbnail.layer.cornerCurve = .continuous
        attachmentThumbnail.tintColor = .secondaryLabel
        NSLayoutConstraint.activate([
            attachmentThumbnail.widthAnchor.constraint(equalToConstant: 48),
            attachmentThumbnail.heightAnchor.constraint(equalToConstant: 48),
        ])
        attachmentName.font = .preferredFont(forTextStyle: .footnote)
        attachmentName.textColor = .secondaryLabel
        attachmentName.lineBreakMode = .byTruncatingMiddle
        let removeAttachment = UIButton(type: .system)
        removeAttachment.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        removeAttachment.tintColor = .secondaryLabel
        removeAttachment.accessibilityLabel = "Remove Attachment"
        removeAttachment.setContentHuggingPriority(.required, for: .horizontal)
        removeAttachment.addAction(UIAction { [weak self] _ in self?.viewModel.attachment = nil }, for: .primaryActionTriggered)
        attachmentPreview.addArrangedSubview(attachmentThumbnail)
        attachmentPreview.addArrangedSubview(attachmentName)
        attachmentPreview.addArrangedSubview(removeAttachment)
        attachmentPreview.spacing = 8
        attachmentPreview.alignment = .center
        attachmentPreview.isHidden = true

        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.onReturn = { [weak self] in
            guard let self, sendButton.isEnabled else { return }
            send()
        }
        textView.accessibilityLabel = "Message"
        textViewHeight = textView.heightAnchor.constraint(equalToConstant: minimumTextHeight)
        textViewHeight.isActive = true

        placeholderLabel.text = "Message"
        placeholderLabel.font = textView.font
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)

        var sendConfiguration = UIButton.Configuration.plain()
        sendConfiguration.image = UIImage(systemName: "arrow.up.circle.fill")
        sendConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 28)
        sendConfiguration.contentInsets = .zero
        // Match the outgoing bubble color rather than the app's monochrome tint.
        sendConfiguration.baseForegroundColor = .systemBlue
        sendButton.configuration = sendConfiguration
        sendButton.accessibilityLabel = "Send"
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .primaryActionTriggered)

        let textRow = UIStackView(arrangedSubviews: [textView, sendButton])
        textRow.alignment = .bottom
        textRow.spacing = 6
        configureReplyPreview()
        pillStack.addArrangedSubview(replyPreview)
        pillStack.addArrangedSubview(attachmentPreview)
        pillStack.addArrangedSubview(textRow)
        pillStack.axis = .vertical
        pillStack.spacing = 4
        pillStack.isLayoutMarginsRelativeArrangement = true
        pillStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14)
        sendButton.isHidden = true
        inputPill.contentView.addSubview(pillStack)
        pillStack.pinToEdges(of: inputPill.contentView)

        let inputRow = UIStackView(arrangedSubviews: [attachGlass, inputPill])
        inputRow.alignment = .bottom
        inputRow.spacing = 8

        composer.axis = .vertical
        composer.spacing = 8
        composer.addArrangedSubview(noticeView)
        composer.addArrangedSubview(inputRow)
        composer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer)
        if #available(iOS 26.0, *) {
            // The same soft edge as under the navigation bar, extended up behind the floating composer.
            collectionView.bottomEdgeEffect.style = .soft
            let edgeElement = UIScrollEdgeElementContainerInteraction()
            edgeElement.scrollView = collectionView
            edgeElement.edge = .bottom
            composer.addInteraction(edgeElement)
        }

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            composer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),

            // A fixed square keeps the symbol circular; the stack would otherwise stretch it.
            sendButton.widthAnchor.constraint(equalToConstant: minimumTextHeight),
            sendButton.heightAnchor.constraint(equalToConstant: minimumTextHeight),
        ])
    }

    /// Messages scroll under the floating composer, so the list's bottom inset tracks its top edge.
    private func updateContentInsetForComposer() {
        let overlap = view.bounds.maxY - composer.frame.minY + 8 - view.safeAreaInsets.bottom
        let inset = max(0, overlap)
        guard collectionView.contentInset.bottom != inset else { return }
        collectionView.contentInset.bottom = inset
        collectionView.verticalScrollIndicatorInsets.bottom = inset
    }

    /// A chat shorter than the screen sits just above the composer, as in Messages, rather than under the title.
    private func updateTopInsetForShortContent() {
        let current = collectionView.contentInset.top
        let barsTop = collectionView.adjustedContentInset.top - current
        let available = collectionView.bounds.height - barsTop - collectionView.adjustedContentInset.bottom
        let inset = max(0, available - collectionView.contentSize.height)
        guard abs(current - inset) > 0.5 else { return }
        collectionView.contentInset.top = inset
        if inset > 0 || isPinnedToBottom {
            collectionView.contentOffset.y = bottomOffset
        }
    }

    /// Keeps a pinned list at the bottom, or an opening room at its divider, through bounds, inset and cell-size changes.
    private func reanchorIfPinned() {
        guard hasScrolledInitially, !collectionView.isDragging, !collectionView.isDecelerating else { return }
        if isAnchoredToDivider {
            scrollToDivider()
            return
        }
        guard isPinnedToBottom, !hasLater else { return }
        collectionView.layoutIfNeeded()
        if abs(collectionView.contentOffset.y - bottomOffset) > 0.5 {
            scrollToBottom(animated: false)
        }
    }

    // MARK: - Binding

    private func bind() {
        Publishers.CombineLatest3(viewModel.$messages, viewModel.$hasEarlierMessages, viewModel.$hasLaterMessages)
            .sink { [weak self] messages, hasEarlier, hasLater in
                self?.hasLater = hasLater
                self?.hasEarlier = hasEarlier
                self?.applySnapshot(messages: messages, hasEarlier: hasEarlier, hasLater: hasLater)
                self?.updateJumpToLatestButton()
            }
            .store(in: &cancellables)

        viewModel.$isLoadingEarlier.dropFirst().sink { [weak self] loading in
            if loading { self?.historySpinner.startAnimating() } else { self?.historySpinner.stopAnimating() }
        }.store(in: &cancellables)

        // Deferred one turn so the window that `jump(to:)` publishes is applied before scrolling.
        viewModel.$jumpTarget.compactMap(\.self).sink { [weak self] target in
            self?.pendingJumpTarget = target
            DispatchQueue.main.async { self?.performPendingJump() }
        }.store(in: &cancellables)
        viewModel.$unseenReactionMessageIds.sink { [weak self] ids in
            guard let self else { return }
            unseenReactionCount = ids.count
            unseenReactionsBadgeLabel.text = ids.count > ChatViewModel.unreadBadgeCap ? "\(ChatViewModel.unreadBadgeCap)+" : "\(ids.count)"
            updateUnseenReactionsButton()
        }.store(in: &cancellables)
        viewModel.$unreadCount.sink { [weak self] count in
            guard let self else { return }
            unreadCount = count
            unreadBadgeLabel.text = count > ChatViewModel.unreadBadgeCap ? "\(ChatViewModel.unreadBadgeCap)+" : "\(count)"
            updateJumpToLatestButton()
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.reportVisibleRead() }
            .store(in: &cancellables)
        reminderDates = viewModel.reminderTarget.map { ChatReminderStore.dueDates(in: $0) } ?? [:]
        // Every minute too, so "Due in" counts down.
        NotificationCenter.default.publisher(for: ChatReminderStore.remindersDidChange)
            .map { _ in () }
            .merge(with: Timer.publish(every: 60, on: .main, in: .common).autoconnect().map { _ in () })
            .sink { [weak self] in self?.reloadReminders() }
            .store(in: &cancellables)
        viewModel.$typingNames.sink { [weak self] names in self?.updateTypingIndicator(names) }.store(in: &cancellables)
        viewModel.$scrollToLatestRequest.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.isAnchoredToDivider = false
                self?.isPinnedToBottom = true
                self?.scrollToBottom(animated: true)
            }
        }.store(in: &cancellables)
        Publishers.CombineLatest(viewModel.$referencedMessages, viewModel.$unavailableReferences)
            .dropFirst()
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.reconfigureReplies() } }
            .store(in: &cancellables)

        viewModel.$state.sink { [weak self] state in
            self?.state = state
            self?.refreshComposer()
            if state == .connected {
                DispatchQueue.main.async { self?.reportVisibleRead() }
            }
        }.store(in: &cancellables)
        viewModel.$isSending.sink { [weak self] in self?.isSending = $0; self?.refreshComposer() }.store(in: &cancellables)
        viewModel.$draft.sink { [weak self] in self?.draft = $0; self?.refreshComposer() }.store(in: &cancellables)
        viewModel.$attachment.sink { [weak self] in self?.attachment = $0; self?.refreshComposer() }.store(in: &cancellables)
        viewModel.$errorMessage.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshComposer() } }.store(in: &cancellables)
        viewModel.$replyingTo.sink { [weak self] in self?.replyingTo = $0; self?.refreshComposer() }.store(in: &cancellables)
        viewModel.$reactions.sink { [weak self] totals in self?.applyReactionTotals(totals) }.store(in: &cancellables)
        // Emitted in willSet, so re-render once the view model holds the new names.
        viewModel.$mentionNames.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reconfigureMentions() } }
            .store(in: &cancellables)
        viewModel.$customEmojis.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reconfigureCustomEmojis() } }
            .store(in: &cancellables)
        viewModel.$canAttach.sink { [weak self] canAttach in
            self?.attachButton.isEnabled = canAttach
            self?.attachButton.alpha = canAttach ? 1 : 0.35
        }.store(in: &cancellables)
    }

    private func applySnapshot(messages: [ChatMessage], hasEarlier _: Bool, hasLater: Bool) {
        let previousItems = items(in: .messages, of: dataSource.snapshot())
        let previousIds = previousItems.filter { $0 != .unreadDivider }
        let wasEmpty = previousIds.isEmpty
        let previousFirst = previousIds.first
        let previousLast = previousIds.last

        messagesById = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        orderedMessages = messages
        indexById = Dictionary(messages.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.messages])
        messageIdByKey = Dictionary(messages.map { (itemKey(for: $0.id), $0.id) }, uniquingKeysWith: { _, latest in latest })
        let items = messages.map { Item.message(itemKey(for: $0.id)) }
        var rows = items
        if let firstUnread = viewModel.firstUnreadMessageId, let index = rows.firstIndex(of: .message(itemKey(for: firstUnread))) {
            rows.insert(.unreadDivider, at: index)
        }
        snapshot.appendItems(rows, toSection: .messages)

        // Edits, tombstones and finished uploads keep their id, and a new message can end the previous one's
        // group, so re-render items whose message or group position changed. A reply also re-renders when its
        // quote does, such as when an older page brings in the message it quotes.
        var changed: [Item] = []
        for (index, message) in messages.enumerated() {
            let layout = bubbleLayout(at: index)
            let reply = message.replyToId.map(replyQuote(for:))
            let key = itemKey(for: message.id)
            if let rendered = renderedMessages[key], rendered.message != message || rendered.layout != layout || rendered.reply != reply {
                changed.append(.message(key))
            }
            renderedMessages[key] = (message, layout, reply)
        }
        snapshot.reconfigureItems(changed)

        let newFirst = items.first
        let prepended = !wasEmpty && newFirst != previousFirst && previousLast == items.last
        let distanceFromBottom = collectionView.contentSize.height - collectionView.contentOffset.y
        let wasAtBottom = isPinnedToBottom
        // The divider can appear after the cached messages first render, once history shows newer unread.
        let dividerAppeared = rows.contains(.unreadDivider) && !previousItems.contains(.unreadDivider)

        dataSource.apply(snapshot, animatingDifferences: false)

        if pendingJumpTarget != nil {
            // A jump scrolls to its target once applied; don't also follow the bottom.
            hasScrolledInitially = true
        } else if !hasScrolledInitially, !items.isEmpty {
            performInitialScrollIfNeeded()
        } else if prepended {
            // Keep the visible messages in place when earlier history is inserted above them.
            collectionView.layoutIfNeeded()
            collectionView.contentOffset.y = collectionView.contentSize.height - distanceFromBottom
        } else if isAnchoredToDivider {
            scrollToDivider()
        } else if dividerAppeared, !userHasScrolled {
            // Move to it in the same pass. Following the bottom first would animate past the new messages.
            isPinnedToBottom = false
            isAnchoredToDivider = true
            scrollToDivider()
        } else if wasAtBottom, !hasLater {
            // At the bottom, new messages and cells that grew push the list up rather than under the input. A sent
            // message replacing its "sending" copy adds nothing: its new cell starts at an estimated height, so the
            // list settles at the bottom before it draws, rather than jumping and sliding back.
            scrollToBottom(animated: items.count > previousIds.count)
        }
        DispatchQueue.main.async { [weak self] in self?.reportVisibleRead() }
    }

    /// A sent message stays under the item of its "sending" copy, so confirming it reconfigures that cell rather
    /// than replacing it with a new one, whose estimated height would make the list jump.
    private func itemKey(for messageId: String) -> String {
        viewModel.sentLocalIds[messageId] ?? messageId
    }

    private func messageId(forKey key: String) -> String {
        messageIdByKey[key] ?? key
    }

    /// The quote shown in a reply, including targets outside the loaded window while they load.
    private func replyQuote(for targetId: String) -> ChatReplyQuote {
        // The view's own messages first: it renders from the view model's `messages` before that property is set.
        if let target = messagesById[targetId] ?? viewModel.message(withId: targetId) {
            let text = target.isDeleted ? target.previewText : mentionText(target.previewText)
            return ChatReplyQuote(name: DebugRedaction.name(target.sender.name), text: text, accentUserId: target.sender.id)
        }
        let unavailable = viewModel.isUnavailableReference(targetId)
        return ChatReplyQuote(name: "Reply", text: unavailable ? "Message unavailable" : "Loading…", accentUserId: nil)
    }

    /// Quote and reply-preview text with mentions by name, or redacted.
    private func mentionText(_ text: String) -> String {
        DebugRedaction.isEnabled ? DebugRedaction.mentions(in: text, pattern: viewModel.mentionPattern) : viewModel.showingMentionNames(text)
    }

    /// Mentions show names, so messages and quotes with any `@` render again when the known names change.
    private func reconfigureMentions() {
        attributedCache.removeAll()
        var snapshot = dataSource.snapshot()
        let changed = items(in: .messages, of: snapshot).filter { item in
            guard case let .message(key) = item, let message = messagesById[messageId(forKey: key)] else { return false }
            let quoted = message.replyToId.flatMap { viewModel.message(withId: $0)?.text } ?? ""
            return (message.text ?? "").contains("@") || quoted.contains("@")
        }
        guard !changed.isEmpty else { return }
        snapshot.reconfigureItems(changed)
        applyKeepingBottom(snapshot)
    }

    /// Messages whose text or reactions may hold custom emoji render again when the catalog changes or images
    /// load. Cached text holds the attachments, so it goes too.
    private func reconfigureCustomEmojis() {
        attributedCache.removeAll()
        var snapshot = dataSource.snapshot()
        let changed = items(in: .messages, of: snapshot).filter { item in
            guard case let .message(key) = item, case let id = messageId(forKey: key), let message = messagesById[id] else { return false }
            return (message.text ?? "").contains(":") || (reactionTotals[id] ?? []).contains { $0.emoji.hasPrefix(":") }
        }
        guard !changed.isEmpty else { return }
        snapshot.reconfigureItems(changed)
        applyKeepingBottom(snapshot)
    }

    private func customEmojiImagesDidLoad() {
        guard !emojiReconfigurePending else { return }
        emojiReconfigurePending = true
        DispatchQueue.main.async { [weak self] in
            self?.emojiReconfigurePending = false
            self?.reconfigureCustomEmojis()
        }
    }

    /// Re-renders replies whose quote changed, such as when a quoted message outside the loaded ones arrives.
    private func reconfigureReplies() {
        var snapshot = dataSource.snapshot()
        let replies = items(in: .messages, of: snapshot).filter { item in
            guard case let .message(key) = item, let target = messagesById[messageId(forKey: key)]?.replyToId,
                  var rendered = renderedMessages[key] else { return false }
            let reply = replyQuote(for: target)
            guard rendered.reply != reply else { return false }
            rendered.reply = reply
            renderedMessages[key] = rendered
            return true
        }
        guard !replies.isEmpty else { return }
        snapshot.reconfigureItems(replies)
        applyKeepingBottom(snapshot)
    }

    private func performPendingJump() {
        guard let target = pendingJumpTarget else { return }
        pendingJumpTarget = nil
        viewModel.clearJumpTarget()
        guard let message = viewModel.message(withId: target), let indexPath = dataSource.indexPath(for: .message(itemKey(for: message.id))) else { return }
        isPinnedToBottom = false
        isAnchoredToDivider = false
        collectionView.layoutIfNeeded()
        isAnimatingJump = true
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            (self?.collectionView.cellForItem(at: indexPath) as? ChatMessageCell)?.flash()
        }
        // In case the scroll was too short to animate, so `scrollViewDidEndScrollingAnimation` doesn't come.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.jumpDidEnd() }
    }

    /// Floating button that returns to the newest message, shown when scrolled up or viewing an older window.
    private func updateJumpToLatestButton() {
        let visible = hasLater || (!isNearBottom && hasScrolledInitially)
        let glass = jumpToLatestGlass
        unreadBadge.isHidden = !visible || unreadCount == 0
        guard glass.isHidden == visible else { return }
        unseenReactionsAboveJump.isActive = false
        unseenReactionsInJumpPlace.isActive = !visible
        unseenReactionsAboveJump.isActive = visible
        UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
        if visible { glass.isHidden = false }
        UIView.animate(withDuration: 0.2, animations: {
            glass.alpha = visible ? 1 : 0
            glass.transform = visible ? .identity : CGAffineTransform(scaleX: 0.7, y: 0.7)
        }, completion: { _ in
            glass.isHidden = !visible
        })
    }

    /// `itemIdentifiers(inSection:)` raises for a section the snapshot doesn't have, such as before the first apply.
    private func items(in section: Section, of snapshot: NSDiffableDataSourceSnapshot<Section, Item>) -> [Item] {
        snapshot.sectionIdentifiers.contains(section) ? snapshot.itemIdentifiers(inSection: section) : []
    }

    private func refreshComposer() {
        let errorMessage = viewModel.errorMessage
        if case let .disconnected(reason) = state {
            noticeLabel.text = reason ?? "Disconnected"
            noticeLabel.textColor = .secondaryLabel
            reconnectButton.isHidden = false
            noticeView.isHidden = false
        } else if let errorMessage {
            noticeLabel.text = errorMessage
            noticeLabel.textColor = .systemRed
            reconnectButton.isHidden = true
            noticeView.isHidden = false
        } else {
            noticeView.isHidden = true
        }

        if textView.text != draft {
            textView.text = draft
            updateMentionSuggestions()
            updateTextViewHeight()
        }
        placeholderLabel.isHidden = !draft.isEmpty

        if let replyingTo {
            replyPreview.isHidden = false
            replyPreviewName.text = "Reply to \(DebugRedaction.name(replyingTo.sender.name))"
            replyPreviewText.text = mentionText(replyingTo.previewText).replacingOccurrences(of: "\n", with: " ")
        } else {
            replyPreview.isHidden = true
        }

        if let attachment {
            attachmentPreview.isHidden = false
            attachmentName.text = attachment.filename
            if attachment.isImage, let image = UIImage(data: attachment.data) {
                attachmentThumbnail.image = image
                attachmentThumbnail.contentMode = .scaleAspectFill
            } else {
                attachmentThumbnail.image = UIImage(systemName: "doc.fill")
                attachmentThumbnail.contentMode = .center
            }
        } else {
            attachmentPreview.isHidden = true
            attachmentThumbnail.image = nil
        }

        let hasContent = attachment != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // The send button appears only once there is something to send, like Messages.
        let showsSend = hasContent || isSending
        if sendButton.isHidden == showsSend {
            UIView.animate(withDuration: 0.2) { [self] in
                sendButton.isHidden = !showsSend
                sendButton.alpha = showsSend ? 1 : 0
                pillStack.directionalLayoutMargins.trailing = showsSend ? 4 : 14
                inputPill.layoutIfNeeded()
            }
        }
        sendButton.isEnabled = state == .connected && !isSending && hasContent
        sendButton.configuration?.showsActivityIndicator = isSending
        view.setNeedsLayout()
    }

    /// Consecutive messages from one sender within 10 minutes form a group: the name heads it and the avatar ends it.
    private func bubbleLayout(at index: Int) -> ChatBubbleLayout {
        let message = orderedMessages[index]
        let previous = index > 0 ? orderedMessages[index - 1] : nil
        let next = index + 1 < orderedMessages.count ? orderedMessages[index + 1] : nil
        func grouped(_ earlier: ChatMessage?, _ later: ChatMessage?) -> Bool {
            guard let earlier, let later, !earlier.sender.isSystem, !later.sender.isSystem,
                  earlier.sender.id == later.sender.id,
                  let start = earlier.timestamp, let end = later.timestamp
            else { return false }
            return end.timeIntervalSince(start) < 600
        }
        let isSystem = message.sender.isSystem
        let isOwn = !isSystem && message.isOwn
        let startsGroup = !grouped(previous, message)
        let endsGroup = !grouped(message, next)
        return ChatBubbleLayout(
            isOwn: isOwn,
            isSystem: isSystem,
            showsName: startsGroup && !isOwn && !isSystem && viewModel.showsSenderNames,
            showsAvatar: endsGroup && !isOwn && !isSystem,
            startsGroup: startsGroup,
        )
    }

    private func attributedBody(for message: ChatMessage, isOwn: Bool) -> NSAttributedString? {
        guard !message.isDeleted, let text = message.text, !text.isEmpty else { return nil }
        let hidesSpoilers = !message.spoilers.isEmpty && !revealedSpoilers.contains(message.id)
        // Mentions are in the key: a Telegram `@username` gets its user id once the user loads.
        let key = "\(message.id)|\(isOwn)|\(hidesSpoilers)|\(message.mentions.map(\.userId))|\(text)"
        if let cached = attributedCache[key] {
            return cached
        }
        let isSystem = message.sender.isSystem
        let rendered = ChatAttributedText.make(
            viewModel.renderedText(for: message),
            color: isSystem ? .secondaryLabel : isOwn ? .white : .label,
            linkColor: isOwn ? .white : .link,
            codeBackground: isOwn ? UIColor.white.withAlphaComponent(0.22) : UIColor.label.withAlphaComponent(0.08),
            // White text on the blue bubble can't use the link color, so mentions there are underlined instead.
            underlinesMentions: isOwn,
            mentionPattern: viewModel.mentionPattern,
            mentionNames: viewModel.mentionNames,
            redactsMentions: DebugRedaction.isEnabled,
            customEmojis: viewModel.customEmojis,
            emojiImageDidLoad: { [weak self] in self?.customEmojiImagesDidLoad() },
            places: ChatPlaces(
                label: { [viewModel] in viewModel.placeLabel(forLink: $0) },
                referencePattern: viewModel.referencePattern,
                referenceLabel: { [viewModel] in viewModel.placeLabel(forReference: $0) },
            ),
            font: isSystem ? .preferredFont(forTextStyle: .footnote) : .preferredFont(forTextStyle: .body),
            formatsQuotes: message.isMarkdown,
        )
        let marked = mentionsMarked(message.mentions, in: rendered, isOwn: isOwn)
        guard hidesSpoilers else {
            attributedCache[key] = marked
            return marked
        }
        let hidden = NSMutableAttributedString(attributedString: marked)
        let color = isOwn ? UIColor.white : UIColor.label
        for range in message.spoilers where NSMaxRange(range) <= hidden.length {
            // A hidden link or mention reveals the spoiler instead of opening.
            hidden.removeAttribute(.chatLink, range: range)
            hidden.removeAttribute(.chatMention, range: range)
            hidden.addAttributes([.foregroundColor: UIColor.clear, .chatSpoiler: color], range: range)
        }
        attributedCache[key] = hidden
        return hidden
    }

    /// Mentions a network marks by position, styled and tappable like `@user_id` ones. They apply to plain text,
    /// whose rendering keeps the text's length.
    private func mentionsMarked(_ mentions: [ChatMessageMention], in text: NSAttributedString, isOwn: Bool) -> NSAttributedString {
        guard !mentions.isEmpty else { return text }
        let marked = NSMutableAttributedString(attributedString: text)
        for mention in mentions where NSMaxRange(mention.range) <= marked.length {
            marked.addAttribute(.chatMention, value: mention.userId, range: mention.range)
            // White text on the blue bubble can't use the link color, so mentions there are underlined instead.
            if isOwn {
                marked.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: mention.range)
            } else {
                marked.addAttribute(.foregroundColor, value: UIColor.link, range: mention.range)
            }
        }
        return marked
    }

    /// Opens at the "New Messages" divider when there is one, like Telegram, otherwise at the newest message.
    /// Waits for real bounds: cached messages are applied before the view is first laid out.
    private func performInitialScrollIfNeeded() {
        guard !hasScrolledInitially, collectionView.bounds.height > 0,
              !items(in: .messages, of: dataSource.snapshot()).isEmpty
        else { return }
        hasScrolledInitially = true
        collectionView.layoutIfNeeded()
        isPinnedToBottom = dataSource.indexPath(for: .unreadDivider) == nil
        if dataSource.indexPath(for: .unreadDivider) != nil {
            isAnchoredToDivider = true
            scrollToDivider()
        } else {
            scrollToBottom(animated: false)
        }
    }

    /// Puts the divider at the top. Two passes: the first lays out the cells around it, the second lands on it
    /// exactly. When everything fits on screen the divider is also the bottom, so the list follows the bottom instead.
    private func scrollToDivider() {
        guard let divider = dataSource.indexPath(for: .unreadDivider) else {
            isAnchoredToDivider = false
            return
        }
        for _ in 0 ..< 2 {
            collectionView.layoutIfNeeded()
            guard let frame = collectionView.layoutAttributesForItem(at: divider)?.frame else { break }
            let target = min(frame.minY - collectionView.adjustedContentInset.top, bottomOffset)
            guard abs(collectionView.contentOffset.y - target) > 0.5 else { break }
            collectionView.scrollToItem(at: divider, at: .top, animated: false)
        }
        collectionView.layoutIfNeeded()
        if collectionView.contentOffset.y >= bottomOffset - 1 {
            isAnchoredToDivider = false
            isPinnedToBottom = true
        }
    }

    /// Scrolls to the real bottom after layout, so self-sized cells never end up under the composer.
    private func scrollToBottom(animated: Bool) {
        if animated {
            // Animate one move to the measured bottom, then settle quietly if the new cells' real
            // heights differ from their estimates.
            collectionView.layoutIfNeeded()
            let target = bottomOffset
            guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
                self.collectionView.contentOffset.y = target
            } completion: { _ in
                // The list may have stopped following the bottom meanwhile, such as for a new divider.
                if !self.collectionView.isDragging, self.isPinnedToBottom, !self.isAnchoredToDivider {
                    self.scrollToBottom(animated: false)
                }
            }
            return
        }
        // Self-sizing cells start at estimated heights; each pass lays out the cells it lands on and
        // corrects `contentSize`, so repeat until the bottom stops moving.
        for _ in 0 ..< 4 {
            collectionView.layoutIfNeeded()
            let offset = bottomOffset
            guard abs(collectionView.contentOffset.y - offset) > 0.5 else { break }
            collectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        }
    }

    private var bottomOffset: CGFloat {
        let insets = collectionView.adjustedContentInset
        return max(-insets.top, collectionView.contentSize.height - collectionView.bounds.height + insets.bottom)
    }

    /// Applies a change that can grow cells (reactions, quotes, edits) while keeping the view anchored to the
    /// bottom when it was there, so the growth pushes content up instead of under the input.
    private func applyKeepingBottom(_ snapshot: NSDiffableDataSourceSnapshot<Section, Item>, animated: Bool = false) {
        let wasAtBottom = isPinnedToBottom && hasScrolledInitially && !hasLater
        if animated, !isAnchoredToDivider {
            // Grow the cells and follow the bottom in one animation, so the list moves up with the growth. Away
            // from the bottom, the lowest visible message stays put, so growth above it also moves content up.
            collectionView.layoutIfNeeded()
            let anchor = wasAtBottom ? nil : lowestVisibleItem()
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
                self.dataSource.apply(snapshot, animatingDifferences: false)
                self.collectionView.layoutIfNeeded()
                if wasAtBottom {
                    self.collectionView.contentOffset.y = self.bottomOffset
                } else if let anchor, let indexPath = self.dataSource.indexPath(for: anchor.item),
                          let frame = self.collectionView.layoutAttributesForItem(at: indexPath)?.frame
                {
                    let target = frame.maxY - anchor.screenMaxY
                    self.collectionView.contentOffset.y = min(max(target, -self.collectionView.adjustedContentInset.top), self.bottomOffset)
                }
            }
            return
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        if isAnchoredToDivider, hasScrolledInitially {
            scrollToDivider()
        } else if wasAtBottom {
            scrollToBottom(animated: true)
        }
    }

    /// The last item showing above the composer, with its bottom edge's distance from the top of the content offset.
    private func lowestVisibleItem() -> (item: Item, screenMaxY: CGFloat)? {
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        let indexPath = collectionView.indexPathsForVisibleItems
            .filter { (collectionView.layoutAttributesForItem(at: $0)?.frame.minY ?? .infinity) < visibleBottom }
            .max()
        guard let indexPath, let item = dataSource.itemIdentifier(for: indexPath),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
        else { return nil }
        return (item, frame.maxY - collectionView.contentOffset.y)
    }

    private func send() {
        Task {
            await viewModel.send()
            // Like Messages, sending shows your message at the bottom.
            if viewModel.errorMessage == nil {
                await viewModel.jumpToLatest()
            }
        }
    }

    private func updateTextViewHeight() {
        guard let font = textView.font else { return }
        let width = textView.bounds.width
        guard width > 0 else { return }
        let maxHeight = font.lineHeight * maxComposerLines + textView.textContainerInset.top + textView.textContainerInset.bottom
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(fitting, minimumTextHeight), maxHeight)
        textView.isScrollEnabled = fitting > maxHeight
        if textViewHeight.constant != height {
            textViewHeight.constant = height
        }
    }

    // MARK: - Attachments

    private func presentPhotoPicker() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        let baseName = provider.suggestedName ?? "photo"
        if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
            // Keep GIFs as is so they stay animated.
            provider.loadDataRepresentation(forTypeIdentifier: UTType.gif.identifier) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor in
                    self?.viewModel.attachment = .init(data: data, mimeType: "image/gif", filename: "\(baseName).gif", isImage: true)
                }
            }
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage, let data = ChatImageEncoding.jpeg(from: image) else { return }
            Task { @MainActor in
                self?.viewModel.attachment = .init(data: data, mimeType: "image/jpeg", filename: "\(baseName).jpg", isImage: true)
            }
        }
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            let data = try Data(contentsOf: url)
            let type = UTType(filenameExtension: url.pathExtension)
            viewModel.attachment = .init(
                data: data,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                filename: url.lastPathComponent,
                isImage: type?.conforms(to: .image) ?? false,
            )
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    @objc private func dismissKeyboard() {
        guard textView.isFirstResponder else { return }
        textView.resignFirstResponder()
    }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        viewModel.draft = textView.text
        viewModel.draftDidChange()
        updateTextViewHeight()
        updateMentionSuggestions()
    }

    func textViewDidChangeSelection(_: UITextView) {
        updateMentionSuggestions()
    }

    func textViewDidEndEditing(_: UITextView) {
        updateMentionSuggestions()
    }

    // MARK: - UICollectionViewDelegate

    func scrollViewWillBeginDragging(_: UIScrollView) {
        userHasScrolled = true
        isAnchoredToDivider = false
    }

    func scrollViewDidEndScrollingAnimation(_: UIScrollView) {
        jumpDidEnd()
    }

    private func jumpDidEnd() {
        guard isAnimatingJump else { return }
        isAnimatingJump = false
        reportVisibleRead()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Only the user's own scrolling changes whether the list follows new messages.
        if scrollView.isDragging || scrollView.isDecelerating {
            isPinnedToBottom = isNearBottom
        }
        updateJumpToLatestButton()
        loadMoreIfNeeded(scrollView)
        reportVisibleRead()
    }

    /// Marks read up to the newest message fully on screen, only while the chat is visible and the app active (§4.6).
    /// Cached messages shown before the chat connects don't count: reading them would move the cursor, and with it
    /// the divider that history places once it arrives.
    private func reportVisibleRead() {
        guard hasScrolledInitially, !isAnimatingJump, state == .connected, view.window != nil, UIApplication.shared.applicationState == .active else { return }
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        var newest: Int?
        var shown: Set<String> = []
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard case let .message(key) = dataSource.itemIdentifier(for: indexPath),
                  let index = indexById[messageId(forKey: key)], !orderedMessages[index].isNotice,
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
            else { continue }
            // Reactions sit at the bottom of the bubble, so they show once its bottom is on screen and clear of
            // the header by about a chip's height; just under the header they're still hidden by its blur.
            if frame.maxY <= visibleBottom + 1, frame.maxY >= visibleTop + 40 {
                shown.insert(orderedMessages[index].id)
            }
            guard frame.maxY <= visibleBottom + 1 else { continue }
            newest = max(newest ?? index, index)
        }
        if let newest {
            viewModel.markRead(upTo: orderedMessages[newest])
        }
        if !shown.isEmpty, unseenReactionCount > 0 {
            viewModel.reactionsSeen(on: shown)
        }
    }

    /// Pages history automatically within about a screen of either end; there are no load buttons.
    private func loadMoreIfNeeded(_ scrollView: UIScrollView) {
        guard hasScrolledInitially, pendingJumpTarget == nil, !isAnimatingJump else { return }
        let prefetch = scrollView.bounds.height
        let visibleTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
        if hasEarlier, visibleTop < prefetch, !viewModel.isLoadingEarlier {
            Task { await viewModel.loadEarlier() }
        }
        // In an older window, nearing the bottom pages forward toward the newest messages.
        if hasLater, visibleBottom > scrollView.contentSize.height - prefetch, !viewModel.isLoadingLater {
            Task { await viewModel.loadLater() }
        }
    }

    func collectionView(_: UICollectionView, shouldSelectItemAt _: IndexPath) -> Bool {
        false
    }

    /// The long-press lift and highlight follow the bubble's rounded shape, not the whole row.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration _: UIContextMenuConfiguration, highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        bubblePreview(at: indexPath, in: collectionView)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration _: UIContextMenuConfiguration, dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        bubblePreview(at: indexPath, in: collectionView)
    }

    func collectionView(_: UICollectionView, willDisplayContextMenu _: UIContextMenuConfiguration, animator _: UIContextMenuInteractionAnimating?) {
        isShowingContextMenu = true
    }

    func collectionView(_: UICollectionView, willEndContextMenuInteraction _: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        let finish = { [weak self] in
            guard let self else { return }
            isShowingContextMenu = false
            if let totals = pendingReactionTotals {
                pendingReactionTotals = nil
                applyReactionTotals(totals)
            }
        }
        if let animator { animator.addCompletion(finish) } else { finish() }
    }

    private func bubblePreview(at indexPath: IndexPath, in collectionView: UICollectionView) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: indexPath) as? ChatMessageCell else { return nil }
        let bubble = cell.bubbleView
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: bubble.bounds, cornerRadius: bubble.layer.cornerRadius)
        return UITargetedPreview(view: bubble, parameters: parameters)
    }

    /// A long press on a message lifts it (`liftMessage`); the context menu is left for presses beside bubbles.
    func collectionView(_: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, focusTarget(at: point) == nil,
              case let .message(key) = dataSource.itemIdentifier(for: indexPath),
              let menu = messageMenu(for: messageId(forKey: key))
        else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in menu.uiMenu })
    }

    /// The message whose bubble is at a point in the list, when it has a menu to show.
    private func focusTarget(at point: CGPoint) -> (id: String, cell: ChatMessageCell)? {
        guard let indexPath = collectionView.indexPathForItem(at: point),
              case let .message(key) = dataSource.itemIdentifier(for: indexPath),
              let cell = collectionView.cellForItem(at: indexPath) as? ChatMessageCell,
              cell.isFocusTarget(at: collectionView.convert(point, to: cell)),
              case let id = messageId(forKey: key),
              messageMenu(for: id) != nil
        else { return nil }
        return (id, cell)
    }

    /// Shrinks the bubble while the finger rests, before `messageLift` lifts it, as a context menu's press does.
    private lazy var messagePress: UILongPressGestureRecognizer = {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressMessage))
        press.minimumPressDuration = 0.1
        press.cancelsTouchesInView = false
        press.delegate = messagePressFeedbackFilter
        return press
    }()

    private lazy var messageLift: UILongPressGestureRecognizer = {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(liftMessage))
        press.minimumPressDuration = 0.45
        press.delegate = messagePressFilter
        return press
    }()

    private lazy var messagePressFilter = ChatGestureFilter { [weak self] gesture in
        self?.canLiftMessage(at: gesture) ?? false
    }

    private lazy var messagePressFeedbackFilter = ChatGestureFilter(isPassive: true) { [weak self] gesture in
        self?.canLiftMessage(at: gesture) ?? false
    }

    private func canLiftMessage(at gesture: UIGestureRecognizer) -> Bool {
        guard presentedViewController == nil else { return false }
        return focusTarget(at: gesture.location(in: collectionView)) != nil
    }

    private var pressedCell: ChatMessageCell?
    private var pressStart = CGPoint.zero
    /// The lifted message, whose bubble stays hidden in the list until it settles back.
    private var focusedMessageId: String?

    @objc private func pressMessage(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            pressStart = gesture.location(in: collectionView)
            pressedCell = focusTarget(at: pressStart)?.cell
            pressedCell?.setPressed(true)
        case .changed:
            // A press that has begun doesn't fail when the finger moves, so a drag lets go of the bubble here.
            let location = gesture.location(in: collectionView)
            if hypot(location.x - pressStart.x, location.y - pressStart.y) > 10 {
                gesture.isEnabled = false
                gesture.isEnabled = true
            }
        case .ended, .cancelled, .failed:
            // A lift takes the bubble as it is; otherwise it springs back.
            if focusedMessageId == nil {
                pressedCell?.setPressed(false)
            }
            pressedCell = nil
        default:
            break
        }
    }

    @objc private func liftMessage(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let target = focusTarget(at: gesture.location(in: collectionView)),
              let message = messagesById[target.id],
              let menu = messageMenu(for: target.id)
        else { return }
        let id = target.id
        let bubble = target.cell.bubbleView
        let snapshot = target.cell.focusSnapshot()
        let sourceFrame = bubbleFrameInWindow(bubble)
        focusedMessageId = id
        bubble.alpha = 0
        let focus = ChatMessageFocusController(
            snapshot: snapshot,
            sourceFrame: sourceFrame,
            currentSourceFrame: { [weak self] in
                guard let self, let indexPath = dataSource.indexPath(for: .message(itemKey(for: id))),
                      let cell = collectionView.cellForItem(at: indexPath) as? ChatMessageCell
                else { return nil }
                return bubbleFrameInWindow(cell.bubbleView)
            },
            isOwn: message.isOwn,
            menu: menu,
            openLink: { [weak self] in self?.openLink($0) },
            didClose: { [weak self] in
                guard let self else { return }
                focusedMessageId = nil
                if let indexPath = dataSource.indexPath(for: .message(itemKey(for: id))),
                   let cell = collectionView.cellForItem(at: indexPath) as? ChatMessageCell
                {
                    cell.bubbleView.alpha = 1
                }
            },
        )
        present(focus, animated: false)
    }

    /// The bubble's frame in the window without the press's shrink.
    private func bubbleFrameInWindow(_ bubble: UIView) -> CGRect {
        let center = bubble.superview?.convert(bubble.center, to: nil) ?? .zero
        return CGRect(x: center.x - bubble.bounds.width / 2, y: center.y - bubble.bounds.height / 2, width: bubble.bounds.width, height: bubble.bounds.height)
    }

    private func messageMenu(for id: String) -> ChatMessageMenu? {
        guard let message = messagesById[id], message.isUserMessage else { return nil }
        let text = message.isDeleted ? "" : message.text ?? ""
        var menu = ChatMessageMenu()
        if viewModel.canReact, !message.isDeleted {
            let mine = Set(viewModel.yourEmojis(on: id))
            // A row of small elements holds four, so three reactions leave room for More Reactions.
            menu.reactions = ChatViewModel.quickReactions.prefix(3).map { emoji in
                ChatMessageMenu.Action(title: emoji, isOn: mine.contains(emoji)) { [weak self] in self?.toggleReaction(emoji, on: id) }
            }
            menu.reactions.append(ChatMessageMenu.Action(title: "More Reactions", image: UIImage(systemName: "face.smiling")) { [weak self] in
                self?.presentReactionPicker(for: id)
            })
        }
        if viewModel.canReply, !message.isDeleted {
            menu.items.append(.action(ChatMessageMenu.Action(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] in
                self?.beginReply(to: id)
            }))
        }
        if !text.isEmpty {
            menu.items.append(.action(ChatMessageMenu.Action(title: "Copy", image: UIImage(systemName: "doc.on.doc")) {
                UIPasteboard.general.string = text
            }))
        }
        if let link = viewModel.link(toMessage: id) {
            menu.items.append(.action(ChatMessageMenu.Action(title: "Copy Link", image: UIImage(systemName: "link")) {
                UIPasteboard.general.url = link
            }))
        }
        // A message with a reminder offers Mark as Done in place of Remind Me.
        if let target = viewModel.reminderTarget, reminderDates[id] != nil {
            menu.items.append(.action(ChatMessageMenu.Action(title: "Mark as Done", image: UIImage(systemName: "checkmark.circle")) {
                ChatReminderStore.markDone(messageId: id, in: target)
            }))
        } else if let target = viewModel.reminderTarget, !message.isDeleted {
            var delays = ChatReminderStore.Delay.allCases.map { delay in
                ChatMessageMenu.Action(title: delay.title) { [weak self] in self?.remind(of: message, in: target, at: delay.dueDate()) }
            }
            delays.append(ChatMessageMenu.Action(title: "Custom…", image: UIImage(systemName: "calendar")) { [weak self] in
                self?.presentReminderDatePicker(for: message, in: target)
            })
            menu.items.append(.submenu(title: "Remind Me", image: UIImage(systemName: "alarm"), children: delays))
        }
        return menu.isEmpty ? nil : menu
    }

    /// A link to a message or member of this chat shows it here; app links (such as Apron links, relative ones
    /// against `linkBaseURL`) open in the app. Message text is untrusted, so otherwise only web and mail links open.
    private func openLink(_ url: URL) {
        switch viewModel.linkTarget(for: url) {
        case let .user(user):
            showProfile(ChatUser(id: user, name: nil, avatarURL: nil))
            return
        case let .message(message):
            Task { await viewModel.jump(to: message) }
            return
        case .chat:
            return
        case nil:
            break
        }
        guard !NotificationRouter.shared.open(url, contentServer: viewModel.linkBaseURL) else { return }
        guard ["http", "https", "mailto"].contains(url.scheme?.lowercased()) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Replies and reactions

    private func configureJumpToLatestButton() {
        let glass = jumpToLatestGlass
        jumpToLatestButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        jumpToLatestButton.tintColor = .label
        jumpToLatestButton.accessibilityLabel = "Jump to Latest"
        jumpToLatestButton.addAction(UIAction { [weak self] _ in
            Task { await self?.viewModel.jumpToLatest() }
        }, for: .primaryActionTriggered)
        glass.contentView.addSubview(jumpToLatestButton)
        jumpToLatestButton.pinToEdges(of: glass.contentView)
        // Unread count badge on the down arrow, like Telegram.
        // A capsule sized by its padded label keeps the count centered at any width.
        unreadBadgeLabel.font = UIFont.systemFont(ofSize: 12, weight: .bold).monospacedDigits()
        unreadBadgeLabel.textColor = .white
        unreadBadgeLabel.textAlignment = .center
        unreadBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        unreadBadge.addSubview(unreadBadgeLabel)
        unreadBadge.backgroundColor = .systemBlue
        unreadBadge.layer.cornerRadius = 10
        unreadBadge.isHidden = true
        unreadBadge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            unreadBadgeLabel.centerYAnchor.constraint(equalTo: unreadBadge.centerYAnchor),
            unreadBadgeLabel.leadingAnchor.constraint(equalTo: unreadBadge.leadingAnchor, constant: 6),
            unreadBadgeLabel.trailingAnchor.constraint(equalTo: unreadBadge.trailingAnchor, constant: -6),
        ])
        glass.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: 40),
            glass.heightAnchor.constraint(equalToConstant: 40),
            glass.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            glass.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -10),
        ])
        view.addSubview(unreadBadge)
        NSLayoutConstraint.activate([
            unreadBadge.centerXAnchor.constraint(equalTo: glass.centerXAnchor),
            unreadBadge.centerYAnchor.constraint(equalTo: glass.topAnchor),
            unreadBadge.heightAnchor.constraint(equalToConstant: 20),
            unreadBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        glass.isHidden = true
        glass.alpha = 0
    }

    /// A heart over the jump-to-latest button, as in Telegram, while the user's messages have reactions they
    /// haven't seen; it scrolls to the oldest one, which counts as seen once on screen.
    private func configureUnseenReactionsButton() {
        let glass = unseenReactionsGlass
        unseenReactionsButton.setImage(UIImage(systemName: "heart", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        unseenReactionsButton.tintColor = .label
        unseenReactionsButton.accessibilityLabel = "Next Unseen Reaction"
        unseenReactionsButton.addAction(UIAction { [weak self] _ in
            Task { await self?.viewModel.jumpToNextUnseenReaction() }
        }, for: .primaryActionTriggered)
        glass.contentView.addSubview(unseenReactionsButton)
        unseenReactionsButton.pinToEdges(of: glass.contentView)
        unseenReactionsBadgeLabel.font = UIFont.systemFont(ofSize: 12, weight: .bold).monospacedDigits()
        unseenReactionsBadgeLabel.textColor = .white
        unseenReactionsBadgeLabel.textAlignment = .center
        unseenReactionsBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        unseenReactionsBadge.addSubview(unseenReactionsBadgeLabel)
        unseenReactionsBadge.backgroundColor = .systemBlue
        unseenReactionsBadge.layer.cornerRadius = 10
        unseenReactionsBadge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            unseenReactionsBadgeLabel.centerYAnchor.constraint(equalTo: unseenReactionsBadge.centerYAnchor),
            unseenReactionsBadgeLabel.leadingAnchor.constraint(equalTo: unseenReactionsBadge.leadingAnchor, constant: 6),
            unseenReactionsBadgeLabel.trailingAnchor.constraint(equalTo: unseenReactionsBadge.trailingAnchor, constant: -6),
        ])
        glass.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(glass)
        unseenReactionsAboveJump = glass.bottomAnchor.constraint(equalTo: jumpToLatestGlass.topAnchor, constant: -14)
        unseenReactionsInJumpPlace = glass.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -10)
        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: 40),
            glass.heightAnchor.constraint(equalToConstant: 40),
            glass.trailingAnchor.constraint(equalTo: jumpToLatestGlass.trailingAnchor),
            unseenReactionsInJumpPlace,
        ])
        view.addSubview(unseenReactionsBadge)
        NSLayoutConstraint.activate([
            unseenReactionsBadge.centerXAnchor.constraint(equalTo: glass.centerXAnchor),
            unseenReactionsBadge.centerYAnchor.constraint(equalTo: glass.topAnchor),
            unseenReactionsBadge.heightAnchor.constraint(equalToConstant: 20),
            unseenReactionsBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        glass.isHidden = true
        glass.alpha = 0
        unseenReactionsBadge.isHidden = true
    }

    private func updateUnseenReactionsButton() {
        let visible = unseenReactionCount > 0
        let glass = unseenReactionsGlass
        unseenReactionsBadge.isHidden = !visible
        guard glass.isHidden == visible else { return }
        if visible { glass.isHidden = false }
        UIView.animate(withDuration: 0.2, animations: {
            glass.alpha = visible ? 1 : 0
            glass.transform = visible ? .identity : CGAffineTransform(scaleX: 0.7, y: 0.7)
        }, completion: { _ in
            glass.isHidden = !visible
        })
    }

    /// "Name is typing…" in a small glass capsule over the list above the composer. It floats, so showing
    /// it never changes the list's insets.
    private func configureTypingIndicator() {
        typingLabel.font = .preferredFont(forTextStyle: .footnote)
        typingLabel.textColor = .secondaryLabel
        typingLabel.lineBreakMode = .byTruncatingTail
        let row = UIStackView(arrangedSubviews: [typingLabel])
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        typingView.contentView.addSubview(row)
        row.pinToEdges(of: typingView.contentView)
        typingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(typingView)
        NSLayoutConstraint.activate([
            typingView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            typingView.trailingAnchor.constraint(lessThanOrEqualTo: jumpToLatestGlass.leadingAnchor, constant: -10),
            typingView.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -10),
        ])
        typingView.isHidden = true
        typingView.alpha = 0
    }

    // MARK: - Mention suggestions

    /// Members matching the `@` word at the caret, in a glass card above the composer, like the typing capsule.
    private func configureMentionSuggestions() {
        mentionStack.axis = .vertical
        mentionStack.isLayoutMarginsRelativeArrangement = true
        mentionStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        mentionGlass.contentView.addSubview(mentionStack)
        mentionStack.pinToEdges(of: mentionGlass.contentView)
        mentionGlass.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mentionGlass)
        NSLayoutConstraint.activate([
            mentionGlass.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            mentionGlass.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            mentionGlass.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
        ])
        mentionGlass.isHidden = true
    }

    /// The word ending at the caret, if the caret is in one that starts with `prefix` and continues with only
    /// `characters`: its range including the prefix, and the text after it.
    private func wordQuery(prefix: String, characters: CharacterSet) -> (range: NSRange, query: String)? {
        let selection = textView.selectedRange
        guard selection.length == 0, textView.isFirstResponder else { return nil }
        let text = textView.text as NSString
        var start = selection.location
        while start > 0, let scalar = UnicodeScalar(text.character(at: start - 1)), !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            start -= 1
        }
        let range = NSRange(location: start, length: selection.location - start)
        let word = text.substring(with: range)
        guard word.hasPrefix(prefix), word.dropFirst().unicodeScalars.allSatisfy(characters.contains) else { return nil }
        return (range, String(word.dropFirst()))
    }

    private static let mentionCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.+:-")
    /// A custom emoji name (`ext:emoji`); a bare `:` offers every emoji, and a closing `:` ends the word, so a
    /// finished key suggests nothing.
    private static let emojiNameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-")

    /// Members for an `@` word, emoji for a `:` word, or places for a reference such as a `#` word, at the caret.
    private func updateMentionSuggestions() {
        var match = wordQuery(prefix: ":", characters: Self.emojiNameCharacters)
        let emojis = match.map { viewModel.emojiSuggestions(for: $0.query) } ?? []
        var users: [ChatUser] = []
        if emojis.isEmpty {
            match = wordQuery(prefix: "@", characters: Self.mentionCharacters)
            users = match.map { viewModel.mentionSuggestions(for: $0.query) } ?? []
        }
        var places: [ChatReferenceSuggestion] = []
        if emojis.isEmpty, users.isEmpty, let prefix = viewModel.referencePrefix {
            match = wordQuery(prefix: prefix, characters: Self.mentionCharacters)
            places = match.map { viewModel.referenceSuggestions(for: $0.query) } ?? []
        }
        let isEmpty = emojis.isEmpty && users.isEmpty && places.isEmpty
        mentionRange = isEmpty ? nil : match?.range
        let ids = emojis.map(\.id) + users.map { "@\($0.id)" } + places.map { "#\($0.reference)" }
        guard ids != shownSuggestionIds else { return }
        shownSuggestionIds = ids
        mentionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !emojis.isEmpty {
            mentionStack.addArrangedSubview(emojiStrip(for: emojis))
        }
        for user in users {
            mentionStack.addArrangedSubview(mentionRow(for: user))
        }
        for place in places {
            mentionStack.addArrangedSubview(referenceRow(for: place))
        }
        mentionGlass.isHidden = isEmpty
        // The card covers the typing capsule's spot; bring it back once the card goes.
        if isEmpty {
            updateTypingIndicator(viewModel.typingNames)
        } else {
            typingView.isHidden = true
            typingView.alpha = 0
        }
    }

    private func mentionRow(for user: ChatUser) -> UIView {
        let avatar = ChatAvatarView()
        let userName = DebugRedaction.name(user.name)
        avatar.configure(name: userName, color: ChatUserColor.color(for: user.id), url: viewModel.avatarURL(for: user))
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 28),
            avatar.heightAnchor.constraint(equalToConstant: 28),
        ])
        let name = UILabel()
        name.text = userName
        name.font = .preferredFont(forTextStyle: .subheadline)
        name.setContentHuggingPriority(.required, for: .horizontal)
        let userId = UILabel()
        userId.text = DebugRedaction.isEnabled ? "@Redacted" : "@\(user.id)"
        userId.font = .preferredFont(forTextStyle: .footnote)
        userId.textColor = .secondaryLabel
        userId.lineBreakMode = .byTruncatingMiddle
        let row = UIStackView(arrangedSubviews: [avatar, name, userId])
        row.spacing = 8
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        row.isAccessibilityElement = true
        row.accessibilityLabel = "\(userName), \(userId.text ?? "")"
        row.accessibilityTraits = .button
        row.addGestureRecognizer(ChatActionTapGesture { [weak self] in self?.insertMention(of: user) })
        return row
    }

    /// A place for a reference word, like a member row: its kind's icon, its name and the reference it inserts.
    private func referenceRow(for place: ChatReferenceSuggestion) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: place.systemImage))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
        ])
        let prefix = viewModel.referencePrefix ?? ""
        let name = UILabel()
        name.text = place.title
        name.font = .preferredFont(forTextStyle: .subheadline)
        name.setContentHuggingPriority(.required, for: .horizontal)
        let reference = UILabel()
        reference.text = "\(prefix)\(place.reference)"
        reference.font = .preferredFont(forTextStyle: .footnote)
        reference.textColor = .secondaryLabel
        reference.lineBreakMode = .byTruncatingMiddle
        let row = UIStackView(arrangedSubviews: [icon, name, reference])
        row.spacing = 8
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        row.isAccessibilityElement = true
        row.accessibilityLabel = "\(place.title), \(reference.text ?? "")"
        row.accessibilityTraits = .button
        row.addGestureRecognizer(ChatActionTapGesture { [weak self] in self?.insertSuggestion("\(prefix)\(place.reference)") })
        return row
    }

    /// The emoji matching a `:` word, in a row that scrolls sideways; tapping one inserts it, or a custom emoji's key.
    private func emojiStrip(for emojis: [ChatEmojiSuggestion]) -> UIView {
        let row = UIStackView()
        row.spacing = 4
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        for emoji in emojis {
            var configuration = UIButton.Configuration.plain()
            switch emoji {
            case let .custom(custom):
                configuration.image = ChatCustomEmojiImages.shared.image(for: custom, height: 32) { [weak self] in
                    // Rebuilt with the image once it loads.
                    self?.shownSuggestionIds = []
                    self?.updateMentionSuggestions()
                }
            case let .unicode(character, _):
                var title = AttributedString(character)
                title.font = UIFont.systemFont(ofSize: 28)
                configuration.attributedTitle = title
            }
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                self?.insertSuggestion(emoji.text)
            })
            button.accessibilityLabel = emoji.label
            // Long press shows the key or name, as the strip has no room for them.
            button.toolTip = emoji.label
            row.addArrangedSubview(button)
        }
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 44),
        ])
        return scroll
    }

    /// Replaces the `@` word with the user's `@user_id` and a space; messages then show it by name.
    private func insertMention(of user: ChatUser) {
        insertSuggestion("@\(user.id)")
    }

    /// Replaces the word being completed with `text` and a space, which also keeps a key apart from a mention
    /// after it (a mention can contain `:`).
    private func insertSuggestion(_ text: String) {
        guard let range = mentionRange else { return }
        let replacement = "\(text) "
        textView.text = (textView.text as NSString).replacingCharacters(in: range, with: replacement)
        textView.selectedRange = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        textViewDidChange(textView)
    }

    private func updateTypingIndicator(_ names: [String]) {
        let names = names.map { DebugRedaction.name($0) }
        let text: String? = switch names.count {
        case 0: nil
        case 1: "\(names[0]) is typing…"
        case 2: "\(names[0]) and \(names[1]) are typing…"
        default: "\(names[0]) and \(names.count - 1) others are typing…"
        }
        if let text {
            typingLabel.text = text
        }
        // Mention suggestions sit where the capsule would.
        let visible = text != nil && mentionGlass.isHidden
        guard typingView.isHidden == visible else { return }
        if visible { typingView.isHidden = false }
        UIView.animate(withDuration: 0.2, animations: {
            self.typingView.alpha = visible ? 1 : 0
        }, completion: { _ in
            self.typingView.isHidden = self.typingView.alpha == 0
        })
    }

    private func configureReplyPreview() {
        let bar = UIView()
        bar.backgroundColor = .link
        bar.layer.cornerRadius = 1.5
        bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
        replyPreviewName.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        replyPreviewName.textColor = .link
        replyPreviewText.font = .preferredFont(forTextStyle: .footnote)
        replyPreviewText.textColor = .secondaryLabel
        let labels = UIStackView(arrangedSubviews: [replyPreviewName, replyPreviewText])
        labels.axis = .vertical
        labels.spacing = 1
        let cancel = UIButton(type: .system)
        cancel.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        cancel.tintColor = .secondaryLabel
        cancel.accessibilityLabel = "Cancel Reply"
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        cancel.addAction(UIAction { [weak self] _ in self?.viewModel.cancelReply() }, for: .primaryActionTriggered)
        replyPreview.addArrangedSubview(bar)
        replyPreview.addArrangedSubview(labels)
        replyPreview.addArrangedSubview(cancel)
        replyPreview.spacing = 8
        replyPreview.alignment = .fill
        replyPreview.isLayoutMarginsRelativeArrangement = true
        replyPreview.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 4)
        replyPreview.isHidden = true
    }

    private func presentReminderDatePicker(for message: ChatMessage, in target: ChatReminderTarget) {
        let picker = UIHostingController(rootView: ChatReminderDatePicker(
            onSet: { [weak self] date in
                self?.dismiss(animated: true)
                self?.remind(of: message, in: target, at: date)
            },
            onCancel: { [weak self] in self?.dismiss(animated: true) },
        ))
        picker.sheetPresentationController?.detents = [.large()]
        present(picker, animated: true)
    }

    private func remind(of message: ChatMessage, in target: ChatReminderTarget, at dueDate: Date) {
        Task {
            do {
                _ = try await ChatReminderStore.schedule(message, in: target, dueDate: dueDate)
            } catch {
                let alert = UIAlertController(title: "Reminder Not Set", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func beginReply(to id: String) {
        guard let message = messagesById[id] else { return }
        viewModel.startReply(to: message)
        textView.becomeFirstResponder()
    }

    /// Reconfigures messages whose reminder changed, and those with one, whose "Due in" moves on.
    private func reloadReminders() {
        guard let target = viewModel.reminderTarget else { return }
        let old = reminderDates
        reminderDates = ChatReminderStore.dueDates(in: target)
        var snapshot = dataSource.snapshot()
        let items = Set(old.keys).union(reminderDates.keys)
            .map { Item.message(itemKey(for: $0)) }
            .filter { snapshot.itemIdentifiers.contains($0) }
        guard !items.isEmpty else { return }
        snapshot.reconfigureItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func revealSpoilers(of id: String) {
        guard revealedSpoilers.insert(id).inserted else { return }
        var snapshot = dataSource.snapshot()
        let item = Item.message(itemKey(for: id))
        guard snapshot.itemIdentifiers.contains(item) else { return }
        snapshot.reconfigureItems([item])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func toggleEmbed(_ index: Int, of id: String) {
        let key = "\(id)|\(index)"
        let isExpanding = expandedEmbeds.remove(key) == nil
        if isExpanding {
            expandedEmbeds.insert(key)
        }
        var snapshot = dataSource.snapshot()
        let item = Item.message(itemKey(for: id))
        guard snapshot.itemIdentifiers.contains(item) else { return }
        snapshot.reconfigureItems([item])
        dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
            // An opened message near the bottom grows under the composer; bring its end into view.
            guard isExpanding, let self, let indexPath = dataSource.indexPath(for: item),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
            else { return }
            let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
            if frame.maxY > visibleBottom {
                collectionView.scrollToItem(at: indexPath, at: .bottom, animated: true)
            }
        }
    }

    private func toggleReaction(_ emoji: String, on id: String) {
        guard messagesById[id]?.isNotice == false else { return }
        reactionHaptic.selectionChanged()
        Task { await viewModel.toggleReaction(emoji, on: id) }
    }

    private func presentReactionPicker(for id: String) {
        let picker = ChatReactionPickerViewController(
            selected: Set(viewModel.yourEmojis(on: id)),
            customEmojis: viewModel.customEmojis.values.filter { !$0.isHidden },
        ) { [weak self] emoji in
            self?.toggleReaction(emoji, on: id)
        }
        if let sheet = picker.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(picker, animated: true)
    }

    private static let reactionTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// Long press on a reaction chip: who reacted with that emoji, oldest first, each with when.
    private func reactionMenu(pressed emoji: String, on id: String) -> UIMenu? {
        guard messagesById[id]?.isNotice == false else { return nil }
        let rows = viewModel.reactors(of: emoji, on: id).map { reactor in
            let action = UIAction(title: reactor.isYou ? "You" : DebugRedaction.name(reactor.user.name), image: reactorImage(for: reactor.user)) { _ in }
            action.subtitle = reactor.date.map(Self.reactionTimeFormatter.string(from:))
            return action
        }
        return rows.isEmpty ? nil : UIMenu(children: rows)
    }

    /// Loads the avatars of a shown message's reactors, so the chip's long-press list has them. The chat itself
    /// only loads avatars beside incoming bubbles, which never includes your own.
    private func prefetchReactorAvatars(on message: ChatMessage) {
        guard let totals = reactionTotals[message.id] else { return }
        let urls = totals.flatMap { viewModel.reactors(of: $0.emoji, on: message.id) }.compactMap { viewModel.avatarURL(for: $0.user) }
        for url in urls where StoryImageCache.shared.image(for: url) == nil && avatarPrefetches.insert(url).inserted {
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else {
                    avatarPrefetches.remove(url)
                    return
                }
                StoryImageCache.shared.setImage(image, for: url)
            }
        }
    }

    /// The reactor's avatar when it is already loaded, otherwise initials on their color, like the chat's avatars.
    private func reactorImage(for user: ChatUser) -> UIImage {
        let size = CGSize(width: 28, height: 28)
        let photo = viewModel.avatarURL(for: user).flatMap { StoryImageCache.shared.image(for: $0) }
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(ovalIn: rect).addClip()
            if let photo {
                let scale = max(size.width / photo.size.width, size.height / photo.size.height)
                let drawn = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
                photo.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
                return
            }
            ChatUserColor.color(for: user.id).setFill()
            UIRectFill(rect)
            let initials = DebugRedaction.name(user.name).split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased() as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: UIColor.white]
            let textSize = initials.size(withAttributes: attributes)
            initials.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// Reconfigures only the messages whose totals changed.
    private func applyReactionTotals(_ totals: [String: [ChatReaction]]) {
        if isShowingContextMenu {
            pendingReactionTotals = totals
            return
        }
        let changedIds = Set(totals.keys).union(reactionTotals.keys).filter { totals[$0] != reactionTotals[$0] }
        reactionTotals = totals
        guard !changedIds.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        let present = Set(items(in: .messages, of: snapshot))
        let changed = changedIds.map { Item.message(itemKey(for: $0)) }.filter(present.contains)
        guard !changed.isEmpty else { return }
        snapshot.reconfigureItems(changed)
        applyKeepingBottom(snapshot, animated: hasScrolledInitially)
    }
}

/// Floating glass backgrounds: Liquid Glass on iOS 26, a thin material before it.
enum ChatGlass {
    static func make(cornerRadius: CGFloat) -> UIVisualEffectView {
        let view: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect()
            effect.isInteractive = true
            view = UIVisualEffectView(effect: effect)
            view.cornerConfiguration = .uniformCorners(radius: .fixed(cornerRadius))
        } else {
            view = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            view.layer.cornerRadius = cornerRadius
            view.layer.cornerCurve = .continuous
            view.clipsToBounds = true
        }
        return view
    }
}

enum ChatImageEncoding {
    /// Downscales to at most 2048pt on the long edge and encodes as JPEG, which every upload server accepts.
    static func jpeg(from image: UIImage, maxDimension: CGFloat = 2048) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image.jpegData(compressionQuality: 0.85) }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}

extension UIView {
    func pinToEdges(of container: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: container.topAnchor),
            bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leadingAnchor.constraint(equalTo: container.leadingAnchor),
            trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }

    func monospacedDigits() -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
            UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
        ]]])
        return UIFont(descriptor: descriptor, size: 0)
    }

    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
