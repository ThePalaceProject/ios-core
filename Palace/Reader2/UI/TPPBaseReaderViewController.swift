//
//  ReaderViewController.swift
//  Created by Mickaël Menu on 07.03.19.
//
//  Copyright 2019 European Digital Reading Lab. All rights reserved.
//  Licensed to the Readium Foundation under one or more contributor license agreements.
//  Use of this source code is governed by a BSD-style license which is detailed in the
//  LICENSE file present in the project repository where this source code is maintained.
//

import SafariServices
import UIKit
import WebKit
import PalaceBookRegistry
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import Combine
import PalaceLogging
import PalaceBookModel

/// Bridges Readium's `Navigator` (which has a `go(to:options:)` method)
/// to our internal `NavigatorGoTo` testing seam, used by
/// `ReaderInitialLocationNavigator` to gate the initial restore call.
/// `Navigator` is already `@MainActor`-bound in Readium 3.x.
private final class GoToNavigatorAdapter: NavigatorGoTo {
    private let navigator: UIViewController & Navigator
    init(_ navigator: UIViewController & Navigator) {
        self.navigator = navigator
    }
    func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool {
        await navigator.go(to: locator, options: options)
    }
}

/// This class is meant to be subclassed by each publication format view controller. It contains the shared behavior, eg. navigation bar toggling.
///
/// Swift 6 `complete`: this is a UIKit view controller, so it is already
/// `@MainActor`-isolated via `UIViewController`. The residual `complete`-mode
/// warnings here are (1) non-Sendable Readium type crossings — `Publication`,
/// `Locator`, `Decoration` — handled by the `@preconcurrency import`s above, and
/// (2) conformance of this main-actor type to the Palace-owned, nonisolated
/// `TPPReaderPositionsDelegate`, handled by `@preconcurrency` on that
/// conformance below. The Readium delegate protocols (`NavigatorDelegate`,
/// `VisualNavigatorDelegate`) are already `@MainActor`, so those conformances
/// need no annotation.
class TPPBaseReaderViewController: UIViewController, Loggable {
    typealias DisplayStrings = Strings.TPPBaseReaderViewController

    private static let bookmarkOnImageName = "BookmarkOn"
    private static let bookmarkOffImageName = "BookmarkOff"

    // Side margins for long labels
    static let overlayLabelMargin: CGFloat = 20

    // TODO: SIMPLY-2656 See if we still need this.
    weak var moduleDelegate: ModuleDelegate?

    // Models and business logic references
    let publication: Publication
    private let bookmarksBusinessLogic: TPPReaderBookmarksBusinessLogic
    private let lastReadPositionPoster: TPPLastReadPositionPoster

    // UI
    var navigator: UIViewController & Navigator
    private var tocBarButton: UIBarButtonItem?
    private var bookmarkBarButton: UIBarButtonItem?
    /// The bookmark bar button is hosted as a custom-view `UIButton` so the
    /// add-confirmation bounce can animate its view (a plain `UIBarButtonItem`
    /// exposes no animatable view). Same asset art / target-action as before.
    private var bookmarkButton: UIButton?
    private(set) var stackView: UIStackView!
    private(set) var navigatorContainer: UIView!
    private(set) lazy var positionLabel = UILabel()
    private(set) lazy var bookTitleLabel = UILabel()

    /// PP-5006 prototype: the drag-to-navigate chapter scrubber. Nil unless the
    /// Testing-menu flag is on, so with the flag off the reader's view
    /// hierarchy and layout are byte-for-byte what they were before.
    private(set) var chapterScrubber: ChapterScrubberView?

    /// Reads the chapter-scrubber flag. The default consults the flag's static
    /// `UserDefaults` reader rather than the shared instance or the composition
    /// root: this flag has no remote component and no instance state, so
    /// neither indirection would buy anything, and both are ratcheted. A
    /// closure (not a value) so nothing is resolved during `init`.
    private let chapterScrubberEnabled: () -> Bool
    private var isShowingSample: Bool = false
    private var initialLocation: Locator?
    private var subscriptions: Set<AnyCancellable> = []

    /// P0 #3: gates the initial `navigator.go(to:)` call behind a
    /// WKWebView-ready signal. See `ReaderInitialLocationNavigator` for
    /// the rationale — the prior unguarded `Task { go }` raced first
    /// paint and occasionally dropped the patron at chapter 1.
    private let initialLocationGate: ReaderInitialLocationNavigator

    /// Strong-held adapter that bridges `Navigator` to `NavigatorGoTo`.
    /// The gate holds a weak ref so the adapter must outlive it; the VC
    /// is the natural owner of both.
    private var initialNavigatorAdapter: GoToNavigatorAdapter?

    /// When `true`, the legacy `VisualNavigatorDelegate.didTapAt` is skipped.
    /// Subclasses using Readium's input observer system (`.tap` observer,
    /// `DirectionalNavigationAdapter`) should override this to return `true`
    /// to prevent double-toggling the toolbar.
    var usesInputObserversForTapHandling: Bool { false }

    /// Set before any user-initiated navigation (toolbar buttons, keyboard,
    /// edge taps). Cleared by `didChangeLocation` after use. Lets subclasses
    /// distinguish manual page turns from VoiceOver's automatic
    /// `accessibilityScroll` which flows through Readium's internal path.
    var manualNavigationPending = false

    private var currentLocationIsBookmarked: Bool {
        bookmarksBusinessLogic.currentLocation(in: navigator) != nil
    }

    enum ReaderKeyboardCommand {
        case goBackward
        case goForward
        case toggleUI
    }

    // MARK: - Lifecycle

    /// Designated initializer.
    /// - Parameters:
    ///   - navigator: VC that is capable of navigating the publication.
    ///   - publication: The R2 model for a publication.
    ///   - book: The SimplyE model for a book.
    ///   - drm: Information about the DRM associated with the publication.
    init(navigator: UIViewController & Navigator,
         publication: Publication,
         book: TPPBook,
         forSample: Bool = false,
         initialLocation: Locator? = nil,
         bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry,
         accountsManager: AccountsManager = AppContainer.production().accountsManager,
         chapterScrubberEnabled: @escaping () -> Bool = { RemoteFeatureFlags.isChapterScrubberEnabled() }) {

        self.navigator = navigator
        self.publication = publication
        self.chapterScrubberEnabled = chapterScrubberEnabled
        self.isShowingSample = forSample
        self.initialLocation = initialLocation
        self.initialLocationGate = ReaderInitialLocationNavigator(initialLocation: initialLocation)

        lastReadPositionPoster = TPPLastReadPositionPoster(
            book: book,
            publication: publication,
            bookRegistryProvider: bookRegistry)

        bookmarksBusinessLogic = TPPReaderBookmarksBusinessLogic(
            book: book,
            r2Publication: publication,
            drmDeviceID: AppContainer.production().accountsManager.currentUserAccount.deviceID,
            bookRegistryProvider: bookRegistry,
            currentLibraryAccountProvider: accountsManager)

        bookmarksBusinessLogic.syncBookmarks { (_, _) in }

        super.init(nibName: nil, bundle: nil)
        title = publication.metadata.title

        NotificationCenter.default.addObserver(self, selector: #selector(voiceOverStatusDidChange), name: Notification.Name(UIAccessibility.voiceOverStatusDidChangeNotification.rawValue), object: nil)

    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UIViewController

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = TPPConfiguration.backgroundColor()

        // Ensure content extends under navigation bar without shifting when bar appears/disappears
        edgesForExtendedLayout = [.top, .bottom]
        extendedLayoutIncludesOpaqueBars = true

        navigationItem.rightBarButtonItems = makeNavigationBarButtons()
        updateNavigationBar(animated: false)
        setupStackView()

        addChild(navigator)

        // Create letterbox container
        navigatorContainer = UIView()
        navigatorContainer.backgroundColor = TPPConfiguration.backgroundColor()
        stackView.addArrangedSubview(navigatorContainer)

        // Inset navigator within container to create letterbox areas
        navigatorContainer.addSubview(navigator.view)
        navigator.view.translatesAutoresizingMaskIntoConstraints = false

        // IMPORTANT: Use FIXED offsets from container edges (not safe area) to prevent
        // content shifting when navigation bar appears/disappears.
        let fixedTopInset: CGFloat = 100.0  // Letterbox space for navbar + status bar
        let fixedBottomInset: CGFloat = 50.0  // Letterbox space for home indicator

        NSLayoutConstraint.activate([
            navigator.view.topAnchor.constraint(equalTo: navigatorContainer.topAnchor, constant: fixedTopInset),
            navigator.view.bottomAnchor.constraint(equalTo: navigatorContainer.bottomAnchor, constant: -fixedBottomInset),
            navigator.view.leadingAnchor.constraint(equalTo: navigatorContainer.leadingAnchor),
            navigator.view.trailingAnchor.constraint(equalTo: navigatorContainer.trailingAnchor)
        ])

        navigator.didMove(toParent: self)

        // Prevent navigator from using safe area insets - critical for Readium 3.3.0
        navigator.view.insetsLayoutMarginsFromSafeArea = false
        navigator.additionalSafeAreaInsets = .zero

        // Prevent scroll view and WKWebView content inset adjustment
        if let scrollView = navigator.view as? UIScrollView {
            scrollView.contentInsetAdjustmentBehavior = .never
        } else {
            // Check subviews for scroll views and web views (Readium uses WKWebView for EPUBs)
            navigator.view.subviews.forEach { subview in
                if let webView = subview as? WKWebView {
                    webView.scrollView.contentInsetAdjustmentBehavior = .never
                    webView.scrollView.contentInset = .zero
                    webView.scrollView.scrollIndicatorInsets = .zero
                } else if let scrollView = subview as? UIScrollView {
                    scrollView.contentInsetAdjustmentBehavior = .never
                }
            }
        }

        stackView.addArrangedSubview(accessibilityToolbar)
        accessibilityToolbar.accessibilityElementsHidden = true

        // Position label in the bottom letterbox area
        positionLabel.translatesAutoresizingMaskIntoConstraints = false
        positionLabel.font = .preferredFont(forTextStyle: .caption1) // Dynamic Type
        positionLabel.adjustsFontForContentSizeCategory = true
        positionLabel.textAlignment = .center
        positionLabel.lineBreakMode = .byTruncatingTail
        positionLabel.textColor = .lightGray
        navigatorContainer.addSubview(positionLabel)
        NSLayoutConstraint.activate([
            positionLabel.bottomAnchor.constraint(equalTo: navigatorContainer.bottomAnchor, constant: -TPPBaseReaderViewController.overlayLabelMargin),
            positionLabel.leftAnchor.constraint(equalTo: navigatorContainer.leftAnchor, constant: TPPBaseReaderViewController.overlayLabelMargin),
            positionLabel.rightAnchor.constraint(equalTo: navigatorContainer.rightAnchor, constant: -TPPBaseReaderViewController.overlayLabelMargin),
            positionLabel.topAnchor.constraint(greaterThanOrEqualTo: navigator.view.bottomAnchor, constant: TPPBaseReaderViewController.overlayLabelMargin / 2)
        ])

        setUpChapterScrubberIfEnabled()

        // Book title label - positioned below status bar using safe area
        // Previously at 20px from container top, which overlapped the status bar
        // Using view's safe area (not container) so label moves with status bar but doesn't affect navigator
        bookTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        bookTitleLabel.font = .preferredFont(forTextStyle: .caption1) // Dynamic Type
        bookTitleLabel.adjustsFontForContentSizeCategory = true
        bookTitleLabel.textAlignment = .center
        bookTitleLabel.lineBreakMode = .byTruncatingTail
        bookTitleLabel.textColor = .lightGray
        view.addSubview(bookTitleLabel)  // Add to view, not navigatorContainer
        NSLayoutConstraint.activate([
            // Position below safe area (status bar) with small margin
            bookTitleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            bookTitleLabel.leftAnchor.constraint(equalTo: view.leftAnchor, constant: TPPBaseReaderViewController.overlayLabelMargin),
            bookTitleLabel.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -TPPBaseReaderViewController.overlayLabelMargin)
        ])

        // Accessibility
        updateViewsForVoiceOver(isRunning: UIAccessibility.isVoiceOverRunning)

        // P0 #3: hand the navigator to the gate. The actual `go(to:)`
        // fires from `viewDidAppear` via `signalReady()`, by which time
        // the WKWebView has reported first paint and the navigator's
        // location-mapping table is populated. Going earlier (as the
        // prior `viewDidLoad` Task did) raced layout and occasionally
        // landed the patron at chapter 1.
        let adapter = GoToNavigatorAdapter(navigator)
        initialNavigatorAdapter = adapter
        initialLocationGate.attach(navigator: adapter)
    }

    private func setupStackView() {
        stackView = UIStackView(frame: .zero)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.distribution = .fill
        stackView.axis = .vertical
        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor),
            stackView.rightAnchor.constraint(equalTo: view.rightAnchor),
            stackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stackView.leftAnchor.constraint(equalTo: view.leftAnchor)
        ])
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()

        // Continuously negate safe area insets to prevent Readium from responding
        navigator.additionalSafeAreaInsets = UIEdgeInsets(
            top: -view.safeAreaInsets.top,
            left: 0,
            bottom: -view.safeAreaInsets.bottom,
            right: 0
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Ensure scroll views never adjust for content insets
        configureScrollViewInsets()
    }

    private func configureScrollViewInsets() {
        if let scrollView = navigator.view as? UIScrollView {
            scrollView.contentInsetAdjustmentBehavior = .never
        } else {
            navigator.view.subviews.forEach { subview in
                configureScrollViewRecursively(subview)
            }
        }
    }

    private func configureScrollViewRecursively(_ view: UIView) {
        view.insetsLayoutMarginsFromSafeArea = false

        // Handle WKWebView specifically - this is what Readium uses for EPUB content
        if let webView = view as? WKWebView {
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.scrollView.contentInset = .zero
            webView.scrollView.scrollIndicatorInsets = .zero
        }

        if let scrollView = view as? UIScrollView {
            scrollView.contentInsetAdjustmentBehavior = .never
        }

        view.subviews.forEach { configureScrollViewRecursively($0) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        accessibilityToolbar.accessibilityElementsHidden = false

        // follow-up (product requirement): when a book is opened
        // with VoiceOver already running, the reader navbar (back / TOC /
        // bookmark / settings) must auto-present. `updateNavigationBar()`
        // checks `UIAccessibility.isVoiceOverRunning` and sets the navbar
        // visible when true, but the equivalent call at viewDidLoad time
        // (via setupView → updateViewsForVoiceOver) is too early — the
        // navigation controller's bar state isn't honored until the VC is
        // fully integrated into the navigation stack. Re-applying in
        // viewDidAppear catches that window and keeps the navbar visible
        // for any VoiceOver-on entry to a book. (When VoiceOver is off the
        // navbar stays hidden as before — visible only on user tap.)
        if UIAccessibility.isVoiceOverRunning {
            updateNavigationBar(animated: false)
        }

        // Readium may create WKWebViews asynchronously, so reconfigure after appearing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.configureScrollViewInsets()
        }

        // P0 #3: trip the initial-location gate. By viewDidAppear, the
        // navigation controller has fully integrated this VC and the
        // WKWebView's first paint is complete (Readium's onLoad observer
        // has fired by then). Safe to navigate to the saved location now.
        // The gate latches internally — repeated viewDidAppear calls
        // (e.g. modal dismissals) won't re-trigger the restore.
        initialLocationGate.signalReady()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let locator = navigator.currentLocation {
            lastReadPositionPoster.storeReadPosition(locator: locator)
        }
    }

    // MARK: - Navigation bar

    private var navigationBarHidden: Bool = true {
        didSet {
            updateNavigationBar()
        }
    }

    func makeNavigationBarButtons() -> [UIBarButtonItem] {
        var buttons: [UIBarButtonItem] = []

        let img = UIImage(named: TPPBaseReaderViewController.bookmarkOffImageName)
        // Custom-view button (same asset, same target/action) so the add
        // confirmation can bounce the button's view. Tint is inherited from the
        // navigation bar exactly as a plain image bar button item would be.
        let button = UIButton(type: .system)
        button.setImage(img, for: .normal)
        button.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        button.addTarget(self, action: #selector(toggleBookmark), for: .touchUpInside)
        button.accessibilityLabel = currentLocationIsBookmarked ? Strings.TPPBaseReaderViewController.removeBookmark : Strings.TPPBaseReaderViewController.addBookmark
        bookmarkButton = button
        let bookmarkBtn = UIBarButtonItem(customView: button)
        bookmarkBtn.accessibilityLabel = button.accessibilityLabel
        let tocButton = UIBarButtonItem(image: UIImage(named: "TOC"),
                                        style: .plain,
                                        target: self,
                                        action: #selector(presentPositionsVC))
        tocButton.accessibilityLabel = Strings.Generic.tableOfContents

        if !isShowingSample {
            buttons.append(bookmarkBtn)
        }

        buttons.append(tocButton)
        tocBarButton = tocButton
        bookmarkBarButton = bookmarkBtn
        updateBookmarkButton(withState: false)

        return buttons
    }

    private func updateBookmarkButton(withState isOn: Bool) {
        guard let button = bookmarkButton else {
            return
        }

        let imageName = isOn ? TPPBaseReaderViewController.bookmarkOnImageName : TPPBaseReaderViewController.bookmarkOffImageName
        let label = isOn ? DisplayStrings.removeBookmark : DisplayStrings.addBookmark
        button.setImage(UIImage(named: imageName), for: .normal)
        button.accessibilityLabel = label
        bookmarkBarButton?.accessibilityLabel = label
    }

    // ----------------------------------------------------------------------------
    // MARK: - Chapter scrubber (PP-5006 prototype)

    /// Builds the scrubber and hangs it in the bottom letterbox, just above the
    /// position label. Does nothing at all when the Testing-menu flag is off.
    private func setUpChapterScrubberIfEnabled() {
        guard chapterScrubberEnabled() else { return }

        let scrubber = ChapterScrubberView()
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        // Joins the chrome that `updateOverlayLabelsVisibility` fades, so it
        // arrives with the same tap that reveals the navigation bar.
        scrubber.isHidden = true
        scrubber.alpha = 0
        scrubber.onCommit = { [weak self] target in
            self?.navigateToScrubTarget(target)
        }
        scrubber.onChapterCrossed = { [weak self] in
            self?.triggerReaderHaptic(.selection)
        }
        navigatorContainer.addSubview(scrubber)

        NSLayoutConstraint.activate([
            scrubber.leftAnchor.constraint(equalTo: navigatorContainer.leftAnchor,
                                           constant: TPPBaseReaderViewController.overlayLabelMargin),
            scrubber.rightAnchor.constraint(equalTo: navigatorContainer.rightAnchor,
                                            constant: -TPPBaseReaderViewController.overlayLabelMargin),
            scrubber.bottomAnchor.constraint(equalTo: positionLabel.topAnchor, constant: -6)
        ])

        chapterScrubber = scrubber
        loadChapterScrubberModel()
    }

    /// Reads the table of contents and the position list once, off the drag
    /// path. `positionsByReadingOrder()` walks every spine resource the first
    /// time it is asked, which on a long book is the expensive part of the
    /// whole feature — doing it here means a drag never waits for it.
    private func loadChapterScrubberModel() {
        Task { @MainActor [weak self] in
            guard let publication = self?.publication else { return }
            let model = await ChapterScrubberModel.make(from: publication)
            // Weak-captured: a reader closed mid-load simply drops the result.
            guard let self else { return }

            self.chapterScrubber?.model = model
            // A book with no chapters AND no positions has nowhere to scrub to.
            // `updateOverlayLabelsVisibility` keeps the control hidden in that
            // case; the control itself also refuses to begin a scrub.
            self.updateOverlayLabelsVisibility(animated: false)
        }
    }

    /// The one place a scrub navigates. Runs after the patron lifts their
    /// finger (or after a VoiceOver adjustment), never during a drag.
    private func navigateToScrubTarget(_ target: ChapterScrubberModel.Target) {
        Task { @MainActor in
            guard let locator = await publication.locate(progression: target.progression) else {
                // Nothing to navigate to; leave `manualNavigationPending`
                // untouched so the next natural page turn is not misread as a
                // deliberate jump.
                return
            }
            manualNavigationPending = true
            await navigator.go(to: locator, options: NavigatorGoOptions(animated: false))
        }
    }

    func toggleNavigationBar() {
        navigationBarHidden = !navigationBarHidden
        // Fade the overlay chrome (book title + position) in lockstep with the
        // ~0.25s nav-bar slide so the reveal reads as one choreographed motion.
        updateOverlayLabelsVisibility(animated: true)
    }

    /// Pure decision for the reader's overlay chrome labels (book title +
    /// position). The chrome belongs to the immersive reading mode, so both
    /// labels are visible when the navigation bar is hidden and hidden when it
    /// is shown; VoiceOver always hides them (their content is surfaced through
    /// the nav bar / rotor instead).
    static func overlayLabelsHidden(navigationBarHidden: Bool, voiceOverRunning: Bool) -> Bool {
        voiceOverRunning || !navigationBarHidden
    }

    /// Fades `bookTitleLabel` and `positionLabel` together to their target
    /// visibility. `isHidden` still drives layout + accessibility; `alpha`
    /// drives the fade so the two labels animate in lockstep with the nav-bar
    /// slide instead of one flipping instantly and the other never moving.
    private func updateOverlayLabelsVisibility(animated: Bool) {
        let hidden = Self.overlayLabelsHidden(
            navigationBarHidden: navigationBarHidden,
            voiceOverRunning: UIAccessibility.isVoiceOverRunning)
        let targetAlpha: CGFloat = hidden ? 0 : 1

        // PP-5006: the scrubber is part of the same chrome, so it arrives and
        // leaves with the labels — the tap that reveals the navigation bar
        // reveals the scrubber too. Unlike the labels it stays visible under
        // VoiceOver, because it is the only one of the three a non-visual
        // patron can operate. A book with nothing to scrub through keeps it
        // hidden regardless.
        let scrubber = chapterScrubber
        let scrubberHidden = !(scrubber?.model.isUsable ?? false)
            || Self.chapterScrubberHidden(
                navigationBarHidden: navigationBarHidden,
                voiceOverRunning: UIAccessibility.isVoiceOverRunning)
        let scrubberAlpha: CGFloat = scrubberHidden ? 0 : 1

        // Reveal: unhide first so the fade-in is visible.
        if !hidden {
            bookTitleLabel.isHidden = false
            positionLabel.isHidden = false
        }
        if !scrubberHidden {
            scrubber?.isHidden = false
        }

        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.25, animations: {
                self.bookTitleLabel.alpha = targetAlpha
                self.positionLabel.alpha = targetAlpha
                scrubber?.alpha = scrubberAlpha
            }, completion: { _ in
                // Conceal: hide only after the fade-out completes.
                if hidden {
                    self.bookTitleLabel.isHidden = true
                    self.positionLabel.isHidden = true
                }
                if scrubberHidden {
                    scrubber?.isHidden = true
                }
            })
        } else {
            bookTitleLabel.alpha = targetAlpha
            positionLabel.alpha = targetAlpha
            bookTitleLabel.isHidden = hidden
            positionLabel.isHidden = hidden
            scrubber?.alpha = scrubberAlpha
            scrubber?.isHidden = scrubberHidden
        }
    }

    /// Pure decision for the chapter scrubber's visibility.
    ///
    /// The scrubber belongs to the same immersive-reading chrome as the book
    /// title and position labels — the chrome that is visible while the
    /// navigation bar is HIDDEN, and that gets out of the way when a tap brings
    /// the navigation bar in. So it tracks `overlayLabelsHidden` exactly, with
    /// one deliberate exception: it stays available under VoiceOver, where the
    /// passive labels hide. The labels hide there because their content is
    /// surfaced through the rotor instead; the scrubber is not content, it is
    /// the only drag-free way to move through the book, and hiding it would
    /// take the feature away from the patrons who most need it.
    static func chapterScrubberHidden(navigationBarHidden: Bool, voiceOverRunning: Bool) -> Bool {
        if voiceOverRunning {
            return false
        }
        return !navigationBarHidden
    }

    func updateNavigationBar(animated: Bool = true) {
        let hidden = navigationBarHidden && !UIAccessibility.isVoiceOverRunning
        navigationController?.setNavigationBarHidden(hidden, animated: animated)
        setNeedsStatusBarAppearanceUpdate()
    }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        return .slide
    }

    override var prefersStatusBarHidden: Bool {
        // Keep status bar visible on iPad to avoid safe area changes when navbar toggles
        if UIDevice.current.userInterfaceIdiom == .pad {
            return false
        }
        return navigationBarHidden
    }

    // ----------------------------------------------------------------------------
    // MARK: - TOC / Bookmarks

    private func shouldPresentAsPopover() -> Bool {
        return UIDevice.current.userInterfaceIdiom == .pad
    }

    @objc func presentPositionsVC() {
        let currentLocation = navigator.currentLocation
        let positionsVC = TPPReaderPositionsVC.newInstance()

        positionsVC.tocBusinessLogic = TPPReaderTOCBusinessLogic(r2Publication: publication,
                                                                 currentLocation: currentLocation)
        positionsVC.bookmarksBusinessLogic = bookmarksBusinessLogic
        positionsVC.pageListBusinessLogic = TPPReaderPageListBusinessLogic(publication: publication)
        positionsVC.delegate = self

        if shouldPresentAsPopover() {
            positionsVC.modalPresentationStyle = .popover
            positionsVC.popoverPresentationController?.barButtonItem = tocBarButton
            present(positionsVC, animated: true) {
                // Makes sure that the popover is dismissed also when tapping on one of
                // the other UIBarButtonItems.
                // ie. http://karmeye.com/2014/11/20/ios8-popovers-and-passthroughviews
                positionsVC.popoverPresentationController?.passthroughViews = nil
            }
        } else {
            navigationController?.pushViewController(positionsVC, animated: true)
        }
    }

    @objc func toggleBookmark() {
        guard let loc = bookmarksBusinessLogic.currentLocation(in: navigator) else {
            return
        }

        if let bookmark = bookmarksBusinessLogic.isBookmarkExisting(at: loc) {
            deleteBookmark(bookmark)
        } else {
            addBookmark(at: loc)
        }
    }

    private func addBookmark(at location: TPPBookmarkR3Location) {
        Task { @MainActor in
            guard let bookmark = await bookmarksBusinessLogic.addBookmark(location) else {
                let alert = TPPAlertUtils.alert(title: "Bookmarking Error",
                                                message: "A bookmark could not be created on the current page.")
                TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert,
                                                             viewController: self,
                                                             animated: true,
                                                             completion: nil)
                return
            }

            Log.info(#file, "Created bookmark: \(bookmark)")

            updateBookmarkButton(withState: true)
            playBookmarkAddedFeedback()
        }
    }

    /// Add-only confirmation: a pref-gated light haptic plus a brief bounce on
    /// the bookmark button. Fired ONLY from the successful add path — deleting a
    /// bookmark and the passive re-light in `locationDidChange` do not call this.
    ///
    /// `addSymbolEffect(.bounce)` is only available for SF Symbol images; the
    /// bookmark keeps its custom asset (avoids an icon redesign), so the
    /// confirmation bounces the button view's transform instead — the same
    /// "pop" read. The haptic goes through `AccessibilityService` (preference +
    /// reduce-motion gated), never a raw `UIImpactFeedbackGenerator`.
    /// Single funnel for the reader's haptics. Both the bookmark confirmation
    /// and the scrubber's chapter-crossing tick go through here, so the
    /// preference- and reduce-motion gating lives in exactly one place.
    func triggerReaderHaptic(_ type: HapticType) {
        Task { await AccessibilityService.shared.triggerHaptic(type) }
    }

    private func playBookmarkAddedFeedback() {
        triggerReaderHaptic(.lightImpact)

        guard Self.shouldAnimateBookmarkBounce(reduceMotion: UIAccessibility.isReduceMotionEnabled),
              let button = bookmarkButton else {
            return
        }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseOut], animations: {
            button.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
        }, completion: { _ in
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn]) {
                button.transform = .identity
            }
        })
    }

    /// Pure gate: the confirmation bounce plays only when Reduce Motion is off.
    static func shouldAnimateBookmarkBounce(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    private func deleteBookmark(_ bookmark: TPPReadiumBookmark) {
        bookmarksBusinessLogic.deleteBookmark(bookmark)
        didDeleteBookmark(bookmark)
    }

    private func didDeleteBookmark(_ bookmark: TPPReadiumBookmark) {
        // at this point the bookmark has already been removed, so we just need
        // to verify that the user is not at the same location of another bookmark,
        // in which case the bookmark icon will be lit up and should stay lit up.
        if
            let loc = bookmarksBusinessLogic.currentLocation(in: navigator),
            bookmarksBusinessLogic.isBookmarkExisting(at: loc) == nil {

            updateBookmarkButton(withState: false)
        }
    }

    // ----------------------------------------------------------------------------
    // MARK: - Accessibility

    private lazy var accessibilityToolbar: UIToolbar = {
        // Swift 6 `complete`: a nested local `func` does NOT inherit the enclosing
        // type's `@MainActor` isolation, so its `UIBarButtonItem` / `accessibilityLabel`
        // (both `@MainActor`) uses would cross into the main actor. This toolbar is
        // built lazily on the main thread (UIKit view setup), so annotating the
        // helper `@MainActor` is the honest isolation-only fix — no hop, no behavior
        // change.
        @MainActor
        func makeItem(_ item: UIBarButtonItem.SystemItem, label: String? = nil, action: UIKit.Selector? = nil) -> UIBarButtonItem {
            let button = UIBarButtonItem(barButtonSystemItem: item, target: (action != nil) ? self : nil, action: action)
            button.accessibilityLabel = label
            return button
        }

        let toolbar = UIToolbar(frame: .zero)
        let forwardButton = makeItem(.fastForward, label: DisplayStrings.nextChapter, action: #selector(goForward))
        let backButton = makeItem(.rewind, label: DisplayStrings.previousChapter, action: #selector(goBackward))

        toolbar.items = [
            backButton,
            makeItem(.flexibleSpace),
            forwardButton
        ]
        toolbar.isHidden = !isVoiceOverRunning
        toolbar.tintColor = UIColor.black
        return toolbar
    }()

    private var isVoiceOverRunning = UIAccessibility.isVoiceOverRunning

    @objc func voiceOverStatusDidChange() {
        let isRunning = UIAccessibility.isVoiceOverRunning
        // Avoids excessive settings refresh when the status didn't change.
        guard isVoiceOverRunning != isRunning else {
            return
        }
        updateViewsForVoiceOver(isRunning: isRunning)
    }

    func updateViewsForVoiceOver(isRunning: Bool) {
        isVoiceOverRunning = isRunning
        updateNavigationBar()
        accessibilityToolbar.isHidden = !isRunning
        // Route the overlay labels through the shared visibility rule so their
        // alpha is reset and their hidden-state tracks the immersive-mode logic
        // (prevents a prior fade-out from leaving them alpha 0 when re-shown).
        updateOverlayLabelsVisibility(animated: false)

        // Adjust bottom inset for accessibility toolbar
        if let scrollView = (navigator.view as? UIScrollView) ?? navigator.view.subviews.compactMap({ $0 as? UIScrollView }).first {
            if isRunning {
                // Ensure layout is up to date to get correct toolbar height
                view.layoutIfNeeded()
                let toolbarHeight = accessibilityToolbar.frame.height
                scrollView.contentInset.bottom = toolbarHeight
                scrollView.scrollIndicatorInsets.bottom = toolbarHeight
            } else {
                scrollView.contentInset.bottom = 0
                scrollView.scrollIndicatorInsets.bottom = 0
            }
        }

        if isRunning {
            UIAccessibility.post(notification: .layoutChanged, argument: navigationController?.navigationBar)
        }
    }

    @objc private func goBackward() {
        manualNavigationPending = true
        Task {
            await navigator.goBackward(options: NavigatorGoOptions(animated: false))
        }
    }

    @objc private func goForward() {
        manualNavigationPending = true
        Task {
            await navigator.goForward(options: NavigatorGoOptions(animated: false))
        }
    }

    // MARK: - Subclass Hooks

    /// Called after the navigator location updates.
    /// Subclasses can override to react to page changes.
    func didChangeLocation(_ locator: Locator) {}

    // MARK: - Keyboard Handling

    @MainActor
    func handleKeyboardCommand(_ command: ReaderKeyboardCommand) {
        switch command {
        case .goBackward:
            manualNavigationPending = true
            Task { @MainActor in
                await navigator.goBackward(options: NavigatorGoOptions(animated: false))
            }
        case .goForward:
            manualNavigationPending = true
            Task { @MainActor in
                await navigator.goForward(options: NavigatorGoOptions(animated: false))
            }
        case .toggleUI:
            toggleNavigationBar()
        }
    }
}

// ------------------------------------------------------------------------------
// MARK: - NavigatorDelegate

extension TPPBaseReaderViewController: NavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        Task {
            Log.info(#function, "R3 locator changed to: \(locator)")

            // Save location here only if VoiceOver is not running; it doesn't save exact location on page
            if !isVoiceOverRunning {
                lastReadPositionPoster.storeReadPosition(locator: locator)
            }

            positionLabel.text = await {
                var chapterTitle = ""
                if let title = locator.title {
                    chapterTitle = " (\(title))"
                }

                var positions: [Locator] = []

                let result = await publication.positions()
                switch result {
                case .success(let locators):
                    positions = locators
                case .failure(let error):
                    moduleDelegate?.presentError(error, from: self)
                }

                if let position = locator.locations.position {
                    return String(format: Strings.TPPBaseReaderViewController.pageOf, position) + "\(positions.count)" + chapterTitle
                } else if let progression = locator.locations.totalProgression {
                    return "\(progression)%" + chapterTitle
                } else {
                    return nil
                }
            }()

            bookTitleLabel.text = publication.metadata.title

            // Keep the scrubber's thumb on the patron's real position. The
            // control ignores this while a drag is in flight, so a location
            // update cannot yank the thumb out from under a finger.
            if let progression = locator.locations.totalProgression {
                chapterScrubber?.setProgression(progression, animated: true)
            }

            if let resourceIndex = publication.resourceIndex(forLocator: locator),
               bookmarksBusinessLogic.isBookmarkExisting(at: TPPBookmarkR3Location(resourceIndex: resourceIndex, locator: locator)) != nil {
                updateBookmarkButton(withState: true)
            } else {
                updateBookmarkButton(withState: false)
            }

            self.didChangeLocation(locator)
        }
    }

    func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
        // SFSafariViewController crashes when given an URL without an HTTP scheme.
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }
        present(SFSafariViewController(url: url), animated: true)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        moduleDelegate?.presentError(error, from: self)
    }

    func navigator(_ navigator: any ReadiumNavigator.Navigator, didFailToLoadResourceAt href: ReadiumShared.RelativeURL, withError error: ReadiumShared.ReadError) {
        moduleDelegate?.presentError(error, from: self)
    }
}

// ------------------------------------------------------------------------------
// MARK: - VisualNavigatorDelegate

extension TPPBaseReaderViewController: VisualNavigatorDelegate {

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        // Subclasses using Readium's input observer system handle taps there.
        // Skip the legacy delegate path to avoid double-toggling the toolbar.
        guard !usesInputObserversForTapHandling else { return }

        let viewport = navigator.view.bounds
        let thresholdRange = 0...(0.2 * viewport.width)

        manualNavigationPending = true
        Task {
            var moved = false
            if thresholdRange ~= point.x {
                moved = await navigator.goLeft(options: NavigatorGoOptions(animated: false))
            } else if thresholdRange ~= (viewport.maxX - point.x) {
                moved = await navigator.goRight(options: NavigatorGoOptions(animated: false))
            }

            if !moved {
                manualNavigationPending = false
                toggleNavigationBar()
            }
        }
    }
}

// ------------------------------------------------------------------------------
// MARK: - TPPReaderPositionsDelegate

extension TPPBaseReaderViewController: @preconcurrency TPPReaderPositionsDelegate {
    func positionsVC(_ positionsVC: TPPReaderPositionsVC, didSelectTOCLocation loc: Any) {
        if shouldPresentAsPopover() {
            positionsVC.dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }

        Task {
            if let location = loc as? Locator {
                await navigator.go(to: location)
            }
        }
    }

    func positionsVC(_ positionsVC: TPPReaderPositionsVC,
                     didSelectBookmark bookmark: TPPReadiumBookmark) {

        if shouldPresentAsPopover() {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }

        Task {
            let r3bookmark = bookmark.convertToR3(from: publication)
            if let locator = r3bookmark?.locator {
                await navigator.go(to: locator)
            }
        }
    }

    func positionsVC(_ positionsVC: TPPReaderPositionsVC,
                     didDeleteBookmark bookmark: TPPReadiumBookmark) {
        didDeleteBookmark(bookmark)
    }

    func positionsVC(_ positionsVC: TPPReaderPositionsVC,
                     didRequestSyncBookmarksWithCompletion completion: @escaping (_ success: Bool, _ bookmarks: [TPPReadiumBookmark]) -> Void) {
        bookmarksBusinessLogic.syncBookmarks(completion: completion)
    }

    func positionsVC(_ positionsVC: TPPReaderPositionsVC,
                     didSelectPageLocation location: Any, pageLabel: String) {
        if shouldPresentAsPopover() {
            positionsVC.dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }

        Task {
            guard let locator = location as? Locator else { return }
            await navigator.go(to: locator)
            // VoiceOver arrival announcement so a non-sighted patron hears which
            // print page they landed on (nav-110).
            let announcement = String(format: Strings.TPPBaseReaderViewController.navigatedToPage, pageLabel)
            await MainActor.run {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
    }
}

// ------------------------------------------------------------------------------
// MARK: - First Responder

extension TPPBaseReaderViewController {
    /// Allow this view controller to become first responder for keyboard input
    override var canBecomeFirstResponder: Bool { true }
}
