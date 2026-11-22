import SwiftUI
import UIKit

enum HomePage: String, Hashable {
    case chats
    case social
}

/// Chats to the left of the feed, swiped between like Instagram's camera and inbox. The pages wrap around, so
/// swiping on past either page lands on the other. A `UIPageViewController`
/// hosts each side as a child view controller; SwiftUI's paging `TabView` and `ScrollView` dropped the
/// navigation bars' layout margins, leaving large titles against the screen edge.
struct HomePager<Chats: View, Social: View>: UIViewControllerRepresentable {
    @Binding var page: HomePage
    /// Off while the visible side has a screen pushed, so back swipes and swipe-to-reply aren't taken over.
    /// The page dots hide with it, so they never cover a chat's composer.
    let isPagingEnabled: Bool
    let chats: Chats
    let social: Social

    func makeCoordinator() -> Coordinator {
        Coordinator(page: $page, chats: UIHostingController(rootView: chats), social: UIHostingController(rootView: social))
    }

    func makeUIViewController(context: Context) -> HomePagerController {
        let controller = HomePagerController()
        controller.pageController.dataSource = context.coordinator
        controller.pageController.delegate = context.coordinator
        controller.pageController.setViewControllers([context.coordinator.controller(for: page)], direction: .forward, animated: false)
        controller.leftPage = context.coordinator.chats
        controller.pages = [context.coordinator.chats, context.coordinator.social]
        return controller
    }

    func updateUIViewController(_ controller: HomePagerController, context: Context) {
        let coordinator = context.coordinator
        coordinator.page = $page
        coordinator.chats.rootView = chats
        coordinator.social.rootView = social
        controller.setPagingEnabled(isPagingEnabled)
        // A page set from outside, such as by a tapped notification, and not by a swipe. Never mid-swipe: the page
        // controller switches its current page before the swipe settles and `page` catches up, and setting
        // pages during the transition raises an exception (a crash in build 190). On the next turn of the run loop,
        // not inside SwiftUI's update: Chats swapped in during launch's first update (a notification tapped with the
        // app left on the feed) laid out without the top safe area, its bars under the status bar until relaunch.
        let target = coordinator.controller(for: page)
        if !coordinator.isTransitioning, controller.pageController.viewControllers?.first !== target {
            DispatchQueue.main.async {
                guard !coordinator.isTransitioning, controller.pageController.viewControllers?.first !== target else { return }
                controller.show(target)
            }
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var page: Binding<HomePage>
        let chats: UIHostingController<Chats>
        let social: UIHostingController<Social>
        /// From the start of a swipe's transition until it finishes, completed or not.
        var isTransitioning = false

        init(page: Binding<HomePage>, chats: UIHostingController<Chats>, social: UIHostingController<Social>) {
            self.page = page
            self.chats = chats
            self.social = social
        }

        func controller(for page: HomePage) -> UIViewController {
            page == .chats ? chats : social
        }

        func pageViewController(_: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            other(than: viewController)
        }

        func pageViewController(_: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            other(than: viewController)
        }

        private func other(than viewController: UIViewController) -> UIViewController {
            viewController === chats ? social : chats
        }

        func pageViewController(_: UIPageViewController, willTransitionTo _: [UIViewController]) {
            isTransitioning = true
        }

        func pageViewController(_ controller: UIPageViewController, didFinishAnimating _: Bool, previousViewControllers _: [UIViewController], transitionCompleted completed: Bool) {
            isTransitioning = false
            guard completed, let current = controller.viewControllers?.first else { return }
            page.wrappedValue = current === chats ? .chats : .social
        }
    }
}

/// The page controller with the page dots over it. The dots are updated straight from the scroll offset:
/// routing every offset change through SwiftUI state re-rendered both pages mid-swipe and cancelled the pan.
final class HomePagerController: UIViewController {
    let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    /// The page at progress 0; the other is at 1.
    weak var leftPage: UIViewController?
    /// Both pages, which get the keyboard's height as a bottom safe area inset.
    var pages: [UIViewController] = []
    private let dots = HomePageDotsView()
    private var offsetObservation: NSKeyValueObservation?
    /// The progress of the page shown when the scroll view was last at rest.
    private var restingProgress: CGFloat = 1

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)

        observeScrolling()

        dots.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dots)
        // Below the safe area, between Chats' bottom search field and the home indicator; on screens with no bottom
        // inset, just above the edge.
        let belowSafeArea = dots.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 2)
        belowSafeArea.priority = .defaultHigh
        NSLayoutConstraint.activate([
            dots.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            belowSafeArea,
            dots.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -2),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// The pages are hosting controllers inside the page controller's scroll view, which don't avoid the keyboard
    /// themselves, so forms in them get the keyboard's height as a bottom inset, animated with the keyboard. The
    /// pager itself keeps its size: shrinking it left a black band under a chat while the keyboard rose, and
    /// left the Chats list laid out at half height when a chat closed with the keyboard up. Chats ignore the
    /// inset and place their composer on `keyboardLayoutGuide`.
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let info = notification.userInfo, let window = view.window else { return }
        var overlap: CGFloat = 0
        if notification.name != UIResponder.keyboardWillHideNotification,
           let screenFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        {
            let frame = view.convert(screenFrame, from: window.screen.coordinateSpace)
            // A floating or undocked keyboard (iPad) doesn't reach the bottom edge and covers nothing to avoid.
            if frame.maxY >= view.bounds.maxY - 1 {
                overlap = max(0, view.bounds.maxY - frame.minY - view.safeAreaInsets.bottom)
            }
        }
        guard pages.contains(where: { $0.additionalSafeAreaInsets.bottom != overlap }) else { return }
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
        let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState]) {
            for page in self.pages {
                page.additionalSafeAreaInsets.bottom = overlap
                page.view.layoutIfNeeded()
            }
        }
    }

    /// Shows a page without a swipe.
    func show(_ page: UIViewController) {
        let isLeft = page === leftPage
        pageController.setViewControllers([page], direction: isLeft ? .reverse : .forward, animated: false)
        restingProgress = isLeft ? 0 : 1
        dots.progress = restingProgress
    }

    func setPagingEnabled(_ enabled: Bool) {
        scrollView?.isScrollEnabled = enabled
        dots.isHidden = !enabled
    }

    /// The scroll view rests one page in, with the current page in the middle, and moves a page either way
    /// during a swipe. It stays the page controller's own delegate, so the offset is observed instead.
    private func observeScrolling() {
        offsetObservation = scrollView?.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            MainActor.assumeIsolated {
                guard let self, scrollView.bounds.width > 0 else { return }
                let shift = (scrollView.contentOffset.x - scrollView.bounds.width) / scrollView.bounds.width
                // The page controller switches its current page while a swipe is still settling, before the
                // offset returns to the middle, so the swipe is measured from the page it started on.
                if shift == 0 {
                    self.restingProgress = self.pageController.viewControllers?.first === self.leftPage ? 0 : 1
                }
                // Past either end the swipe wraps to the other page, so the position reflects back into 0...1.
                let position = self.restingProgress + shift
                self.dots.progress = min(1, max(0, position < 0 ? -position : position > 1 ? 2 - position : position))
            }
        }
    }

    private var scrollView: UIScrollView? {
        pageController.view.subviews.lazy.compactMap { $0 as? UIScrollView }.first
    }
}

/// Two dots like the story rows' indicator: each grows and darkens with how close the scroll position is to
/// its page, so they move continuously with a swipe.
final class HomePageDotsView: UIView {
    private static let minimumSize: CGFloat = 5
    private static let growth: CGFloat = 2
    private static let spacing: CGFloat = 5
    /// Padding inside the pill that keeps the dots legible over content.
    private static let inset = UIEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)
    private let pill = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let dotViews = [UIView(), UIView()]

    /// 0 on Chats, 1 on Social.
    var progress: CGFloat = 1 {
        didSet {
            guard progress != oldValue else { return }
            setNeedsLayout()
            accessibilityLabel = progress < 0.5 ? "Chats, page 1 of 2" : "Notifications, page 2 of 2"
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        pill.clipsToBounds = true
        addSubview(pill)
        dotViews.forEach(addSubview)
        isAccessibilityElement = true
        accessibilityLabel = "Notifications, page 2 of 2"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        let largest = Self.minimumSize + Self.growth
        return CGSize(
            width: largest * 2 + Self.spacing + Self.inset.left + Self.inset.right,
            height: largest + Self.inset.top + Self.inset.bottom,
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pill.frame = bounds
        pill.layer.cornerRadius = bounds.height / 2
        let slot = Self.minimumSize + Self.growth
        for (index, dot) in dotViews.enumerated() {
            let intensity = max(0, 1 - abs(progress - CGFloat(index)))
            let size = Self.minimumSize + Self.growth * intensity
            let centerX = Self.inset.left + slot / 2 + CGFloat(index) * (slot + Self.spacing)
            dot.frame = CGRect(x: centerX - size / 2, y: (bounds.height - size) / 2, width: size, height: size)
            dot.layer.cornerRadius = size / 2
            dot.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.25 + 0.75 * intensity)
        }
    }
}
