//
//  CriticalScreensVoiceOverAuditTests.swift
//  PalaceTests
//
//  VoiceOver audit of the catalog lane, book detail, EPUB reader chrome and
//  audiobook player: every expected control is reachable, labelled, and a
//  double-tap reaches its handler, proven by a witness rather than the
//  activation call's return value. Shaped after #819 (double-tap that did
//  nothing) and #811 (missing narrator label). Not covered: WKWebView page
//  content, swipe order, rotors, anything behind sign-in.
//

import XCTest
import SwiftUI
import UIKit
import ReadiumShared
import PalaceAudiobookToolkit
@testable import Palace
import PalaceBookModel
import PalaceUtilities

@MainActor
final class CriticalScreensVoiceOverAuditTests: XCTestCase {

    private var host: AccessibilityAuditHost?

    override class func tearDown() {
        MainActor.assumeIsolated { AccessibilityRuntime.restore() }
        super.tearDown()
    }

    override func tearDown() {
        host?.tearDown()
        host = nil
        // No NoNetworkURLProtocol enable/disable here: PalaceTestSetup registers
        // it once for the whole run, and a disable() would unregister it for
        // every test that follows.
        super.tearDown()
    }

    // MARK: - Catalog lane

    func testCatalogLane_everyControlIsReachableLabeledAndDoubleTapOpensItsOwnBook() {
        let gatsby = TPPBookMocker.mockBook(identifier: "a11y-lane-gatsby", title: "The Great Gatsby", authors: "F. Scott Fitzgerald")
        let audiobook = TPPBookMocker.snapshotAudiobook()
        let untitled = TPPBookMocker.mockBook(identifier: "a11y-lane-untitled", title: "Untitled Work", authors: nil)
        var selected: [String] = []
        var moreTapped: [String] = []

        let lane = CatalogLaneRowView(
            title: "Staff Picks",
            books: [gatsby, audiobook, untitled],
            moreURL: URL(string: "https://example.com/lanes/staff-picks"),
            onSelect: { selected.append($0.identifier) },
            onMoreTapped: { title, _ in moreTapped.append(title) }
        )
        let host = mount(UIHostingController(rootView: lane))

        let moreLabel = String(format: Strings.Generic.moreBooksInLane, "Staff Picks")
        let report = auditScreen(
            "Catalog lane",
            host: host,
            witnesses: [
                moreLabel: { moreTapped == ["Staff Picks"] },
                gatsby.voiceOverLabel: { selected.last == gatsby.identifier },
                audiobook.voiceOverLabel: { selected.last == audiobook.identifier },
                untitled.voiceOverLabel: { selected.last == untitled.identifier }
            ]
        )

        XCTAssertEqual(selected, [gatsby.identifier, audiobook.identifier, untitled.identifier],
                       "each cover's double-tap must open that cover's book, once, in lane order")
        let heading = report.element(labeled: "Staff Picks")
        XCTAssertNotNil(heading, "the lane title must be reachable")
        XCTAssertTrue(heading?.traits.contains(.header) ?? false,
                      "the lane title must be a heading so the VoiceOver heading rotor can jump between lanes")
    }

    // MARK: - Book detail

    func testBookDetail_everyControlIsReachableLabeledAndActivates() {
        let (container, coordinator) = makeDetailContainer()
        coordinator.push(.catalogLaneMore(title: "Staff Picks", url: URL(string: "https://example.com/lanes/staff-picks")!))
        let book = TPPBookMocker.snapshotEPUB()

        let root = NavigationStack { BookDetailView(book: book) }
            .environment(\.appContainer, container)
        let host = mount(UIHostingController(rootView: root))
        host.settle(0.6)

        let helpLabel = "Get Help — chat with our support bot"
        auditScreen(
            "Book detail",
            host: host,
            witnesses: [
                Strings.BookDetailView.more.capitalized: {
                    AccessibilityTraversalAudit.traverse(host.window)
                        .contains { $0.label == Strings.BookDetailView.less.capitalized }
                },
                Strings.Generic.goBack: { coordinator.path.isEmpty },
                helpLabel: { host.window.rootViewController?.presentedViewController != nil }
            ],
            // `BookDetailView(book:)` builds its view model from
            // `AppContainer.production()`, whose download center uses its own
            // URLSession: a double-tap on Borrow would start a real borrow and
            // download. Borrow is still checked for reachability, label and
            // frame; its activation is not fired.
            notFired: [Strings.BookButton.borrow],
            resetAfterActivation: { host.dismissPresented() }
        )
    }

    // MARK: - EPUB reader chrome

    func testEPUBReaderChrome_withVoiceOverChromeShown_everyControlIsReachableLabeledAndActivates() throws {
        let hub = NavigationCoordinatorHub(tabRouterHub: nil)
        let coordinator = NavigationCoordinator()
        hub.register(coordinator, for: nil)
        coordinator.push(.catalogLaneMore(title: "Staff Picks", url: URL(string: "https://example.com/lanes/staff-picks")!))

        let publication = Publication(manifest: Manifest(
            metadata: Metadata(title: "Reader Chrome Fixture", languages: ["en"]),
            readingOrder: [Link(href: "chapter1.xhtml", mediaType: .xhtml)]
        ))
        let reader = try TPPEPUBViewController(
            publication: publication,
            book: TPPBookMocker.snapshotEPUB(),
            initialLocation: nil,
            navigationHub: hub
        )
        let nav = UINavigationController(rootViewController: reader)
        let host = mount(nav)
        // A sighted tap reveals the navigation bar; VoiceOver adds the
        // previous/next chapter toolbar. `UIAccessibility.isVoiceOverRunning`
        // cannot be set from a test, so both are driven through the same
        // entry points the reader uses.
        reader.toggleNavigationBar()
        reader.updateViewsForVoiceOver(isRunning: true)
        host.settle(0.6)
        reader.manualNavigationPending = false

        let bookmarkStrings = Strings.TPPBaseReaderViewController.self
        auditScreen(
            "EPUB reader chrome",
            host: host,
            witnesses: [
                // Previous/next chapter hand off to the Readium navigator
                // asynchronously; their handlers mark a manual navigation
                // before doing so, which is the witness (the one-chapter
                // fixture has nowhere to turn to).
                bookmarkStrings.previousChapter: { reader.manualNavigationPending },
                bookmarkStrings.nextChapter: { reader.manualNavigationPending },
                Strings.Generic.goBack: { coordinator.path.isEmpty },
                Strings.Generic.searchInBook: { reader.presentedViewController != nil },
                Strings.Generic.tableOfContents: { nav.viewControllers.count == 2 },
                Strings.TPPEPUBViewController.readerSettings: { reader.presentedViewController != nil },
                // The fixture book is not in the registry, so saving the
                // bookmark fails and the reader shows its "Bookmarking Error"
                // alert. Either that alert or the flipped label proves the
                // double-tap reached `toggleBookmark`.
                bookmarkStrings.addBookmark: {
                    host.settle(0.7)
                    return nav.presentedViewController is UIAlertController
                        || AccessibilityTraversalAudit.traverse(host.window)
                            .contains { $0.label == bookmarkStrings.removeBookmark }
                }
            ],
            resetAfterActivation: {
                reader.manualNavigationPending = false
                host.dismissPresented()
                nav.popToRootViewController(animated: false)
                host.settle(0.2)
                // Returning from the table of contents re-hides the bar (the
                // reader's immersive default). VoiceOver keeps it visible via
                // `isVoiceOverRunning`, which a test cannot set, so show it the
                // way a tap would.
                for _ in 0..<2 where nav.isNavigationBarHidden {
                    reader.toggleNavigationBar()
                    host.settle(0.1)
                }
                reader.updateViewsForVoiceOver(isRunning: true)
            }
        )
    }

    // MARK: - Audiobook player

    func testAudiobookFullPlayer_everyControlIsReachableLabeledAndActivates() {
        let (presenter, session) = makeAudiobookPresenter()
        presenter.expand()
        let host = mountPlayer(presenter, session)
        host.settle(0.8)

        let generic = Strings.Generic.self
        auditScreen(
            "Audiobook player (full)",
            host: host,
            witnesses: [
                generic.close: { session.stopPlaybackCallCount == 1 },
                generic.minimizePlayer: { !presenter.isPlayerExpanded },
                generic.tableOfContents: { host.window.rootViewController?.presentedViewController != nil },
                generic.skipBackSeconds(Self.backSkip): { session.skipBackCallCount == 1 },
                generic.playAudiobook: { session.togglePlayPauseCallCount == 1 },
                generic.skipForwardSeconds(Self.forwardSkip): { session.skipForwardCallCount == 1 },
                generic.playbackSpeedValue(PlaybackRate.normalTime.displayLabel): { host.window.rootViewController?.presentedViewController != nil },
                generic.sleepTimer: { host.window.rootViewController?.presentedViewController != nil },
                generic.addBookmark: {
                    AccessibilityTraversalAudit.traverse(host.window).contains { $0.label == generic.bookmarkAdded }
                }
            ],
            // AirPlay is the system `AVRoutePickerView`; firing it opens the
            // system route picker, which the test cannot dismiss. It is still
            // checked for reachability, label and frame.
            notFired: [generic.airplay],
            resetAfterActivation: {
                host.dismissPresented()
                presenter.expand()
            }
        )
    }

    func testAudiobookMiniPlayer_everyControlIsReachableLabeledAndActivates() {
        let (presenter, session) = makeAudiobookPresenter()
        presenter.minimize()
        let host = mountPlayer(presenter, session)
        host.settle(0.8)

        let generic = Strings.Generic.self
        let book = TPPBookMocker.snapshotAudiobook()
        let nowPlaying = String(format: generic.nowPlayingLabelTitleAndAuthor, book.title, book.authors ?? "")
        auditScreen(
            "Audiobook player (mini)",
            host: host,
            witnesses: [
                // Closing from the mini bar asks for confirmation first (PP-4910).
                generic.closeAudiobookPlayer: { host.window.rootViewController?.presentedViewController is UIAlertController },
                nowPlaying: { presenter.isPlayerExpanded },
                generic.skipBackSeconds(Self.backSkip): { session.skipBackCallCount == 1 },
                generic.playAudiobook: { session.togglePlayPauseCallCount == 1 },
                generic.skipForwardSeconds(Self.forwardSkip): { session.skipForwardCallCount == 1 }
            ],
            resetAfterActivation: {
                host.dismissPresented()
                presenter.minimize()
            }
        )
    }

    /// The seek bar is the one way to move within a chapter. A VoiceOver user
    /// moves it by swiping up or down, which needs the `.adjustable` trait and
    /// an adjustable action that seeks the player (PP-5280).
    func testAudiobookFullPlayer_seekBarIsAdjustableWithVoiceOverSwipes() {
        let (presenter, session) = makeAudiobookPresenter()
        presenter.expand()
        let host = mountPlayer(presenter, session)
        host.settle(0.8)

        let seekBar = AccessibilityTraversalAudit.traverse(host.window)
            .first { $0.label == Strings.Generic.playbackPosition }
        XCTAssertNotNil(seekBar, "the seek bar must be reachable")
        guard let seekBar else { return }

        XCTAssertTrue(seekBar.traits.contains(.adjustable),
                      "VoiceOver users seek by swiping up/down on an adjustable element; traits were \(seekBar.traits.rawValue)")
        let spokenBefore = seekBar.object.accessibilityValue
        seekBar.object.accessibilityIncrement()
        host.settle(0.2)
        XCTAssertEqual(session.seekFractions.count, 1, "a VoiceOver swipe up must seek the player once")
        XCTAssertGreaterThan(session.seekFractions.last ?? 0, 0, "a swipe up from the chapter start must seek forward")
        let refreshed = AccessibilityTraversalAudit.traverse(host.window)
            .first { $0.label == Strings.Generic.playbackPosition }
        XCTAssertNotEqual(refreshed?.object.accessibilityValue, spokenBefore,
                          "the spoken value must follow the step, not wait for playback to catch up")
    }

    /// A 10:00 chapter with forward 45 s and back 10 s. Playback reports 4:50
    /// while the published fraction still reads 0.50 (the two are published
    /// separately), so the live-timecode and target branches of the spoken
    /// value differ. Swipe up moves +45 s, swipe down −10 s, and VoiceOver
    /// reads each target at once (PP-5280).
    func testAudiobookFullPlayer_seekBarSwipes_stepByEachDirectionsIntervalAndSpeakTheTarget() throws {
        let (presenter, session) = makeAudiobookPresenter()
        presenter.progress.chapterOffset = 290
        presenter.progress.chapterTimeLeft = 310
        presenter.progress.chapterProgress = 0.5
        presenter.expand()
        let host = mountPlayer(presenter, session)

        XCTAssertEqual(try seekBarValue(in: host), "50%, 4:50", "idle: VoiceOver reads the live timecode")

        let up = 0.5 + Double(Self.forwardSkip) / 600
        try seekBar(in: host).object.accessibilityIncrement()
        host.settle(0.2)
        XCTAssertEqual(session.seekFractions.first ?? -1, up, accuracy: 0.000_001, "swipe up moves by the forward interval")
        XCTAssertEqual(try seekBarValue(in: host), "57%, 5:45", "VoiceOver reads the target, not 4:50")

        let down = up - Double(Self.backSkip) / 600
        try seekBar(in: host).object.accessibilityDecrement()
        host.settle(0.2)
        XCTAssertEqual(session.seekFractions.count, 2)
        XCTAssertEqual(session.seekFractions.last ?? -1, down, accuracy: 0.000_001, "swipe down moves by the back interval")
        XCTAssertEqual(try seekBarValue(in: host), "55%, 5:35", "the target, rounded to the nearest second")
    }

    /// Before the chapter length is known there is no honest timecode, so
    /// VoiceOver reads the percentage alone rather than a made-up 0:00.
    func testAudiobookFullPlayer_seekBar_withUnknownChapterLength_speaksOnlyThePercentage() throws {
        let (presenter, session) = makeAudiobookPresenter()
        presenter.progress.chapterProgress = 0.5
        presenter.expand()
        let host = mountPlayer(presenter, session)

        XCTAssertEqual(try seekBarValue(in: host), "50%")
        try seekBar(in: host).object.accessibilityIncrement()
        host.settle(0.2)
        XCTAssertEqual(try seekBarValue(in: host), "55%", "the 5% fallback step, spoken without a timecode")
    }

    // MARK: - Helpers

    private func mount(_ controller: UIViewController) -> AccessibilityAuditHost {
        let host = AccessibilityAuditHost(controller)
        self.host = host
        return host
    }

    /// Audits one screen and fails the test for every violation, every
    /// expected control that is not reachable, and every fired control whose
    /// witness did not observe its effect.
    ///
    /// - Parameters:
    ///   - witnesses: expected actionable labels, each with a check that its
    ///     double-tap had the intended effect. Evaluated right after that
    ///     element is activated.
    ///   - notFired: expected actionable labels that are checked for
    ///     reachability, label and frame but not activated.
    ///   - resetAfterActivation: returns the screen to its audited state so
    ///     the next element is still on screen.
    @discardableResult
    private func auditScreen(
        _ screen: String,
        host: AccessibilityAuditHost,
        witnesses: [String: () -> Bool],
        notFired: Set<String> = [],
        resetAfterActivation: @escaping () -> Void = {},
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AXAuditReport {
        var observed: [String: Bool] = [:]
        let report = AccessibilityTraversalAudit.audit(
            screen: screen,
            root: host.window,
            window: host.window,
            activate: { !notFired.contains($0.label) },
            afterEachActivation: { element in
                host.settle(0.3)
                if let witness = witnesses[element.label] {
                    observed[element.label] = witness()
                }
                resetAfterActivation()
                host.settle(0.3)
            }
        )

        if report.elements.isEmpty {
            XCTFail("[\(screen)] the accessibility tree is empty; nothing was audited", file: file, line: line)
        }
        for violation in report.violations {
            XCTFail("\(violation)\n--- accessibility tree ---\n\(report.dump)", file: file, line: line)
        }

        let reachable = Set(report.actionable.map(\.label))
        for label in (Array(witnesses.keys) + Array(notFired)).sorted() where !reachable.contains(label) {
            XCTFail("[\(screen)] \"\(label)\" is not reachable as an actionable VoiceOver element\n--- accessibility tree ---\n\(report.dump)",
                    file: file, line: line)
        }

        for label in witnesses.keys.sorted() where reachable.contains(label) && observed[label] != true {
            XCTFail("[\(screen)] double-tap on \"\(label)\" did not produce its effect", file: file, line: line)
        }
        return report
    }

    private func makeDetailContainer() -> (AppContainer, NavigationCoordinator) {
        let base = makeTestAppContainer()
        let flags = MockFeatureFlagProvider()
        flags.isTriageBotEnabled = true
        let hub = NavigationCoordinatorHub(tabRouterHub: nil)
        let coordinator = NavigationCoordinator()
        hub.register(coordinator, for: nil)
        let container = AppContainer(
            bookRegistry: base.bookRegistry,
            networkExecutor: base.networkExecutor,
            networkQueue: base.networkQueue,
            reachability: base.reachability,
            accountsManager: base.accountsManager,
            settings: base.settings,
            featureFlags: flags,
            downloadCenter: base.downloadCenter,
            downloadAnnouncementService: base.downloadAnnouncementService,
            debugSettings: base.debugSettings,
            imageCache: base.imageCache,
            imageLoader: base.imageLoader,
            userAccountPublisher: base.userAccountPublisher,
            opdsFeedService: base.opdsFeedService,
            readerService: base.readerService,
            navigationCoordinatorHub: hub,
            tabRouterHub: base.tabRouterHub,
            drmAuthorizerProvider: base.drmAuthorizerProvider,
            authCoordinator: base.authCoordinator
        )
        return (container, coordinator)
    }

    private func makeAudiobookPresenter() -> (AudiobookSessionPresenter, SpyShimSession) {
        let session = SpyShimSession()
        let presenter = AudiobookSessionPresenter(sessionManager: session)
        presenter.adoptBook(TPPBookMocker.snapshotAudiobook())
        return (presenter, session)
    }

    /// Skip intervals pinned for every player test, distinct so a swapped
    /// forward/back argument cannot pass.
    private static let forwardSkip = 45
    private static let backSkip = 10

    /// Mounts the player with its `@AppStorage` reading an isolated suite
    /// holding `forwardSkip` / `backSkip`, never `UserDefaults.standard`.
    private func mountPlayer(_ presenter: AudiobookSessionPresenter, _ session: SpyShimSession) -> AccessibilityAuditHost {
        let suite = "a11y-audit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Self.forwardSkip, forKey: AudiobookSkipIntervalSettings.forwardKey)
        defaults.set(Self.backSkip, forKey: AudiobookSkipIntervalSettings.backKey)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let player = AudiobookMorphingPlayerView(
            presenter: presenter, progress: presenter.progress, audiobookSession: session)
            .defaultAppStorage(defaults)
        let host = mount(UIHostingController(rootView: player))
        host.settle(0.8)
        return host
    }

    private func seekBar(in host: AccessibilityAuditHost) throws -> AXAuditElement {
        try XCTUnwrap(AccessibilityTraversalAudit.traverse(host.window)
            .first { $0.label == Strings.Generic.playbackPosition }, "the seek bar must be reachable")
    }

    private func seekBarValue(in host: AccessibilityAuditHost) throws -> String? {
        try seekBar(in: host).object.accessibilityValue
    }
}

private extension AccessibilityAuditHost {
    func dismissPresented() {
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        settle(0.2)
    }
}
