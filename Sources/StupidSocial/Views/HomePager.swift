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
    let isPagingEnabled: Bool
    /// The titles row in both pages' large titles, moved along with a swipe.
    let titles: HomeTitleStripModel
    let chats: Chats
    let social: Social

    func makeCoordinator() -> Coordinator {
        Coordinator(page: $page, chats: UIHostingController(rootView: chats), social: UIHostingController(rootView: social))
    }

    func makeUIViewController(context: Context) -> HomePagerController {
        let controller = HomePagerController(titles: titles)
        controller.pageController.dataSource = context.coordinator
        controller.pageController.delegate = context.coordinator
        controller.pageController.setViewControllers([context.coordinator.controller(for: page)], direction: .forward, animated: false)
        controller.leftPage = context.coordinator.chats
        controller.pages = [context.coordinator.chats, context.coordinator.social]
        titles.pageViews = controller.pages.map(\.view)
        titles.position = page == .chats ? 0 : 1
        // A tapped title scrolls to its page, the way a swipe would.
        titles.select = { [weak controller, coordinator = context.coordinator] index in
            guard let controller, !coordinator.isTransitioning else { return }
            let current = Int(titles.position.rounded())
            guard index != current else { return }
            let target: HomePage = index.isMultiple(of: 2) ? .chats : .social
            coordinator.isTransitioning = true
            // Before the scroll, so the update it causes finds the page already showing.
            coordinator.page.wrappedValue = target
            controller.scroll(to: coordinator.controller(for: target), forward: index > current) {
                coordinator.isTransitioning = false
            }
        }
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

/// The page controller, which moves the title strip straight from the scroll offset: routing every offset change
/// through SwiftUI state re-rendered both pages mid-swipe and cancelled the pan.
final class HomePagerController: UIViewController {
    let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    /// The page at progress 0; the other is at 1.
    weak var leftPage: UIViewController?
    /// Both pages, which get the keyboard's height as a bottom safe area inset.
    var pages: [UIViewController] = []
    private let titles: HomeTitleStripModel
    private var offsetObservation: NSKeyValueObservation?

    init(titles: HomeTitleStripModel) {
        self.titles = titles
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)

        observeScrolling()

        // Nothing inside a navigation bar's large title receives touches, so the pager takes taps on the titles.
        let titleTap = UITapGestureRecognizer(target: self, action: #selector(titleTapped))
        titleTap.cancelsTouchesInView = false
        titleTap.delegate = self
        view.addGestureRecognizer(titleTap)

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

    @objc private func titleTapped(_ recognizer: UITapGestureRecognizer) {
        if let index = titles.titleIndex(at: recognizer.location(in: view), in: view) {
            titles.select?(index)
        }
    }

    /// Shows a page without a swipe.
    func show(_ page: UIViewController) {
        let isLeft = page === leftPage
        pageController.setViewControllers([page], direction: isLeft ? .reverse : .forward, animated: false)
        titles.position = isLeft ? 0 : 1
    }

    /// Scrolls to a page as a swipe would, for a tapped title.
    func scroll(to page: UIViewController, forward: Bool, completion: @escaping () -> Void) {
        pageController.setViewControllers([page], direction: forward ? .forward : .reverse, animated: true) { [weak self] _ in
            guard let self else { return }
            titles.position = page === leftPage ? 0 : 1
            // An animated set leaves the page controller's cached neighbours stale, so it's set again without.
            DispatchQueue.main.async {
                self.pageController.setViewControllers([page], direction: .forward, animated: false)
                completion()
            }
        }
    }

    func setPagingEnabled(_ enabled: Bool) {
        scrollView?.isScrollEnabled = enabled
    }

    /// The scroll view stays the page controller's own delegate, so its offset is observed instead. The titles
    /// follow on the next layout pass: when the page controller moves the scroll view back to the middle, it
    /// sets the offset before moving the pages, so they're only where they belong once it's done.
    private func observeScrolling() {
        offsetObservation = scrollView?.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.view.setNeedsLayout() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTitlesPosition()
    }

    /// The titles' position from where the pages are on screen. Measured from the scroll offset and the page
    /// the swipe started on, a swipe started while the last one was still settling counted from the wrong page,
    /// and the titles showed the other page's until the scroll view came back to the middle (observed 2026-11-23).
    private func updateTitlesPosition() {
        guard let scrollView, scrollView.bounds.width > 0 else { return }
        let width = scrollView.bounds.width
        for page in pages where page.view.isDescendant(of: scrollView) {
            let x = page.view.convert(CGPoint.zero, to: view).x
            guard abs(x) < width else { continue }
            // Past either end the swipe wraps to the other page, which the title row repeats for.
            titles.position = (page === leftPage ? 0 : 1) - x / width
            return
        }
    }

    private var scrollView: UIScrollView? {
        pageController.view.subviews.lazy.compactMap { $0 as? UIScrollView }.first
    }
}

extension HomePagerController: UIGestureRecognizerDelegate {
    /// Only touches on a title, alongside whatever else is handling them, and never while paging is off: a screen is
    /// pushed over the visible page then, with its own controls where the titles were.
    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        scrollView?.isScrollEnabled != false && titles.titleIndex(at: touch.location(in: view), in: view) != nil
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        true
    }
}
