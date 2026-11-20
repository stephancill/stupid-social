import AVFoundation
import Combine
import Photos
import StupidChatKit
import StupidSocialCore
import SwiftUI
import UIKit

/// One photo or video of a post in the viewer, which pages through every one of every post it was given.
struct MediaViewerPage: Hashable {
    /// The post's counts and actions in the caption, with `engaging`; nil for a post the app can't act on.
    let post: PostThread.Post?
    /// The post the page is one of: pages of the same post share it, and the viewer opens at its first.
    let itemId: String
    let index: Int
    let count: Int
    let media: ProfileTimelineItem.Media
    let caption: String?
    /// The post on its network, shared from the read-only counts when there's no action bar to share it from.
    var link: URL?
    /// Replies, reposts and likes shown read-only for a post the app can't act on (no `post` and `engaging`).
    var counts: Counts?

    struct Counts: Hashable {
        var replies: Int?
        var reposts: Int?
        var likes: Int?
    }

    var key: String {
        "\(itemId)#\(index)"
    }

    /// Every photo and video of one post, in order.
    static func pages(itemId: String, post: PostThread.Post?, media: [ProfileTimelineItem.Media], caption: String?, link: URL? = nil, counts: Counts? = nil) -> [MediaViewerPage] {
        let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        return media.enumerated().map { index, item in
            MediaViewerPage(post: post, itemId: itemId, index: index, count: media.count, media: item, caption: caption?.isEmpty == false ? caption : nil, link: link, counts: counts)
        }
    }
}

extension ProfileTimelineItem {
    /// Its photos and videos, or the grid's thumbnail when only a link card has an image.
    var mediaPages: [MediaViewerPage] {
        let shown = !media.isEmpty ? media : thumbnailURL.map { [ProfileTimelineItem.Media(imageURL: $0)] } ?? []
        return MediaViewerPage.pages(itemId: post.target.id, post: post, media: shown, caption: post.target.text)
    }
}

/// Opens photos and videos full screen from anywhere: a profile's grid, a post's media, a post in a chat.
@MainActor
enum MediaViewer {
    /// Opens the media grid of `kind` full screen at the post's first photo or video, with each post's counts and
    /// actions when `engaging` is given. Paging near the end loads the grid's next page.
    static func present(timeline: ProfileTimelineViewModel, kind: ProfileTimelineKind, itemId: String, network: SocialNetwork, engaging: (any PostEngaging)?) {
        let pages = Self.pages(timeline.timeline(kind).items)
        present(
            pages: pages,
            startKey: pages.first { $0.itemId == itemId }?.key,
            network: network,
            engaging: engaging,
            updates: timeline.$timelines
                .map { [kind] in Self.pages($0[kind]?.items ?? []) }
                .eraseToAnyPublisher(),
            loadMore: { [weak timeline] in timeline?.loadMore(kind) },
        )
    }

    /// Opens `pages` at the one with `startKey` (else the first). `updates` brings later pages, such as a grid's
    /// next page, which `loadMore` asks for as the viewer nears the end.
    static func present(
        pages: [MediaViewerPage],
        startKey: String? = nil,
        network: SocialNetwork,
        engaging: (any PostEngaging)?,
        updates: AnyPublisher<[MediaViewerPage], Never>? = nil,
        loadMore: (() -> Void)? = nil,
    ) {
        guard !pages.isEmpty else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard var presenter = window?.rootViewController else { return }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        let caption = MediaViewerCaptionModel(network: network, engaging: engaging)
        let viewer = MediaViewerController(pages: pages, startKey: startKey, updates: updates, loadMore: loadMore, caption: caption)
        presenter.present(viewer, animated: true)
    }

    static func pages(_ items: [ProfileTimelineItem]) -> [MediaViewerPage] {
        items.filter { $0.thumbnailURL != nil }.flatMap(\.mediaPages)
    }

    /// A post drawn in a chat (`ChatKit.openPostMedia`), at the photo or video tapped. An X post gets its counts and
    /// actions through `xEngaging`; others link to the post on their network.
    static func present(chatPost post: ChatPost, at index: Int, xEngaging: (any PostEngaging)?) {
        let network = post.network?.socialNetwork ?? .x
        let media = post.media.compactMap { embed -> ProfileTimelineItem.Media? in
            switch embed {
            case let .image(url, aspectRatio, alt, _, _):
                ProfileTimelineItem.Media(imageURL: url, aspectRatio: aspectRatio, altText: alt)
            case let .video(url, posterURL, aspectRatio, _, isGIF):
                posterURL.map { ProfileTimelineItem.Media(imageURL: $0, videoURL: url, isGIF: isGIF, aspectRatio: aspectRatio) }
            default:
                nil
            }
        }
        var thread: PostThread.Post?
        if network == .x, xEngaging != nil, let link = post.link, let id = XPost.id(in: link) {
            let handle = post.authorHandle.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }
            let author = NotificationActor(id: handle ?? post.authorName, network: .x, username: handle, displayName: post.authorName, avatarURL: post.authorAvatarURL, isVerified: post.isVerified)
            thread = PostThread.Post(target: NotificationTarget(id: id, text: post.text, url: link, author: author, postedAt: post.date), engagement: nil)
        }
        let pages = MediaViewerPage.pages(
            itemId: thread?.target.id ?? post.link?.absoluteString ?? post.authorName,
            post: thread,
            media: media,
            caption: post.text,
            link: post.link,
            counts: post.counts.map { MediaViewerPage.Counts(replies: $0.replies, reposts: $0.reposts, likes: $0.likes) },
        )
        present(pages: pages, startKey: pages.indices.contains(index) ? pages[index].key : nil, network: network, engaging: thread == nil ? nil : xEngaging)
    }
}

/// Full-screen media: swipe sideways through every photo and video, pinch or double-tap to zoom, tap to show or hide
/// the post's text and the buttons, swipe up or down to close. Paging near the end asks for more.
private enum MediaSaveError: Error {
    case denied
}

final class MediaViewerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    private var pages: [MediaViewerPage]
    private let updates: AnyPublisher<[MediaViewerPage], Never>?
    private let loadMore: (() -> Void)?
    private var currentKey: String

    private let backdrop = UIView()
    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 12])
    private let closeButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    /// A video's controls over the caption, as X lays them out: play or pause beside a thin scrubber across the
    /// screen, the sound button above its end, and the time only while scrubbing.
    private let scrubBar = UIStackView()
    private let playButton = UIButton(type: .system)
    private let scrubber = UISlider()
    private let muteButton = UIButton(type: .system)
    private let timeLabel = InsetLabel()
    /// Sound stays off or on across the videos paged through.
    private var isMuted = false
    private var timeObserver: Any?
    private weak var observedPlayer: AVPlayer?
    private var isScrubbing = false
    private var wasPlayingBeforeScrub = false
    private var isSeeking = false
    private var pendingSeek: CMTime?
    private let caption: MediaViewerCaptionModel
    private let captionController: UIHostingController<MediaViewerCaptionView>
    private var captionView: UIView {
        captionController.view
    }

    private var chromeHidden = false
    private var updatesObservation: AnyCancellable?
    /// Controllers for the current page and those beside it, by page key.
    private var prepared: [String: MediaViewerPageController] = [:]

    private static let dismissDistance: CGFloat = 120
    private static let dismissVelocity: CGFloat = 800
    /// Pages from the end at which the grid's next page loads.
    private static let loadMoreDistance = 4
    /// Pages readied on each side of the current one: more ahead, the way people swipe.
    private static let preparedAhead = 2
    private static let preparedBehind = 1
    /// Pages past the readied ones whose photos (or video posters) are downloaded ahead.
    private static let warmedAhead = 4

    init(pages: [MediaViewerPage], startKey: String?, updates: AnyPublisher<[MediaViewerPage], Never>?, loadMore: (() -> Void)?, caption: MediaViewerCaptionModel) {
        self.pages = pages
        self.updates = updates
        self.loadMore = loadMore
        self.caption = caption
        captionController = UIHostingController(rootView: MediaViewerCaptionView(model: caption))
        currentKey = startKey.flatMap { key in pages.contains { $0.key == key } ? key : nil } ?? pages.first?.key ?? ""
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        modalPresentationCapturesStatusBarAppearance = true
        overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool {
        chromeHidden
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            observeTime(of: nil)
        }
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        chromeHidden
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        backdrop.backgroundColor = .black
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)

        pager.dataSource = self
        pager.delegate = self
        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        if let page = pages.first(where: { $0.key == currentKey }) {
            pager.setViewControllers([pageController(page)], direction: .forward, animated: false)
        }

        setUpCaption()
        configure(closeButton, systemImage: "xmark", label: "Close", action: #selector(close))
        configure(moreButton, systemImage: "ellipsis", label: "More", action: nil)
        moreButton.showsMenuAsPrimaryAction = true
        setUpScrubBar()
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            moreButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            moreButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        updatesObservation = updates?
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] pages in self?.update(pages) }

        showCurrentPage()
    }

    // MARK: Pages

    private var currentIndex: Int? {
        pages.firstIndex { $0.key == currentKey }
    }

    private var currentPageController: MediaViewerPageController? {
        pager.viewControllers?.first as? MediaViewerPageController
    }

    /// The page's controller: the one prepared ahead when there is one, so its photo and video are already loading.
    private func pageController(_ page: MediaViewerPage) -> MediaViewerPageController {
        if let prepared = prepared[page.key] {
            return prepared
        }
        let controller = MediaViewerPageController(page: page)
        controller.onTap = { [weak self] in self?.setChromeHidden(!(self?.chromeHidden ?? false)) }
        controller.onPlaybackChange = { [weak self] in self?.updatePlayButton() }
        prepared[page.key] = controller
        return controller
    }

    /// Readies the pages beside the current one (loading their photos, buffering their videos), so swiping to
    /// them shows them at once, and warms the cache with the photos a few pages further on. Controllers further
    /// away are let go, so only a few players hold video at a time.
    private func prepareNeighbors() {
        guard let index = currentIndex else { return }
        let kept = pages[max(0, index - Self.preparedBehind) ... min(pages.count - 1, index + Self.preparedAhead)]
        let keys = Set(kept.map(\.key))
        prepared = prepared.filter { keys.contains($0.key) || $0.value === currentPageController }
        for page in kept {
            pageController(page).loadViewIfNeeded()
        }
        let warmed = pages.dropFirst(index + Self.preparedAhead + 1).prefix(Self.warmedAhead)
        for page in warmed {
            ImageCache.shared.preload(url: page.media.imageURL)
        }
    }

    func pageViewController(_: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let key = (viewController as? MediaViewerPageController)?.page.key,
              let index = pages.firstIndex(where: { $0.key == key }), index > 0
        else { return nil }
        return pageController(pages[index - 1])
    }

    func pageViewController(_: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let key = (viewController as? MediaViewerPageController)?.page.key,
              let index = pages.firstIndex(where: { $0.key == key }), index + 1 < pages.count
        else { return nil }
        return pageController(pages[index + 1])
    }

    func pageViewController(_: UIPageViewController, didFinishAnimating _: Bool, previousViewControllers _: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let page = currentPageController?.page else { return }
        currentKey = page.key
        showCurrentPage()
    }

    private func showCurrentPage() {
        caption.page = currentPageController?.page
        observeTime(of: currentPageController?.player)
        if currentPageController?.page.media.isGIF == false {
            currentPageController?.player?.isMuted = isMuted
        }
        updateMoreMenu()
        updatePlayButton()
        if let index = currentIndex, index + Self.loadMoreDistance >= pages.count {
            loadMore?()
        }
        prepareNeighbors()
    }

    /// A later page of the grid adds pages; the pager asks again for the page after the current one, which it
    /// last heard was the end.
    private func update(_ pages: [MediaViewerPage]) {
        let wasLast = currentIndex == self.pages.count - 1
        self.pages = pages
        guard let current = currentPageController, pages.contains(where: { $0.key == currentKey }) else { return }
        if wasLast, currentIndex != pages.count - 1 {
            pager.setViewControllers([current], direction: .forward, animated: false)
        }
        prepareNeighbors()
    }

    // MARK: Chrome

    private func setUpCaption() {
        caption.onTap = { [weak self] in self?.setChromeHidden(true) }
        captionController.sizingOptions = .intrinsicContentSize
        captionController.view.backgroundColor = .clear
        addChild(captionController)
        captionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captionView)
        NSLayoutConstraint.activate([
            captionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            captionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            captionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        captionController.didMove(toParent: self)
    }

    private func configure(_ button: UIButton, systemImage: String, label: String, action: Selector?) {
        var configuration: UIButton.Configuration = if #available(iOS 26.0, *) {
            .glass()
        } else {
            .gray()
        }
        configuration.image = UIImage(systemName: systemImage)
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .large
        button.configuration = configuration
        button.accessibilityLabel = label
        if let action {
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
    }

    private var chromeViews: [UIView] {
        [closeButton, moreButton, captionView] + (showsScrubBar ? [scrubBar, muteButton] : [])
    }

    private func setChromeHidden(_ hidden: Bool) {
        chromeHidden = hidden
        UIView.animate(withDuration: 0.2) {
            self.updateChromeAlpha()
            self.setNeedsStatusBarAppearanceUpdate()
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }

    private func updateChromeAlpha() {
        closeButton.alpha = chromeHidden ? 0 : 1
        captionView.alpha = chromeHidden ? 0 : 1
        moreButton.alpha = chromeHidden ? 0 : 1
        scrubBar.alpha = chromeHidden || !showsScrubBar ? 0 : 1
        muteButton.alpha = scrubBar.alpha
    }

    private func updatePlayButton() {
        let isPlaying = currentPageController?.isPlaying ?? false
        playButton.configuration?.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
        playButton.accessibilityLabel = isPlaying ? "Pause" : "Play"
        playButton.isEnabled = currentPageController?.isVideo == true
        updateChromeAlpha()
    }

    @objc private func togglePlayback() {
        currentPageController?.togglePlayback()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: Scrubbing

    /// GIFs loop like photos, with no controls.
    private var showsScrubBar: Bool {
        currentPageController?.isVideo == true && currentPageController?.page.media.isGIF != true
    }

    private func setUpScrubBar() {
        var play = UIButton.Configuration.plain()
        play.image = UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
        play.baseForegroundColor = .white
        play.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)
        playButton.configuration = play
        playButton.accessibilityLabel = "Pause"
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        playButton.setContentHuggingPriority(.required, for: .horizontal)

        scrubber.minimumTrackTintColor = .white
        scrubber.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        scrubber.setThumbImage(Self.dot(diameter: 8), for: .normal)
        scrubber.setThumbImage(Self.dot(diameter: 18), for: .highlighted)
        scrubber.accessibilityLabel = "Playback position"
        scrubber.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        scrubber.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        scrubber.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        scrubBar.addArrangedSubview(playButton)
        scrubBar.addArrangedSubview(scrubber)
        scrubBar.axis = .horizontal
        scrubBar.alignment = .center
        scrubBar.spacing = 6
        scrubBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrubBar)

        var sound = UIButton.Configuration.filled()
        sound.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        sound.baseForegroundColor = .white
        sound.cornerStyle = .capsule
        sound.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        muteButton.configuration = sound
        muteButton.addTarget(self, action: #selector(toggleMuted), for: .touchUpInside)
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(muteButton)
        updateMuteButton()

        timeLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        timeLabel.layer.cornerRadius = 14
        timeLabel.layer.masksToBounds = true
        timeLabel.alpha = 0
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timeLabel)

        NSLayoutConstraint.activate([
            scrubBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            scrubBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            scrubBar.bottomAnchor.constraint(equalTo: captionView.topAnchor, constant: 30),
            muteButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            muteButton.bottomAnchor.constraint(equalTo: scrubBar.topAnchor, constant: -12),
            timeLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            timeLabel.bottomAnchor.constraint(equalTo: scrubBar.topAnchor, constant: -16),
        ])
    }

    /// The scrubber's knob: a small dot, larger while held.
    private static func dot(diameter: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter)).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        }
    }

    @objc private func toggleMuted() {
        isMuted.toggle()
        currentPageController?.player?.isMuted = isMuted
        updateMuteButton()
    }

    private func updateMuteButton() {
        muteButton.configuration?.image = UIImage(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        muteButton.accessibilityLabel = isMuted ? "Unmute" : "Mute"
    }

    /// Follows the shown page's player four times a second, moving the scrubber unless the user holds it.
    private func observeTime(of player: AVPlayer?) {
        if let timeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        observedPlayer = player
        pendingSeek = nil
        isScrubbing = false
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.showTime(time) }
        }
        showTime(player.currentTime())
    }

    private var duration: Double? {
        guard let seconds = observedPlayer?.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private func showTime(_ time: CMTime) {
        let elapsed = max(0, time.seconds.isFinite ? time.seconds : 0)
        let total = duration
        scrubber.isEnabled = total != nil
        if !isScrubbing {
            scrubber.value = total.map { Float(min(elapsed / $0, 1)) } ?? 0
        }
        scrubber.accessibilityValue = "\(Self.clock(elapsed)) of \(Self.clock(total ?? elapsed))"
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return whole >= 3600
            ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
    }

    @objc private func scrubBegan() {
        guard let player = observedPlayer else { return }
        isScrubbing = true
        wasPlayingBeforeScrub = player.rate > 0
        player.pause()
        if let duration {
            timeLabel.text = "\(Self.clock(player.currentTime().seconds)) / \(Self.clock(duration))"
        }
        UIView.animate(withDuration: 0.15) { self.timeLabel.alpha = 1 }
    }

    @objc private func scrubChanged() {
        guard let duration else { return }
        let target = CMTime(seconds: Double(scrubber.value) * duration, preferredTimescale: 600)
        timeLabel.text = "\(Self.clock(target.seconds)) / \(Self.clock(duration))"
        seek(to: target)
    }

    @objc private func scrubEnded() {
        isScrubbing = false
        UIView.animate(withDuration: 0.2) { self.timeLabel.alpha = 0 }
        if wasPlayingBeforeScrub {
            observedPlayer?.play()
        }
        updatePlayButton()
    }

    /// Exact seeks, one at a time: while one runs only the newest position waits, so dragging stays smooth.
    private func seek(to time: CMTime) {
        guard let player = observedPlayer else { return }
        guard !isSeeking else {
            pendingSeek = time
            return
        }
        isSeeking = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isSeeking = false
                if let next = pendingSeek {
                    pendingSeek = nil
                    seek(to: next)
                }
            }
        }
    }

    // MARK: Saving

    /// Saves the shown photo, or the video as its MP4: into Photos on an iPhone or iPad, into Downloads on a Mac.
    private func updateMoreMenu() {
        guard let page = currentPageController?.page else {
            moreButton.menu = nil
            return
        }
        let onMac = ProcessInfo.processInfo.isiOSAppOnMac
        let save = UIAction(
            title: onMac ? "Save to Downloads" : "Save to Photos",
            image: UIImage(systemName: onMac ? "arrow.down.circle" : "photo.on.rectangle"),
        ) { [weak self] _ in
            self?.save(page, toPhotos: !onMac)
        }
        moreButton.menu = UIMenu(children: [save])
    }

    private func save(_ page: MediaViewerPage, toPhotos: Bool) {
        let isVideo = page.media.videoURL != nil
        setSaving(true)
        Task {
            defer { setSaving(false) }
            do {
                let file = try await MediaDownloads.file(
                    for: page.media.videoURL ?? page.media.imageURL,
                    name: "\(caption.network.rawValue)-\(Self.fileId(page.itemId))-\(page.index + 1)",
                )
                if toPhotos {
                    guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
                        throw MediaSaveError.denied
                    }
                    try await Self.addToPhotos(file, isVideo: isVideo)
                } else {
                    _ = try await ChatDownloads.save(file, from: self)
                }
                showSaved()
            } catch is CancellationError {
                // The user declined to choose the Downloads folder.
            } catch {
                let message = (error as? MediaSaveError) == .denied
                    ? "Allow stupid social to add photos in Settings to save \(isVideo ? "videos" : "photos")."
                    : error.localizedDescription
                let alert = UIAlertController(title: "Couldn't Save \(isVideo ? "Video" : "Photo")", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    /// The menu button shows a check for a moment once the file is saved.
    private func showSaved() {
        moreButton.configuration?.image = UIImage(systemName: "checkmark")
        moreButton.accessibilityLabel = "Saved"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.moreButton.configuration?.image = UIImage(systemName: "ellipsis")
            self?.moreButton.accessibilityLabel = "More"
        }
    }

    /// A post's id, or for a post known by its link (a chat's Bluesky or Instagram post) the link's last part.
    static func fileId(_ itemId: String) -> String {
        guard itemId.contains("://"), let last = URL(string: itemId)?.pathComponents.last(where: { $0 != "/" }) else { return itemId }
        return last
    }

    /// Photos runs the change block on its own queue, so it must not inherit the controller's main-actor isolation.
    private nonisolated static func addToPhotos(_ file: URL, isVideo: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
        }
    }

    /// The menu button spins while a file downloads, at its own size.
    private func setSaving(_ saving: Bool) {
        moreButton.configuration?.showsActivityIndicator = saving
        moreButton.isEnabled = !saving
    }

    // MARK: Swipe to dismiss

    /// Only a mostly vertical drag on media that isn't zoomed in closes the viewer; sideways drags page.
    /// Drags on the scrubber and the buttons are theirs, not the start of a swipe to close.
    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        ![scrubBar, muteButton, moreButton, closeButton].contains { touch.view?.isDescendant(of: $0) == true }
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return currentPageController?.isZoomed != true && abs(velocity.y) > abs(velocity.x)
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view).y
        switch pan.state {
        case .began:
            for chrome in chromeViews {
                chrome.alpha = 0
            }
        case .changed:
            pager.view.transform = CGAffineTransform(translationX: 0, y: translation)
            backdrop.alpha = 1 - min(abs(translation) / (view.bounds.height / 2), 1) * 0.8
        case .ended, .cancelled:
            let velocity = pan.velocity(in: view).y
            if pan.state == .ended, abs(translation) > Self.dismissDistance || abs(velocity) > Self.dismissVelocity {
                let direction: CGFloat = (abs(velocity) > Self.dismissVelocity ? velocity : translation) < 0 ? -1 : 1
                UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
                    self.pager.view.transform = CGAffineTransform(translationX: 0, y: direction * self.view.bounds.height)
                    self.backdrop.alpha = 0
                } completion: { _ in
                    self.dismiss(animated: false)
                }
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    self.pager.view.transform = .identity
                    self.backdrop.alpha = 1
                    self.updateChromeAlpha()
                }
            }
        default:
            break
        }
    }
}

/// One photo or video, zoomable: pinch or double-tap to zoom, drag to pan a zoomed one. A video plays on its own
/// page and loops; a GIF plays muted.
final class MediaViewerPageController: UIViewController, UIScrollViewDelegate {
    let page: MediaViewerPage
    var onTap: (() -> Void)?
    var onPlaybackChange: (() -> Void)?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var loadTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var readyObservation: NSKeyValueObservation?
    private var hasPrerolled = false
    private var isVisible = false

    init(page: MediaViewerPage) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
    }

    var isVideo: Bool {
        page.media.videoURL != nil
    }

    var isPlaying: Bool {
        (player?.rate ?? 0) > 0
    }

    var isZoomed: Bool {
        scrollView.zoomScale > scrollView.minimumZoomScale
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        scrollView.addSubview(contentView)
        imageView.contentMode = .scaleAspectFit
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        contentView.isAccessibilityElement = true
        contentView.accessibilityLabel = page.media.altText ?? (isVideo ? "Video" : "Image")
        contentView.accessibilityTraits = .image

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(tap)

        loadImage()
        if let videoURL = page.media.videoURL {
            setUpPlayer(videoURL)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        player?.play()
        onPlaybackChange?()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        player?.pause()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !isZoomed {
            layoutContent()
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        onPlaybackChange?()
    }

    // MARK: Media

    /// The photo, or a video's poster until its first frame. The grid's smaller thumbnail shows while a
    /// larger photo loads.
    private func loadImage() {
        let url = page.media.imageURL
        if let cached = ImageCache.shared.image(for: url) {
            imageView.image = cached
            return
        }
        if let thumbnail = ImageCache.shared.image(for: url.removingQuery) {
            imageView.image = thumbnail
        } else if !isVideo {
            spinner.startAnimating()
        }
        loadTask = Task { [weak self] in
            let image = await ImageCache.shared.load(url: url)
            guard let self, !Task.isCancelled else { return }
            spinner.stopAnimating()
            guard let image else { return }
            imageView.image = image
            if !isZoomed {
                layoutContent()
            }
        }
    }

    private func setUpPlayer(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = page.media.isGIF
        looper = AVPlayerLooper(player: player, templateItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        contentView.layer.addSublayer(layer)
        playerLayer = layer
        self.player = player
        statusObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.onPlaybackChange?() }
        }
        readyObservation = player.observe(\.currentItem?.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.prerollIfReady() }
        }
        if isVisible {
            player.play()
        }
    }

    /// A page readied beside the current one loads its video's first seconds while paused, so it starts at once
    /// when swiped to. AVPlayer only prerolls a ready item that isn't playing.
    private func prerollIfReady() {
        guard let player, !isVisible, !hasPrerolled, player.rate == 0, player.currentItem?.status == .readyToPlay else { return }
        hasPrerolled = true
        player.preroll(atRate: 1)
    }

    // MARK: Zoom

    /// The media's size fitted to the page, at zoom scale 1.
    private var fittedSize: CGSize {
        let bounds = scrollView.bounds.size
        let ratio: CGFloat? = page.media.aspectRatio.map { CGFloat($0) }
            ?? imageView.image.map { $0.size.width / max($0.size.height, 1) }
        guard let ratio, ratio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        return bounds.width / bounds.height > ratio
            ? CGSize(width: bounds.height * ratio, height: bounds.height)
            : CGSize(width: bounds.width, height: bounds.width / ratio)
    }

    private func layoutContent() {
        let size = fittedSize
        contentView.frame = CGRect(origin: .zero, size: size)
        imageView.frame = contentView.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = contentView.bounds
        CATransaction.commit()
        scrollView.contentSize = size
        centerContent()
    }

    func viewForZooming(in _: UIScrollView) -> UIView? {
        contentView
    }

    func scrollViewDidZoom(_: UIScrollView) {
        centerContent()
    }

    /// Keeps media smaller than the page centered on it.
    private func centerContent() {
        let x = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let y = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if isZoomed {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: contentView)
        let scale = scrollView.maximumZoomScale / 2
        let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
        scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    @objc private func tapped() {
        onTap?()
    }
}

private extension URL {
    var removingQuery: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false), components.query != nil else { return self }
        components.query = nil
        return components.url ?? self
    }
}

/// What the viewer's caption shows: the current page's post, and each post's engagement as it changes here, so a
/// like stays when paging through the post's other photos and back.
@MainActor
final class MediaViewerCaptionModel: ObservableObject {
    @Published var page: MediaViewerPage?
    @Published var engagements: [String: PostEngagement] = [:]
    let network: SocialNetwork
    let engaging: (any PostEngaging)?
    var onTap: (() -> Void)?

    init(network: SocialNetwork, engaging: (any PostEngaging)?) {
        self.network = network
        self.engaging = engaging
    }

    func engagement(of page: MediaViewerPage) -> Binding<PostEngagement?> {
        Binding(
            get: { self.engagements[page.itemId] ?? page.post?.engagement },
            set: { self.engagements[page.itemId] = $0 },
        )
    }

    func reload(_ page: MediaViewerPage) async {
        guard let engaging, let loaded = try? await engaging.fetchEngagement(postId: page.itemId) else { return }
        engagements[page.itemId] = loaded
    }
}

/// The post's text, which photo of the post this is, and its counts and actions, over a gradient at the bottom of
/// the viewer. Tapping the text or the gradient hides it with the rest of the viewer's buttons.
struct MediaViewerCaptionView: View {
    @ObservedObject var model: MediaViewerCaptionModel

    var body: some View {
        if let page = model.page {
            VStack(alignment: .leading, spacing: 12) {
                if page.caption != nil || page.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        if let caption = page.caption {
                            Text(caption)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                                .lineLimit(8)
                        }
                        if page.count > 1 {
                            Text("\(page.index + 1) of \(page.count)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let engaging = model.engaging, let post = page.post, let postURL = NotificationTargetURL.resolve(network: model.network, target: post.target) {
                    PostActionBar(
                        target: post.target,
                        author: post.target.author,
                        network: model.network,
                        postURL: postURL,
                        engaging: engaging,
                        engagement: model.engagement(of: page),
                        reload: { await model.reload(page) },
                    )
                    // Each post its own bar: a composer or alert open for one post doesn't carry over to the next.
                    .id(page.itemId)
                } else if page.counts != nil || page.link != nil {
                    ReadOnlyCounts(counts: page.counts ?? MediaViewerPage.Counts(), link: page.link)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, 12)
            .background {
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                model.onTap?()
            }
        }
    }
}

/// A label with room around its text, for the scrubbing time.
private final class InsetLabel: UILabel {
    private let insets = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

/// A post's replies, reposts and likes where the app can't act on it, then sharing the link: only the counts the
/// network gives (Instagram has no reposts), spread evenly across the bar as `PostActionBar` spreads its buttons.
private struct ReadOnlyCounts: View {
    let counts: MediaViewerPage.Counts
    let link: URL?

    private var shown: [(systemImage: String, value: Int, name: String)] {
        [
            ("bubble.left", counts.replies, "replies"),
            ("arrow.2.squarepath", counts.reposts, "reposts"),
            ("heart", counts.likes, "likes"),
        ].compactMap { item in item.1.map { (item.0, $0, item.2) } }
    }

    var body: some View {
        HStack {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Spacer()
                }
                HStack(spacing: 4) {
                    Image(systemName: item.systemImage)
                    if item.value > 0 {
                        Text(PostCardView.compactCount(item.value))
                            .monospacedDigit()
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.value) \(item.name)")
            }
            if let link {
                if !shown.isEmpty {
                    Spacer()
                }
                ShareLink(item: link) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}
