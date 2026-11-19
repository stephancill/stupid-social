import AVFoundation
import Combine
import StupidSocialCore
import SwiftUI
import UIKit

/// One photo or video of a post in the viewer: the viewer pages through every one of every post in the grid.
struct ProfileMediaPage: Hashable {
    let post: PostThread.Post
    let index: Int
    let count: Int
    let media: ProfileTimelineItem.Media
    let caption: String?

    var itemId: String {
        post.target.id
    }

    var key: String {
        "\(itemId)#\(index)"
    }
}

extension ProfileTimelineItem {
    /// Its photos and videos, or the grid's thumbnail when only a link card has an image.
    var mediaPages: [ProfileMediaPage] {
        let caption = post.target.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = !media.isEmpty ? media : thumbnailURL.map { [ProfileTimelineItem.Media(imageURL: $0)] } ?? []
        return shown.enumerated().map { index, media in
            ProfileMediaPage(post: post, index: index, count: shown.count, media: media, caption: caption?.isEmpty == false ? caption : nil)
        }
    }
}

@MainActor
enum ProfileMediaViewer {
    /// Opens the media grid of `kind` full screen at the post's first photo or video, with each post's counts and
    /// actions when `engaging` is given.
    static func present(timeline: ProfileTimelineViewModel, kind: ProfileTimelineKind, itemId: String, network: SocialNetwork, engaging: (any PostEngaging)?) {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard var presenter = window?.rootViewController else { return }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        let caption = ProfileMediaCaptionModel(network: network, engaging: engaging)
        let viewer = ProfileMediaViewerController(timeline: timeline, kind: kind, itemId: itemId, caption: caption)
        presenter.present(viewer, animated: true)
    }

    static func pages(_ items: [ProfileTimelineItem]) -> [ProfileMediaPage] {
        items.filter { $0.thumbnailURL != nil }.flatMap(\.mediaPages)
    }
}

/// Full-screen media from a profile's grid: swipe sideways through every photo and video, pinch or double-tap
/// to zoom, tap to show or hide the post's text and the buttons, swipe up or down to close. Paging near the end
/// loads the grid's next page.
final class ProfileMediaViewerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    private let timeline: ProfileTimelineViewModel
    private let kind: ProfileTimelineKind
    private var pages: [ProfileMediaPage] = []
    private var currentKey: String

    private let backdrop = UIView()
    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 12])
    private let closeButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let caption: ProfileMediaCaptionModel
    private let captionController: UIHostingController<ProfileMediaCaptionView>
    private var captionView: UIView {
        captionController.view
    }

    private var chromeHidden = false
    private var timelineObservation: AnyCancellable?
    /// Controllers for the current page and those beside it, by page key.
    private var prepared: [String: ProfileMediaPageController] = [:]

    private static let dismissDistance: CGFloat = 120
    private static let dismissVelocity: CGFloat = 800
    /// Pages from the end at which the grid's next page loads.
    private static let loadMoreDistance = 4
    /// Pages readied on each side of the current one: more ahead, the way people swipe.
    private static let preparedAhead = 2
    private static let preparedBehind = 1
    /// Pages past the readied ones whose photos (or video posters) are downloaded ahead.
    private static let warmedAhead = 4

    init(timeline: ProfileTimelineViewModel, kind: ProfileTimelineKind, itemId: String, caption: ProfileMediaCaptionModel) {
        self.timeline = timeline
        self.kind = kind
        self.caption = caption
        captionController = UIHostingController(rootView: ProfileMediaCaptionView(model: caption))
        pages = ProfileMediaViewer.pages(timeline.timeline(kind).items)
        currentKey = pages.first { $0.itemId == itemId }?.key ?? pages.first?.key ?? ""
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
        configure(playButton, systemImage: "pause.fill", label: "Pause", action: #selector(togglePlayback))
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            playButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            playButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        timelineObservation = timeline.$timelines
            .map { [kind] in $0[kind]?.items ?? [] }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] items in self?.update(items) }

        showCurrentPage()
    }

    // MARK: Pages

    private var currentIndex: Int? {
        pages.firstIndex { $0.key == currentKey }
    }

    private var currentPageController: ProfileMediaPageController? {
        pager.viewControllers?.first as? ProfileMediaPageController
    }

    /// The page's controller: the one prepared ahead when there is one, so its photo and video are already loading.
    private func pageController(_ page: ProfileMediaPage) -> ProfileMediaPageController {
        if let prepared = prepared[page.key] {
            return prepared
        }
        let controller = ProfileMediaPageController(page: page)
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
        guard let key = (viewController as? ProfileMediaPageController)?.page.key,
              let index = pages.firstIndex(where: { $0.key == key }), index > 0
        else { return nil }
        return pageController(pages[index - 1])
    }

    func pageViewController(_: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let key = (viewController as? ProfileMediaPageController)?.page.key,
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
        updatePlayButton()
        if let index = currentIndex, index + Self.loadMoreDistance >= pages.count {
            timeline.loadMore(kind)
        }
        prepareNeighbors()
    }

    /// A later page of the grid adds pages; the pager asks again for the page after the current one, which it
    /// last heard was the end.
    private func update(_ items: [ProfileTimelineItem]) {
        let wasLast = currentIndex == pages.count - 1
        pages = ProfileMediaViewer.pages(items)
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

    private func configure(_ button: UIButton, systemImage: String, label: String, action: Selector) {
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
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
    }

    private var chromeViews: [UIView] {
        [closeButton, captionView] + (currentPageController?.isVideo == true ? [playButton] : [])
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
        playButton.alpha = chromeHidden || currentPageController?.isVideo != true ? 0 : 1
    }

    private func updatePlayButton() {
        let isPlaying = currentPageController?.isPlaying ?? false
        playButton.configuration?.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill")
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

    // MARK: Swipe to dismiss

    /// Only a mostly vertical drag on media that isn't zoomed in closes the viewer; sideways drags page.
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
final class ProfileMediaPageController: UIViewController, UIScrollViewDelegate {
    let page: ProfileMediaPage
    var onTap: (() -> Void)?
    var onPlaybackChange: (() -> Void)?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var loadTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var readyObservation: NSKeyValueObservation?
    private var hasPrerolled = false
    private var isVisible = false

    init(page: ProfileMediaPage) {
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
final class ProfileMediaCaptionModel: ObservableObject {
    @Published var page: ProfileMediaPage?
    @Published var engagements: [String: PostEngagement] = [:]
    let network: SocialNetwork
    let engaging: (any PostEngaging)?
    var onTap: (() -> Void)?

    init(network: SocialNetwork, engaging: (any PostEngaging)?) {
        self.network = network
        self.engaging = engaging
    }

    func engagement(of page: ProfileMediaPage) -> Binding<PostEngagement?> {
        Binding(
            get: { self.engagements[page.itemId] ?? page.post.engagement },
            set: { self.engagements[page.itemId] = $0 },
        )
    }

    func reload(_ page: ProfileMediaPage) async {
        guard let engaging, let loaded = try? await engaging.fetchEngagement(postId: page.itemId) else { return }
        engagements[page.itemId] = loaded
    }
}

/// The post's text, which photo of the post this is, and its counts and actions, over a gradient at the bottom of
/// the viewer. Tapping the text or the gradient hides it with the rest of the viewer's buttons.
struct ProfileMediaCaptionView: View {
    @ObservedObject var model: ProfileMediaCaptionModel

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

                if let engaging = model.engaging, let postURL = NotificationTargetURL.resolve(network: model.network, target: page.post.target) {
                    PostActionBar(
                        target: page.post.target,
                        author: page.post.target.author,
                        network: model.network,
                        postURL: postURL,
                        engaging: engaging,
                        engagement: model.engagement(of: page),
                        reload: { await model.reload(page) },
                    )
                    // Each post its own bar: a composer or alert open for one post doesn't carry over to the next.
                    .id(page.itemId)
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
