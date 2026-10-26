import Photos
import UIKit

/// Full-screen viewer for an image in an Apron chat: pinch or double-tap to zoom, swipe up or down to dismiss,
/// tap to show or hide the buttons, and save the original file to Photos.
final class ApronImageViewerController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let url: URL
    private let alt: String?
    private let backdrop = UIView()
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let closeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private var chromeHidden = false
    private var loadTask: Task<Void, Never>?

    /// Past this distance or speed, a vertical swipe dismisses instead of springing back.
    private static let dismissDistance: CGFloat = 120
    private static let dismissVelocity: CGFloat = 800

    init(url: URL, image: UIImage?, alt: String?) {
        self.url = url
        self.alt = alt
        super.init(nibName: nil, bundle: nil)
        imageView.image = image
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
    }

    override var prefersStatusBarHidden: Bool {
        chromeHidden
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        backdrop.backgroundColor = .black
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = alt ?? "Image"
        imageView.accessibilityTraits = .image
        scrollView.addSubview(imageView)

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        configure(closeButton, systemImage: "xmark", label: "Close", action: #selector(close))
        configure(saveButton, systemImage: "square.and.arrow.down", label: "Save to Photos", action: #selector(save))
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            saveButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            saveButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
        tap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        if imageView.image == nil {
            loadImage()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scrollView.zoomScale == scrollView.minimumZoomScale {
            imageView.frame = scrollView.bounds
            scrollView.contentSize = scrollView.bounds.size
        }
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

    private func loadImage() {
        if let cached = StoryImageCache.shared.image(for: url) {
            imageView.image = cached
            return
        }
        spinner.startAnimating()
        loadTask = Task { [weak self, url] in
            let image = await (try? URLSession.shared.data(from: url)).flatMap { UIImage(data: $0.0) }
            guard let self, !Task.isCancelled else { return }
            spinner.stopAnimating()
            guard let image else { return }
            StoryImageCache.shared.setImage(image, for: url)
            imageView.image = image
        }
    }

    // MARK: Zoom

    func viewForZooming(in _: UIScrollView) -> UIView? {
        imageView
    }

    /// Keeps a zoomed-out image centered.
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let x = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let y = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let scale = scrollView.maximumZoomScale / 2
        let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
        scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    // MARK: Chrome

    @objc private func toggleChrome() {
        setChromeHidden(!chromeHidden)
    }

    private func setChromeHidden(_ hidden: Bool) {
        chromeHidden = hidden
        UIView.animate(withDuration: 0.2) {
            self.closeButton.alpha = hidden ? 0 : 1
            self.saveButton.alpha = hidden ? 0 : 1
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: Swipe to dismiss

    /// Only a mostly vertical drag on an image that isn't zoomed in dismisses; a zoomed image pans instead.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return scrollView.zoomScale <= scrollView.minimumZoomScale && abs(velocity.y) > abs(velocity.x)
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view).y
        switch pan.state {
        case .began:
            closeButton.alpha = 0
            saveButton.alpha = 0
        case .changed:
            imageView.transform = CGAffineTransform(translationX: 0, y: translation)
            backdrop.alpha = 1 - min(abs(translation) / (view.bounds.height / 2), 1) * 0.8
        case .ended, .cancelled:
            let velocity = pan.velocity(in: view).y
            if pan.state == .ended, abs(translation) > Self.dismissDistance || abs(velocity) > Self.dismissVelocity {
                // Leaves in the direction of the swipe, then dismisses without the cross-dissolve.
                let direction: CGFloat = (abs(velocity) > Self.dismissVelocity ? velocity : translation) < 0 ? -1 : 1
                UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
                    self.imageView.transform = CGAffineTransform(translationX: 0, y: direction * self.view.bounds.height)
                    self.backdrop.alpha = 0
                } completion: { _ in
                    self.dismiss(animated: false)
                }
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    self.imageView.transform = .identity
                    self.backdrop.alpha = 1
                    self.closeButton.alpha = self.chromeHidden ? 0 : 1
                    self.saveButton.alpha = self.chromeHidden ? 0 : 1
                }
            }
        default:
            break
        }
    }

    // MARK: Save

    /// Saves the original bytes, so GIFs and the full resolution survive, rather than the decoded image.
    @objc private func save() {
        setSaving(true)
        Task { [weak self, url] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
                    throw ApronImageSaveError.denied
                }
                try await Self.addToPhotos(data)
                self?.setSaving(false, saved: true)
            } catch {
                self?.setSaving(false)
                self?.showSaveError(error)
            }
        }
    }

    /// Photos runs the change block on its own queue, so it must not inherit the controller's main-actor isolation.
    private nonisolated static func addToPhotos(_ data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    private func setSaving(_ saving: Bool, saved: Bool = false) {
        saveButton.configuration?.showsActivityIndicator = saving
        saveButton.isEnabled = !saving && !saved
        if saved {
            saveButton.configuration?.image = UIImage(systemName: "checkmark")
            saveButton.accessibilityLabel = "Saved to Photos"
        }
    }

    private func showSaveError(_ error: Error) {
        let message = (error as? ApronImageSaveError) == .denied
            ? "Allow stupid social to add photos in Settings to save images."
            : error.localizedDescription
        let alert = UIAlertController(title: "Couldn't Save Image", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private enum ApronImageSaveError: Error {
    case denied
}
