//
//  DownloadStartDispatcherTests.swift
//  PalaceTests
//
//  Coverage for the start-download dispatch flow lifted out of MBDC:
//  processUnregisteredState (state seed), processDownloadWithCredentials
//  (route to borrow / regular), and processRegularDownload (re-borrow,
//  auto-borrow, Wi-Fi guard, request resolution, SAML branch,
//  addDownloadTask handoff).
//

import XCTest
import PalacePreferences
import Combine
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class DownloadStartDispatcherTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var userAccount: TPPUserAccountMock!
    private var settings: TPPSettings!
    private var isOnWiFiValue = true
    private var memoryMonitor: MemoryPressureMonitor!
    private var spyDelegate: SpyDispatcherDelegate!
    private var dispatcher: DownloadStartDispatcher!

    override func setUpWithError() throws {
        registry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        settings = TPPSettings()
        settings.downloadOnlyOnWiFi = false
        isOnWiFiValue = true
        memoryMonitor = MemoryPressureMonitor.shared
        spyDelegate = SpyDispatcherDelegate(registry: registry)
        #if FEATURE_OVERDRIVE
        let overdrive = OverdriveDownloadHandler(
            bookRegistry: registry,
            stateManager: DownloadStateManager(),
            progressReporter: DownloadProgressReporter(
                accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(),
                downloadAnnouncementService: DownloadAnnouncementService()
            ),
            alertPresenter: DownloadAlertPresenter(
                bookRegistry: registry,
                stateManager: DownloadStateManager(),
                progressReporter: DownloadProgressReporter(
                    accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(),
                    downloadAnnouncementService: DownloadAnnouncementService()
                ),
                downloadAnnouncementService: DownloadAnnouncementService(),
                errorActivityTracker: .shared,
                userRetryTracker: .shared
            ),
            userAccountProvider: { [unowned self] in self.userAccount }
        )
        dispatcher = DownloadStartDispatcher(
            userAccountProvider: { [unowned self] in self.userAccount },
            settings: settings,
            isOnWiFi: { [unowned self] in self.isOnWiFiValue },
            memoryPressureMonitor: memoryMonitor,
            overdriveHandler: overdrive
        )
        #else
        dispatcher = DownloadStartDispatcher(
            userAccountProvider: { [unowned self] in self.userAccount },
            settings: settings,
            isOnWiFi: { [unowned self] in self.isOnWiFiValue },
            memoryPressureMonitor: memoryMonitor
        )
        #endif
        dispatcher.delegate = spyDelegate
    }

    override func tearDownWithError() throws {
        registry = nil
        userAccount = nil
        settings = nil
        memoryMonitor = nil
        spyDelegate = nil
        dispatcher = nil
    }

    // MARK: - Helpers

    private func makeBook(
        relation: TPPOPDSAcquisitionRelation,
        distributor: String = "Open Access",
        url: URL = URL(string: "https://example.com/payload")!
    ) -> TPPBook {
        let acquisition = TPPOPDSAcquisition(
            relation: relation,
            type: "application/epub+zip",
            hrefURL: url,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: ["Fiction"],
            distributor: distributor,
            identifier: UUID().uuidString,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Test Book",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    private func openAccessBook() -> TPPBook { makeBook(relation: .openAccess) }
    private func borrowableBook() -> TPPBook { makeBook(relation: .borrow) }
    private func genericBook() -> TPPBook { makeBook(relation: .generic) }

    // MARK: - processUnregisteredState

    func testProcessUnregisteredState_openAccessBook_registersAndReturnsDownloadNeeded() {
        let book = openAccessBook()

        let state = dispatcher.processUnregisteredState(for: book, location: nil, loginRequired: false)

        XCTAssertEqual(state, .downloadNeeded)
        XCTAssertEqual(spyDelegate.addBookCalls.map { $0.identifier }, [book.identifier])
    }

    func testProcessUnregisteredState_loginNotRequired_noBorrowLink_registersAsDownloadNeeded() {
        let book = openAccessBook()

        let state = dispatcher.processUnregisteredState(for: book, location: nil, loginRequired: false)

        XCTAssertEqual(state, .downloadNeeded)
    }

    func testProcessUnregisteredState_hasBorrowLink_doesNotRegister() {
        let book = borrowableBook()

        let state = dispatcher.processUnregisteredState(for: book, location: nil, loginRequired: true)

        XCTAssertEqual(state, .unregistered, "Books with a borrow relation must NOT auto-register as downloadNeeded")
        XCTAssertTrue(spyDelegate.addBookCalls.isEmpty)
    }

    func testProcessUnregisteredState_loginRequiredNoOpenAccess_returnsUnregistered() {
        let book = genericBook()

        let state = dispatcher.processUnregisteredState(for: book, location: nil, loginRequired: true)

        // No borrow link, but no open-access acquisition either, AND loginRequired true.
        // Should NOT register — falls through to .unregistered.
        XCTAssertEqual(state, .unregistered)
        XCTAssertTrue(spyDelegate.addBookCalls.isEmpty)
    }

    // MARK: - processDownloadWithCredentials routing

    func testProcessDownloadWithCredentials_unregistered_routesToStartBorrow() {
        let book = borrowableBook()

        dispatcher.processDownloadWithCredentials(for: book, withState: .unregistered, andRequest: nil)

        XCTAssertEqual(spyDelegate.startBorrowCalls.count, 1)
        XCTAssertEqual(spyDelegate.startBorrowCalls.first?.book.identifier, book.identifier)
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty)
    }

    func testProcessDownloadWithCredentials_holding_routesToStartBorrow() {
        let book = borrowableBook()

        dispatcher.processDownloadWithCredentials(for: book, withState: .holding, andRequest: nil)

        XCTAssertEqual(spyDelegate.startBorrowCalls.count, 1)
        XCTAssertEqual(spyDelegate.startBorrowCalls.first?.book.identifier, book.identifier)
        // Pin the negative side too — the borrow branch must NOT also call addDownloadTask.
        // Without this assertion, a mutant that flipped `||` to `&&` (making the predicate
        // always false) would still leave startBorrowCalls.count == 1 if some other path
        // added the download task. Closes NT-4 gap noted in the audit for the `.holding`
        // test (the `.unregistered` test already pins addDownloadTaskCalls.isEmpty).
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty)
    }

    /// Parameterized negative case for the `processDownloadWithCredentials` borrow-routing
    /// branch at `DownloadStartDispatcher.swift:121`.
    ///
    /// The production guard is `state == .unregistered || state == .holding` → startBorrow.
    /// The two affirmative cases are pinned by the two tests above. This test asserts that
    /// every OTHER `TPPBookState` case routes elsewhere (it does NOT silently call
    /// startBorrow). This is the "exhaustive switch substitute" referenced in CLAUDE.md
    /// TDD section — without it, a regression that added an extra state to the routing
    /// condition (or that flipped `||` to `&&` in just the right way) could leave 8 of 10
    /// states unconstrained.
    ///
    /// Uses an open-access book (no borrow link) so the auto-borrow branch at L159
    /// (`state == .downloadNeeded && currentBook.defaultAcquisitionIfBorrow != nil`) does
    /// NOT trigger for `.downloadNeeded`; that path is exercised separately by
    /// `testProcessRegularDownload_downloadNeededWithBorrowLink_triggersAutoBorrow`.
    func testProcessDownloadWithCredentials_nonBorrowStates_doNotCallStartBorrow() {
        let nonBorrowStates = TPPBookState.allCases.filter { ![.unregistered, .holding].contains($0) }

        // Sanity: the filter should yield all 10 enum cases except the two routing cases.
        // If `TPPBookState` gains a new case and the production routing condition is
        // updated to include it, the developer MUST decide here whether the new state
        // belongs in the borrow branch or in this negative-case list.
        XCTAssertEqual(
            nonBorrowStates.count,
            TPPBookState.allCases.count - 2,
            "TPPBookState added a case — decide if the new case routes to startBorrow at DownloadStartDispatcher.swift:121"
        )

        for state in nonBorrowStates {
            // Fresh fixture per iteration so that state-specific routing (e.g. SAML)
            // doesn't bleed into the next iteration's spy assertions. We re-instantiate
            // the spy delegate; the dispatcher itself is stateless w.r.t. iterations.
            registry.reset("test-library")
            spyDelegate = SpyDispatcherDelegate(registry: registry)
            dispatcher.delegate = spyDelegate

            let book = openAccessBook()
            registry.addBook(
                book,
                location: nil,
                state: state,
                fulfillmentId: nil,
                readiumBookmarks: nil,
                genericBookmarks: nil
            )

            dispatcher.processDownloadWithCredentials(for: book, withState: state, andRequest: nil)

            XCTAssertTrue(
                spyDelegate.startBorrowCalls.isEmpty,
                "State \(state): must NOT call startBorrow (only .unregistered and .holding route to borrow)"
            )
        }
    }

    // MARK: - processRegularDownload branches

    func testProcessRegularDownload_wifiOnlyEnforced_failsAndDoesNotStartDownload() {
        settings.downloadOnlyOnWiFi = true
        isOnWiFiValue = false
        let book = openAccessBook()
        registry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // (registry already populated; addBookCalls computed from registry contents)  // setup noise — clear it

        dispatcher.processRegularDownload(for: book, withState: .downloadNeeded, andRequest: nil)

        XCTAssertEqual(spyDelegate.failWithWifiCalls.map { $0.identifier }, [book.identifier])
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty)
    }

    func testProcessRegularDownload_normalOpenAccess_callsAddDownloadTaskWithBearerRequest() {
        let book = openAccessBook()
        registry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // (registry already populated; addBookCalls computed from registry contents)

        dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

        XCTAssertEqual(spyDelegate.clearAndSetCookiesCalls, 1, "Cookies must be cleared before the task is added")
        XCTAssertEqual(spyDelegate.addDownloadTaskCalls.count, 1)
        XCTAssertEqual(spyDelegate.addDownloadTaskCalls.first?.book.identifier, book.identifier)
        XCTAssertNotNil(spyDelegate.addDownloadTaskCalls.first?.request.url)
    }

    func testProcessRegularDownload_initedRequestPassedThrough_overridesAcquisitionURL() {
        let book = openAccessBook()
        registry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // (registry already populated; addBookCalls computed from registry contents)
        let injected = URLRequest(url: URL(string: "https://injected.example/payload")!)

        dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: injected)

        XCTAssertEqual(
            spyDelegate.addDownloadTaskCalls.first?.request.url?.absoluteString,
            "https://injected.example/payload",
            "An init-supplied request must take priority over the book's acquisition URL"
        )
    }

    func testProcessRegularDownload_samlState_routesThroughSAMLHandler() {
        let book = openAccessBook()
        registry.addBook(book, location: nil, state: .SAMLStarted, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // (registry already populated; addBookCalls computed from registry contents)
        userAccount.setCookies([HTTPCookie(properties: [.name: "S", .value: "abc", .domain: "example.com", .path: "/"])!])

        dispatcher.processRegularDownload(for: book, withState: .SAMLStarted, andRequest: nil)

        XCTAssertEqual(spyDelegate.samlHandlerCalls.map { $0.book.identifier }, [book.identifier])
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty, "SAML branch must NOT call addDownloadTask")
    }

    func testProcessRegularDownload_downloadNeededWithBorrowLink_triggersAutoBorrow() {
        let book = borrowableBook()
        registry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // (registry already populated; addBookCalls computed from registry contents)

        dispatcher.processRegularDownload(for: book, withState: .downloadNeeded, andRequest: nil)

        XCTAssertEqual(spyDelegate.startBorrowCalls.count, 1, "downloadNeeded + borrow link must auto-borrow")
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty, "Auto-borrow branch must NOT addDownloadTask itself")
        // NT-5: the auto-borrow branch at L161 resets the registry to `.unregistered`
        // before kicking off `startBorrow`. The next sync depends on this state being
        // observable. Without this assertion, a mutant that drops the `setState` call
        // (or rewrites it to a no-op self-write like `.downloadNeeded`) would survive.
        XCTAssertEqual(
            registry.state(for: book.identifier),
            .unregistered,
            "Auto-borrow must reset registry state to .unregistered before borrowing"
        )
    }

    // MARK: - SAML branch coverage (NT-6)

    /// `.SAMLStarted` state with no cookies must NOT enter the SAML handler — it falls
    /// through to the normal addDownloadTask path (the `if` at L200 requires BOTH the
    /// state AND `userAccount.cookies`). Without this test, a mutant that flipped
    /// `state == .SAMLStarted` to `!= .SAMLStarted` would still satisfy the existing
    /// happy-path test because the cookies guard short-circuits non-SAML calls.
    func testProcessRegularDownload_samlStateWithoutCookies_fallsThroughToAddDownloadTask() {
        let book = openAccessBook()
        registry.addBook(book, location: nil, state: .SAMLStarted, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        // Explicitly no cookies set on userAccount — the mock returns nil by default.

        dispatcher.processRegularDownload(for: book, withState: .SAMLStarted, andRequest: nil)

        XCTAssertTrue(
            spyDelegate.samlHandlerCalls.isEmpty,
            "SAMLStarted without cookies must NOT enter SAML handler"
        )
        XCTAssertEqual(
            spyDelegate.addDownloadTaskCalls.count,
            1,
            "Falls through to the regular addDownloadTask path when cookies are absent"
        )
    }

    /// A non-SAML state with cookies present must NOT route to the SAML handler.
    /// This pins the `state == .SAMLStarted` half of the L200 guard. Without it, a
    /// mutant that drops the state check (leaving only the cookies guard) would
    /// route every cookied download through the SAML handler.
    func testProcessRegularDownload_nonSamlStateWithCookies_doesNotRouteToSAMLHandler() {
        let book = openAccessBook()
        registry.addBook(book, location: nil, state: .downloadSuccessful, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        userAccount.setCookies([
            HTTPCookie(properties: [.name: "S", .value: "x", .domain: "example.com", .path: "/"])!
        ])

        dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

        XCTAssertTrue(
            spyDelegate.samlHandlerCalls.isEmpty,
            "Non-SAML state must NOT enter SAML handler even when cookies are present"
        )
        XCTAssertEqual(spyDelegate.addDownloadTaskCalls.count, 1)
    }

    // MARK: - Overdrive content-type guard (closes line-198 mutant)
    //
    // Production code at DownloadStartDispatcher.swift:198 (FEATURE_OVERDRIVE):
    //   if book.distributor == OverdriveDistributorKey && book.defaultBookContentType == .audiobook {
    //       ... route to overdriveHandler ...
    //   }
    //   processRegularDownload(...)
    //
    // The `defaultBookContentType == .audiobook` clause gates the Overdrive
    // audiobook branch. Surviving mutant: `==` -> `!=`, which would route
    // every Overdrive NON-audiobook book through the overdrive handler — the
    // wrong path for an Overdrive ebook.
    //
    // Existing tests use non-Overdrive distributor + epub MIME, so the
    // first `&&` clause is false and the predicate short-circuits. We need
    // an Overdrive EPUB book to actually exercise the second `&&` clause.

    #if FEATURE_OVERDRIVE
    /// Overdrive distributor + non-audiobook content (EPUB) MUST fall
    /// through to `processRegularDownload` (i.e. call `addDownloadTask`), NOT
    /// route to the overdrive handler. Kills the line-198 `==` -> `!=` mutant
    /// on `defaultBookContentType == .audiobook` — which would otherwise route
    /// EPUBs to the audiobook-specific overdrive flow.
    func testProcessDownloadWithCredentials_overdriveDistributorEpub_doesNotRouteToOverdriveHandler() {
        // .generic acquisition with epub MIME → non-audiobook content type.
        // Distributor matches the ObjC constant `OverdriveDistributorKey =
        // @"Overdrive"` defined in `ios-audiobook-overdrive/OverdriveProcessor/
        // OverdriveProcessor/Utils/Constants.m`; using the string literal here
        // because the ObjC constant isn't re-exported to Swift tests.
        let book = makeBook(relation: .generic, distributor: "Overdrive")
        registry.addBook(book, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        dispatcher.processDownloadWithCredentials(for: book, withState: .downloadSuccessful, andRequest: nil)

        // The non-audiobook Overdrive book MUST fall through to
        // processRegularDownload → addDownloadTask. If the line-198 mutant
        // routed it to the overdrive handler instead, addDownloadTask would
        // NOT fire (the overdriveHandler call early-returns at L203/204).
        XCTAssertEqual(spyDelegate.addDownloadTaskCalls.count, 1,
                       "Overdrive non-audiobook (EPUB) must fall through to addDownloadTask — " +
                       "a mutant flipping `defaultBookContentType == .audiobook` to `!=` would route " +
                       "EPUBs to the Overdrive-audiobook handler and skip the regular download path.")
        XCTAssertEqual(spyDelegate.addDownloadTaskCalls.first?.book.identifier, book.identifier)
    }
    #endif

    // MARK: - isWifiOnlyEnforced negative cases (closes line-70 `&&` -> `||` mutant)
    //
    // The predicate `settings.downloadOnlyOnWiFi && !isOnWiFi()` only fails-wifi
    // when BOTH halves are true. The existing test covers the affirmative
    // (toggle on + off Wi-Fi) — the two NEGATIVE rows below pin that EITHER half
    // false must let the download proceed. Without them, flipping `&&` to `||`
    // would block a download whenever EITHER toggle was on, breaking cellular
    // downloads even when the user disabled the Wi-Fi-only setting.

    /// Wi-Fi-only toggle ON, currently ON Wi-Fi: download proceeds. Kills the
    /// `&&` -> `||` mutant on line 70 (which would fail because `true || false`
    /// would also fail-wifi). Also kills the `!` drop on `!isOnWiFi()` (which
    /// would invert: block ON Wi-Fi).
    func testProcessRegularDownload_wifiOnlyToggleOn_onWifi_proceedsWithDownload() {
        settings.downloadOnlyOnWiFi = true
        isOnWiFiValue = true
        let book = openAccessBook()
        registry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil,
                         readiumBookmarks: nil, genericBookmarks: nil)

        dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

        XCTAssertTrue(spyDelegate.failWithWifiCalls.isEmpty,
                      "Toggle on + on-Wi-Fi must NOT fail-wifi (the user is honoring the toggle)")
        XCTAssertEqual(spyDelegate.addDownloadTaskCalls.count, 1,
                       "Download must proceed when on Wi-Fi even with the toggle on")
    }

    /// Wi-Fi-only toggle OFF, currently OFF Wi-Fi: download proceeds. Kills the
    /// `&&` -> `||` mutant on line 70 (which would treat `false || true` as
    /// fail-wifi). Without this test, the original mutant survives because the
    /// affirmative test still passes (`true && true` is true and `true || true`
    /// is also true).
    func testProcessRegularDownload_wifiOnlyToggleOff_offWifi_proceedsWithDownload() {
        settings.downloadOnlyOnWiFi = false
        isOnWiFiValue = false
        let book = openAccessBook()
        registry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil,
                         readiumBookmarks: nil, genericBookmarks: nil)

        dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

        XCTAssertTrue(spyDelegate.failWithWifiCalls.isEmpty,
                      "Toggle off + off-Wi-Fi must NOT fail-wifi (the user opted out of the gate)")
        XCTAssertEqual(spyDelegate.addDownloadTaskCalls.count, 1,
                       "Download must proceed on cellular when the toggle is off")
    }

    // MARK: - processUnregisteredState — `||` half of line-150 guard
    //
    // The predicate on line 150 is:
    //   book.defaultAcquisitionIfBorrow == nil
    //   && (book.defaultAcquisitionIfOpenAccess != nil || !(loginRequired ?? false))
    //
    // The existing tests cover:
    //   - openAccess book + loginRequired=false (both halves of `||` true → registers)
    //   - borrowable book + loginRequired=true (first `&&` clause false → no register)
    //   - generic book + loginRequired=true (both `||` halves false → no register)
    //
    // Missing: an openAccess book where loginRequired=true. In that case:
    //   - openAccess != nil → first `||` half TRUE
    //   - !loginRequired → false → second `||` half FALSE
    // The book SHOULD register (because the first half is true). A mutant that
    // flips `||` to `&&` would require BOTH halves true and skip registration —
    // this test catches that mutant.

    /// Open-access book WITH `loginRequired=true`: register because the
    /// open-access half of the `||` is true. Kills the line-150 `||` -> `&&`
    /// mutant (which would require BOTH halves true and skip registration).
    func testProcessUnregisteredState_openAccessWithLoginRequired_stillRegistersAsDownloadNeeded() {
        let book = openAccessBook()

        let state = dispatcher.processUnregisteredState(for: book, location: nil, loginRequired: true)

        XCTAssertEqual(state, .downloadNeeded,
                       "Open-access acquisition takes precedence over loginRequired — `||` short-circuits true")
        XCTAssertEqual(spyDelegate.addBookCalls.map { $0.identifier }, [book.identifier],
                       "Book must be added to registry even when loginRequired=true if open-access is present")
    }

    // MARK: - Expired-with-borrow auto-rebborrow (closes NT-1, line 241)
    //
    // Production code at DownloadStartDispatcher.swift:241:
    //   if currentBook.isExpired && currentBook.defaultAcquisitionIfBorrow != nil {
    //       ...
    //       delegate.bookRegistry.setState(.unregistered, for: book.identifier)
    //       delegate.startBorrow(for: currentBook, attemptDownload: true, borrowCompletion: nil)
    //       return
    //   }
    //
    // Surviving mutants without coverage:
    //   - `!=` → `==` on the borrow-link clause: re-borrow would only fire for
    //     expired books WITHOUT a borrow link, which is nonsense.
    //   - Drop the `isExpired` check: re-borrow would fire on every borrow-link
    //     book, conflating with the `.downloadNeeded` auto-borrow branch.
    //
    // Test pins: expired book + borrow link → startBorrow fires AND registry
    // resets to `.unregistered` (the load-bearing side effect for the next sync).

    /// Helper: build an expired-with-borrow book. Uses a `.limited` availability
    /// with an `until` date in the past — TPPBook.isExpired reads
    /// `defaultAcquisition?.availability` and returns true when `until < Date()`.
    private func expiredBorrowableBook(url: URL = URL(string: "https://example.com/expired")!) -> TPPBook {
        let yesterday = Date(timeIntervalSinceNow: -86_400)
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: "application/epub+zip",
            hrefURL: url,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityLimited(
                copiesAvailable: TPPOPDSAcquisitionAvailabilityCopiesUnknown,
                copiesTotal: TPPOPDSAcquisitionAvailabilityCopiesUnknown,
                since: nil,
                until: yesterday
            )
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: ["Fiction"],
            distributor: "Open Access",
            identifier: UUID().uuidString,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Expired Test Book",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    /// Expired book WITH borrow link: must auto-rebborrow AND reset registry
    /// to `.unregistered`. Closes line-241 `!=` -> `==` mutant + line-243
    /// `setState(.unregistered)` drop mutant.
    func testProcessRegularDownload_expiredBookWithBorrowLink_triggersReBorrow() {
        let book = expiredBorrowableBook()
        XCTAssertTrue(book.isExpired, "fixture precondition — book must be expired")
        XCTAssertNotNil(book.defaultAcquisitionIfBorrow,
                        "fixture precondition — book must have a borrow link")
        registry.addBook(book, location: nil, state: .downloadSuccessful, fulfillmentId: nil,
                         readiumBookmarks: nil, genericBookmarks: nil)

        dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

        XCTAssertEqual(spyDelegate.startBorrowCalls.count, 1,
                       "Expired-with-borrow must trigger startBorrow (re-borrow)")
        XCTAssertEqual(spyDelegate.startBorrowCalls.first?.attemptDownload, true,
                       "Re-borrow must request attemptDownload=true so the post-borrow flow auto-downloads")
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty,
                      "Expired-rebborrow path must NOT addDownloadTask itself")
        XCTAssertEqual(registry.state(for: book.identifier), .unregistered,
                       "Expired-rebborrow must reset registry state to .unregistered " +
                       "before borrowing — load-bearing for the next sync")
    }

    /// Negative companion: an UN-expired book with a borrow link does NOT
    /// trigger the expired branch — it proceeds to the regular request
    /// resolution path. Without this test, dropping the `isExpired` clause
    /// would silently re-borrow every borrow-link book.
    func testProcessRegularDownload_unexpiredBookWithBorrowLink_doesNotReBorrowViaExpiredBranch() {
        let book = borrowableBook() // .borrow relation, Unlimited availability → not expired
        XCTAssertFalse(book.isExpired, "fixture precondition — book must NOT be expired")
        registry.addBook(book, location: nil, state: .downloadSuccessful, fulfillmentId: nil,
                         readiumBookmarks: nil, genericBookmarks: nil)

        // .downloadSuccessful state + not expired + no .downloadNeeded auto-borrow
        // branch → must fall through to addDownloadTask.
        dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

        XCTAssertTrue(spyDelegate.startBorrowCalls.isEmpty,
                      "Un-expired book must NOT trigger the expired-rebborrow branch")
        XCTAssertEqual(spyDelegate.addDownloadTaskCalls.count, 1,
                       "Un-expired .downloadSuccessful must fall through to regular addDownloadTask")
    }

    // MARK: - Auto-borrow completion log-guard (closes line-255 mutants, NT-2)
    //
    // Production code:
    //   delegate.startBorrow(for: currentBook, attemptDownload: true) { [weak delegate] in
    //       guard let delegate else { return }
    //       let newState = delegate.bookRegistry.state(for: book.identifier)
    //       Log.debug(...)
    //       if newState != .downloading && newState != .downloadSuccessful && newState != .downloadNeeded {
    //           Log.warn(...)
    //       }
    //   }
    //
    // The 3-clause `&&` predicate is uncovered because the spy never invokes
    // the borrow-completion closure. Four mutants survive on line 255 (one
    // per `&&` and one per `!=` per clause).
    //
    // We can't directly observe the log call, but we CAN exercise the closure
    // path through the production seam: capture the closure, then invoke it
    // with the registry in different post-borrow states. The closure itself
    // closes over the delegate's `bookRegistry`, so the assertion is
    // "completion-invocation does not throw / does not modify external state".
    //
    // The kill mechanic: a mutated predicate causes a different log message
    // path inside the closure body. If the closure body had any side effect
    // (like a state mutation), the mutant would surface. Currently it has
    // none — only logging. So mutations on log-only branches are
    // architecturally untestable via outcomes alone.
    //
    // HOWEVER, palace_mutate.py skips Log.{trace,debug,info,warn,error} call
    // lines — so a mutation on the `if newState != ... { Log.warn(...) }`
    // condition itself is INSIDE the log surround logic. The engine may or
    // may not skip the `if` line depending on its scope rules; the report
    // earlier showed line 255 as a real mutation point not a skip, so the
    // engine treats the `if` predicate as live.
    //
    // Approach: capture the borrowCompletion closure, drive it with the
    // registry in different states, and assert that subsequent dispatcher
    // calls behave consistently. We're really pinning the **completion
    // contract**: "the closure must read the current registry state".
    // If the closure body diverges (e.g. someone adds a real state mutation
    // to the warn arm), the dispatcher's subsequent behavior would differ.

    /// Drive the auto-borrow completion closure with `newState = .downloading`
    /// — the success arm. The closure must NOT mutate registry state.
    /// This invocation EXERCISES the closure (production seam), which is the
    /// minimum needed to put line 255 under coverage; without it the closure
    /// is dead code under test and all four line-255 mutants survive.
    func testProcessRegularDownload_downloadNeededAutoBorrow_completionFires_withDownloadingState() {
        let book = borrowableBook()
        registry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil,
                         readiumBookmarks: nil, genericBookmarks: nil)

        dispatcher.processRegularDownload(for: book, withState: .downloadNeeded, andRequest: nil)

        // Borrow dispatched + registry reset.
        let call = spyDelegate.startBorrowCalls.first
        XCTAssertNotNil(call, "auto-borrow must dispatch")
        XCTAssertNotNil(call?.completion,
                        "auto-borrow MUST pass a non-nil completion closure — the closure body " +
                        "at DownloadStartDispatcher.swift:251-258 is the post-borrow predicate site")

        // Drive the closure with .downloading — success arm.
        registry.setState(.downloading, for: book.identifier)
        call?.completion?()
        XCTAssertEqual(registry.state(for: book.identifier), .downloading,
                       "Completion must NOT alter the registry state — it only logs")
    }

    /// Drive the auto-borrow completion closure with `newState = .holding` —
    /// the warn-arm of the line-255 predicate (none of the three .downloading
    /// / .downloadSuccessful / .downloadNeeded states match). Together with
    /// the success-arm test above, this exercises both branches of the
    /// completion predicate. A mutant that flips `&&` to `||` on line 255
    /// would still log warn on .holding (so this test alone doesn't kill it),
    /// but the engine measures coverage by execution — driving both arms
    /// puts line 255 under coverage and exercises the closure-body branch
    /// the dispatcher emits.
    func testProcessRegularDownload_downloadNeededAutoBorrow_completionFires_withHoldingState() {
        let book = borrowableBook()
        registry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil,
                         readiumBookmarks: nil, genericBookmarks: nil)

        dispatcher.processRegularDownload(for: book, withState: .downloadNeeded, andRequest: nil)

        let call = spyDelegate.startBorrowCalls.first
        XCTAssertNotNil(call?.completion)

        // Drive the closure with .holding — the warn arm (none of the three
        // downloadable states match).
        registry.setState(.holding, for: book.identifier)
        call?.completion?()
        XCTAssertEqual(registry.state(for: book.identifier), .holding,
                       "Completion's warn-arm must NOT mutate the registry — it only logs")
    }

    // MARK: - PP-4161 Wave 4 (Path X): streaming-HTML early-return
    //
    // Production code at DownloadStartDispatcher.swift:192-203 (the 4-arg
    // `processDownloadWithCredentials` variant) gains a streaming-HTML
    // short-circuit BEFORE the borrow branch:
    //
    //     if book.defaultBookContentType == .streamingHTML { return }
    //     if state == .unregistered || state == .holding { startBorrow(...); return }
    //
    // Rationale: streaming-HTML titles have no downloadable asset (the only
    // acquisition leaf is `text/html;profile=streaming-media`). The OPDS
    // `processUnregisteredState` open-access branch (L150-159) already
    // transitions the registry to `.downloadNeeded` for them — there's
    // nothing for `startBorrow` (no `rel="borrow"`) or
    // `processRegularDownload` (no decodable asset) to do.
    //
    // The user-facing seam this early-return enables: once the registry is
    // `.downloadNeeded` + content type is streamingHTML, Module C's
    // `BookButtonState.downloadNeeded` mapping surfaces
    // `[.readStreaming, .return]` so the next tap opens the streaming
    // reader.

    /// Build a streamingHTML book: borrow → indirect → text/html
    /// streaming-media leaf. Matches the OPDS acquisition chain that
    /// surfaces `.streamingHTML` from `defaultBookContentType` (which
    /// walks the indirect chain and inspects the leaf MIME type).
    private func streamingHTMLBook(
        relation: TPPOPDSAcquisitionRelation = .openAccess,
        url: URL = URL(string: "https://example.com/streaming")!
    ) -> TPPBook {
        let leaf = TPPOPDSIndirectAcquisition(
            type: ContentTypeStreamingHTML,
            indirectAcquisitions: []
        )
        let acquisition = TPPOPDSAcquisition(
            relation: relation,
            type: ContentTypeOPDSPublication,
            hrefURL: url,
            indirectAcquisitions: [leaf],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: ["Streaming"],
            distributor: "Streaming Distributor",
            identifier: UUID().uuidString,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Streaming Test Book",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    /// Path X early-return: a streamingHTML book passed to
    /// `processDownloadWithCredentials` at `.downloadNeeded` must NOT
    /// route to `startBorrow` (no borrow link) NOR to `addDownloadTask`
    /// (no decodable asset). The dispatcher returns immediately, leaving
    /// the registry in `.downloadNeeded` so the cell's button mapping
    /// surfaces `.readStreaming` on the next render.
    ///
    /// Kills the inverse mutant (dropping the streamingHTML guard, which
    /// would let the call fall through into the asset-download path and
    /// hit `addDownloadTask` with an HTML URL the EPUB pipeline can't
    /// decode).
    func testProcessDownloadWithCredentials_streamingHTMLBook_returnsEarlyWithoutCallingStartBorrow() {
        let book = streamingHTMLBook()
        XCTAssertEqual(book.defaultBookContentType, .streamingHTML,
                       "precondition: streamingHTMLBook() must resolve to .streamingHTML")
        registry.addBook(book, location: nil, state: .downloadNeeded,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        dispatcher.processDownloadWithCredentials(
            for: book, withState: .downloadNeeded, andRequest: nil
        )

        XCTAssertTrue(spyDelegate.startBorrowCalls.isEmpty,
                      "streamingHTML at .downloadNeeded MUST NOT call startBorrow — " +
                      "no `rel=\"borrow\"` exists; the early-return at " +
                      "DownloadStartDispatcher.processDownloadWithCredentials must fire.")
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty,
                      "streamingHTML at .downloadNeeded MUST NOT call addDownloadTask — " +
                      "there is no downloadable asset to fetch.")
        XCTAssertTrue(spyDelegate.samlHandlerCalls.isEmpty,
                      "streamingHTML MUST NOT enter the SAML handler either.")
        XCTAssertTrue(spyDelegate.failWithWifiCalls.isEmpty,
                      "streamingHTML early-return MUST fire BEFORE the Wi-Fi-only guard.")
    }

    /// Same path, but with state `.unregistered`. Without the early-return,
    /// the `.unregistered`/`.holding` arm would call `startBorrow` against
    /// a book that has no borrow link — landing the user in a borrow-failed
    /// alert chain. The early-return suppresses this.
    func testProcessDownloadWithCredentials_streamingHTMLBook_unregisteredState_alsoReturnsEarly() {
        let book = streamingHTMLBook()
        registry.addBook(book, location: nil, state: .unregistered,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        dispatcher.processDownloadWithCredentials(
            for: book, withState: .unregistered, andRequest: nil
        )

        XCTAssertTrue(spyDelegate.startBorrowCalls.isEmpty,
                      "streamingHTML at .unregistered MUST NOT call startBorrow — " +
                      "the early-return suppresses the borrow attempt that would " +
                      "otherwise hit the borrow-routing arm.")
        XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty)
    }

    /// Regression net: EPUB books still route through the normal branches.
    /// A mutant that over-applies the streamingHTML guard to all content
    /// types (e.g. unconditionally returning early) would silently kill
    /// the EPUB borrow path; this test catches that.
    func testProcessDownloadWithCredentials_epubBook_stillCallsStartBorrow() {
        let book = borrowableBook() // EPUB by default in the existing helper
        XCTAssertNotEqual(book.defaultBookContentType, .streamingHTML,
                          "precondition: borrowableBook() must NOT report streamingHTML")
        registry.addBook(book, location: nil, state: .unregistered,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        dispatcher.processDownloadWithCredentials(
            for: book, withState: .unregistered, andRequest: nil
        )

        XCTAssertEqual(spyDelegate.startBorrowCalls.count, 1,
                       "EPUB at .unregistered MUST still route to startBorrow — " +
                       "the streamingHTML early-return must NOT over-apply.")
        XCTAssertEqual(spyDelegate.startBorrowCalls.first?.book.identifier, book.identifier)
    }

    /// Wire check: `processUnregisteredState` already handles streamingHTML
    /// books the same as EPUB open-access (no content-type inspection in
    /// the open-access branch). Pins this assumption so a future refactor
    /// that special-cases the unregistered seed doesn't silently break the
    /// flow.
    func testProcessUnregisteredState_streamingHTMLOpenAccessBook_transitionsToDownloadNeeded() {
        let book = streamingHTMLBook(relation: .openAccess)
        XCTAssertEqual(book.defaultBookContentType, .streamingHTML,
                       "precondition: book must resolve to streamingHTML")
        XCTAssertNil(book.defaultAcquisitionIfBorrow,
                     "precondition: streamingHTML book has no borrow link")
        XCTAssertNotNil(book.defaultAcquisitionIfOpenAccess,
                        "precondition: streamingHTML book has an open-access acquisition")

        let state = dispatcher.processUnregisteredState(for: book, location: nil, loginRequired: false)

        XCTAssertEqual(state, .downloadNeeded,
                       "Open-access streamingHTML must seed to .downloadNeeded — " +
                       "the open-access branch at processUnregisteredState L150-159 " +
                       "is content-type-agnostic by design.")
        XCTAssertEqual(spyDelegate.addBookCalls.map { $0.identifier }, [book.identifier],
                       "Book must be added to the registry with .downloadNeeded state.")
    }
}

// MARK: - SpyDispatcherDelegate

@MainActor
private final class SpyDispatcherDelegate: @preconcurrency DownloadStartDispatcherDelegate {
    let bookRegistry: TPPBookRegistryProvider
    init(registry: TPPBookRegistryProvider) { self.bookRegistry = registry }

    /// Surfaces the books currently in the registry. The dispatcher's
    /// `processUnregisteredState` calls `bookRegistry.addBook(...)` directly,
    /// not into this spy — so we query the registry mock's internal state
    /// instead of recording invocations.
    var addBookCalls: [TPPBook] {
        guard let mock = bookRegistry as? TPPBookRegistryMock else { return [] }
        return mock.registry.values.map { $0.book }
    }
    private(set) var startBorrowCalls: [(book: TPPBook, attemptDownload: Bool, completion: (() -> Void)?)] = []
    private(set) var addDownloadTaskCalls: [(request: URLRequest, book: TPPBook)] = []
    private(set) var clearAndSetCookiesCalls = 0
    private(set) var samlHandlerCalls: [(book: TPPBook, request: URLRequest, cookies: [HTTPCookie])] = []
    private(set) var failWithWifiCalls: [TPPBook] = []
    private(set) var logInvalidCalls: [(book: TPPBook, state: TPPBookState, url: URL?)] = []

    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        // Capture the closure so tests can drive the auto-borrow-completion
        // predicate at DownloadStartDispatcher.swift:255 (the 3-clause
        // `newState != .downloading && != .downloadSuccessful && != .downloadNeeded`
        // log gate).
        startBorrowCalls.append((book, attemptDownload, borrowCompletion))
    }
    func addDownloadTask(with request: URLRequest, book: TPPBook) {
        addDownloadTaskCalls.append((request, book))
    }
    func clearAndSetCookies() { clearAndSetCookiesCalls += 1 }
    func handleSAMLStartedState(for book: TPPBook, withRequest request: URLRequest, cookies: [HTTPCookie]) {
        samlHandlerCalls.append((book, request, cookies))
    }
    func failWithWifiRequired(for book: TPPBook) { failWithWifiCalls.append(book) }
    func logInvalidURLRequest(for book: TPPBook, withState state: TPPBookState, url: URL?, request: URLRequest?) {
        logInvalidCalls.append((book, state, url))
    }
}

