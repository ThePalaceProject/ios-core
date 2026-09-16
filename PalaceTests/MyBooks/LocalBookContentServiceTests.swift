//
//  LocalBookContentServiceTests.swift
//  PalaceTests
//
//  Coverage for the local-content deletion paths extracted into
//  LocalBookContentService. Exercises both `deleteLocalContent`
//  overloads (identifier + book) across the epub / pdf / audiobook
//  / unsupported branches against a temp-dir BookFileManager.
//

import XCTest
import Combine
import PalaceCatalog
import PalacePreferences
import PalaceNetwork
@testable import Palace
import PalaceBookModel
import PalaceBookRegistry

@MainActor
final class LocalBookContentServiceTests: XCTestCase {

    private var tempDir: URL!
    private var registry: TPPBookRegistryMock!
    private var bookFileManager: SpyBookFileManager!
    private var service: LocalBookContentService!
    private var appContainer: AppContainer!
    /// Isolated UserDefaults suites created per test, removed in teardown so a
    /// preference cannot outlive the test that set it.
    private var isolatedSuiteNames: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalBookContentServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        appContainer = makeTestAppContainer()
        registry = TPPBookRegistryMock()
        bookFileManager = SpyBookFileManager(
            tempDir: tempDir,
            bookRegistry: registry,
            accountsManager: appContainer.accountsManager
        )
        service = LocalBookContentService(
            bookRegistry: registry,
            accountsManager: appContainer.accountsManager,
            bookFileManager: bookFileManager
        )
    }

    override func tearDownWithError() throws {
        for name in isolatedSuiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        isolatedSuiteNames = []
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        registry = nil
        bookFileManager = nil
        service = nil
        appContainer = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func writeFile(at url: URL, bytes: Int = 100) throws -> URL {
        try Data(repeating: 0xCC, count: bytes).write(to: url)
        return url
    }

    private func seedBook(_ book: TPPBook) {
        registry.addBook(book, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    }

    // MARK: - deleteLocalContent(for: identifier)

    func testDeleteForIdentifier_unknownIdentifier_logsAndDoesNothing() {
        // No book added — service should bail out without touching disk.
        // Drop a stray file so we can assert nothing got removed.
        let strayURL = tempDir.appendingPathComponent("stray.epub")
        try? Data(repeating: 0x00, count: 50).write(to: strayURL)

        service.deleteLocalContent(for: "nonexistent-id")

        XCTAssertTrue(FileManager.default.fileExists(atPath: strayURL.path),
                      "Unknown identifier must not delete unrelated files")
    }

    func testDeleteForIdentifier_lookUpsBookInRegistryAndDelegates() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        seedBook(book)

        let url = bookFileManager.fakeURLFor(book)
        try writeFile(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        service.deleteLocalContent(for: book.identifier)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Identifier-overload must resolve the book and delete its file")
    }

    // MARK: - deleteLocalContent(forBook:)

    func testDeleteForBook_epub_removesFileWhenPresent() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let url = bookFileManager.fakeURLFor(book)
        try writeFile(at: url)

        service.deleteLocalContent(forBook: book)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "epub branch must remove the file from disk")
    }

    func testDeleteForBook_epub_missingFile_logsButDoesNotThrow() {
        // No file written, just attempt deletion. The service catches
        // missing-file and continues — no XCTFail expected.
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        service.deleteLocalContent(forBook: book)
        // No assertion needed beyond "didn't crash" — the test passing
        // means the method handled the missing-file branch gracefully.
    }

    func testDeleteForBook_pdf_removesContentFile() throws {
        let book = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
        let url = bookFileManager.fakeURLFor(book)
        try writeFile(at: url)

        service.deleteLocalContent(forBook: book)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "pdf branch must remove the content file")
    }

    func testDeleteForBook_unresolvableFileURL_doesNotCrashAndLogsWarning() {
        // MISSING-001-OK: crash-guard — exercises the "Could not resolve fileUrl"
        // early-return; observable contract is "no crash, no exception, no side
        // effect on the file manager beyond the lookup attempt".
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        bookFileManager.failResolutionForIdentifier = book.identifier

        service.deleteLocalContent(forBook: book)

        // Tested implicitly — no crash, no exception. The warning log
        // path is hit per the implementation's `Log.warn`.
    }

    // MARK: - Per-account isolation

    func testDeleteForBook_accountOverride_passedThroughToBookFileManager() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let url = bookFileManager.fakeURLFor(book)
        try writeFile(at: url)

        service.deleteLocalContent(forBook: book, account: "explicit-account-id")

        XCTAssertEqual(bookFileManager.lastResolvedAccount, "explicit-account-id",
                       "Caller-supplied account must be threaded through to the file manager")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

#if LCP

    // MARK: - redownloadLCPContentFile: duplicate-transfer guard
    //
    // Two callers reach this method independently — the registry-load self-heal
    // (BookRegistrySync) and the open-time gate
    // (AudiobookSessionManager.gateOnLCPContentDownload) — and the only guard
    // used to be `fileExists`, which cannot see an in-flight transfer. On device
    // against A1QA that produced two concurrent full downloads of the same
    // 778 MB archive, one of which was stored and the other discarded.

    /// Builds a Marketplace LCP audiobook in the `/loans/` XML feed shape that
    /// `LCPAudiobooks.canOpenBook` actually accepts: the LCP *license* MIME on
    /// `defaultAcquisition`, with `application/audiobook+lcp` as the terminal
    /// indirect child so `defaultBookContentType` resolves to `.audiobook`.
    /// Mirrors the fixtures in `LCPAcquisitionPredicateTests`; a plain
    /// `application/audiobook+lcp` acquisition does NOT satisfy the predicate.
    private func makeLCPAudiobook() -> TPPBook {
        let lcpLicenseMIME = "application/vnd.readium.lcp.license.v1.0+json"
        let audiobookLCPMIME = "application/audiobook+lcp"
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: lcpLicenseMIME,
            hrefURL: URL(string: "https://library.test/book.lcpl")!,
            indirectAcquisitions: [
                TPPOPDSIndirectAcquisition(type: audiobookLCPMIME, indirectAcquisitions: [])
            ],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [],
            categoryStrings: [],
            distributor: "Test",
            identifier: UUID().uuidString,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "Test",
            subtitle: nil,
            summary: nil,
            title: "Test LCP Audiobook",
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

    /// Builds an LCP audiobook whose `.lcpl` license is on disk (so the
    /// license-lookup guard passes) and whose `.lcpa` content is absent (so the
    /// fileExists guard passes), i.e. the exact license-only state the
    /// re-download exists to repair.
    private func seedLicenseOnlyLCPAudiobook() throws -> TPPBook {
        let book = makeLCPAudiobook()
        seedBook(book)
        let contentURL = bookFileManager.fakeURLFor(book)
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        try writeFile(at: licenseURL, bytes: 2569)
        XCTAssertFalse(FileManager.default.fileExists(atPath: contentURL.path),
                       "precondition: content must be absent for the re-download to run")
        return book
    }

    private func makeService(
        fulfiller: SpyLCPContentFulfiller,
        reporter: SpyProgressReporter? = nil,
        idleTimeout: TimeInterval = LocalBookContentService.inflightContentDownloadIdleTimeout,
        clock: FakeClock? = nil
    ) -> LocalBookContentService {
        let service = LocalBookContentService(
            bookRegistry: registry,
            accountsManager: appContainer.accountsManager,
            bookFileManager: bookFileManager,
            lcpContentFulfiller: fulfiller.fulfill,
            inflightIdleTimeout: idleTimeout,
            monotonicClock: clock.map { c in { c.now } }
        )
        service.contentDownloadReporter = reporter
        return service
    }

    // MARK: - PP-5135 — a downloaded LCP audiobook must have its audio on disk

    /// The self-heal fetches the `.lcpa` whenever the book is left with only its
    /// `.lcpl` license, unconditionally.
    ///
    /// PP-4957 used to skip this while the streaming flag was ON, reasoning that
    /// a streaming LCP audiobook is "intentionally content-absent" because its
    /// license alone makes it playable. That holds only while the device is
    /// online, and the same book is reported to the patron as **Downloaded** — so
    /// going offline, which is the entire point of downloading, left the open
    /// with no audio behind it and it dead-ended in `PublicationOpenError`.
    /// Measured on device for PP-5135: every borrowed LCP audiobook had its
    /// `.lcpl` and not one `.lcpa`.
    ///
    /// Streaming keeps its benefit — playback starts immediately rather than
    /// waiting on a multi-gigabyte archive — because this fetch is a background
    /// transfer nobody blocks on.
    ///
    /// There is deliberately no flag-ON/flag-OFF pair here: the streaming seam
    /// was REMOVED from `LocalBookContentService`, so "skips the fetch while
    /// streaming" is now unrepresentable rather than merely untaken. A test
    /// asserting the other flag state could only pass a provider the type no
    /// longer has.
    func testRedownload_licenseOnly_fetchesTheArchiveSoTheBookWorksOffline() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 1,
                       "the .lcpa must land in the background, or the book cannot be played offline (PP-5135)")
        XCTAssertTrue(service.isContentDownloadInFlight(for: book.identifier),
                      "the transfer claimed its slot, so a concurrent trigger cannot start a duplicate")
    }

    /// PP-5135 regression: the fetch is SWALLOWED while the download center still
    /// reports a transfer for this book.
    ///
    /// This is the test that would have caught the first version of the fix. That
    /// version fired the trigger from inside `LCPFulfillmentHandler`, which runs
    /// while `bookIdentifierToDownloadInfo` still holds the fulfillment entry —
    /// so `downloadCenterHasTransfer` was true and `redownloadLCPContentFile`
    /// returned at "already transferring — skipping duplicate", fetching nothing
    /// on every fresh borrow. The tests written alongside it injected a SPY
    /// trigger, so they asserted the call and never the callee, and the guard
    /// that defeated the fix lived past the seam. Two reviewers caught it by
    /// reading; no test could.
    ///
    /// Asserting this from BOTH sides is the point: the guard must swallow the
    /// fetch when a transfer is live (or two producers duplicate a multi-hundred-
    /// megabyte archive), and must NOT swallow it once the transfer is cleared
    /// (or the book never gets its audio). A caller therefore has to fire after
    /// the download-completion cleanup, which is why the production trigger sits
    /// in `MyBooksDownloadCenter.startLCPContentFetchIfNeeded`.
    func testRedownload_whileDownloadCenterReportsATransfer_isSkipped() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)
        service.downloadCenterHasTransfer = { _ in true }

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 0,
                       "a live download-center transfer must suppress the fetch — two producers of one .lcpa is how a 778 MB archive got downloaded twice")
    }

    /// The other side of the same guard: once the download center no longer
    /// reports a transfer — i.e. after the completion cleanup — the identical
    /// call DOES fetch. Together with the test above this pins the timing
    /// requirement on the production caller rather than restating the guard.
    func testRedownload_afterTheTransferClears_fetches() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)
        service.downloadCenterHasTransfer = { _ in false }

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 1,
                       "with no transfer in flight the .lcpa must be fetched, or a borrowed audiobook never gets its audio (PP-5135)")
    }

    // MARK: - PP-5135: the download centre's trigger honours the WiFi preference

    /// The `MyBooksDownloadCenter` trigger site, not the audiobook one.
    ///
    /// Added because review found a SURVIVING MUTANT: deleting the
    /// `guard LocalBookContentService.backgroundFetchAllowed(...)` from
    /// `startLCPContentFetchIfNeeded` left all 71 tests green. The cube tests
    /// cover the pure rule, the gate test covers the AudiobookSessionManager
    /// site, and the placement lints check ordering — none of them touch the
    /// policy at THIS caller. Intent Claim E asserts "neither trigger site"
    /// starts a transfer against `downloadOnlyOnWiFi`; without these two tests
    /// that claim was true of one site and unverified at the other, which is
    /// exactly the cellular regression an earlier review round forced the guard
    /// into existence for.
    ///
    /// `TPPSettings` is built over an isolated UserDefaults suite (the pattern in
    /// `DownloadOnlyOnWiFiTests`) rather than `.standard`, so the preference
    /// cannot leak into or out of neighbouring tests.
    ///
    /// Named "whenNotOnWiFi" rather than "onCellular" because `isOnWiFi` is NOT
    /// driven here: `Reachability.isOnWiFi` is `public`, not `open`, across the
    /// PalaceNetwork boundary, so `MockReachability` cannot stub it and it reads
    /// an unstarted `NWPathMonitor` — measured as deterministically
    /// `.unsatisfied` -> false, not host-dependent. The preference is the input
    /// this test actually drives. Closing the gap needs an `isOnWiFi` seam; the
    /// precedent is `DownloadStartDispatcher.swift:62`, which takes
    /// `isOnWiFi: @escaping () -> Bool`.
    func testDownloadCentreFetch_whenNotOnWiFiAndWiFiOnlySet_doesNotFetch() async throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let center = try makeDownloadCentre(fulfiller: fulfiller,
                                            connected: true,
                                            downloadOnlyOnWiFi: true)

        await center.startLCPContentFetchIfNeeded(for: book, account: appContainer.accountsManager.currentAccountId ?? "", afterFailedDownload: false)

        XCTAssertEqual(fulfiller.callCount, 0,
                       "download-only-on-WiFi is a preference the patron set — the completion path must not pull a multi-hundred-megabyte archive over cellular (PP-5135)")
    }

    /// The inverse, so the test above cannot pass merely because the trigger
    /// never fires: with the preference off, the same call DOES fetch. Deleting
    /// the guard fails the test above; deleting the trigger fails this one.
    func testDownloadCentreFetch_whenPolicyAllows_fetches() async throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let center = try makeDownloadCentre(fulfiller: fulfiller,
                                            connected: true,
                                            downloadOnlyOnWiFi: false)

        // A DISTINCT account, not `accountsManager.currentAccountId`. Passing the
        // live value would make the assertion below tautological — it would hold
        // even if this method ignored its parameter and resolved the account
        // itself, which is precisely the defect PP-5146 exists to remove.
        await center.startLCPContentFetchIfNeeded(for: book, account: "pp5147-explicit-account", afterFailedDownload: false)

        XCTAssertEqual(fulfiller.callCount, 1,
                       "with the policy satisfied the .lcpa must be fetched, or a borrowed audiobook never gets its audio (PP-5135)")
        // EVERY resolution, in order — not just the last one. There are THREE on
        // this path, which is itself the finding: the missing-check, the licence
        // lookup, and the destination. I expected two, asserted two, and the
        // array came back `[pinned, nil, pinned]` — the licence was still being
        // resolved against the live library while the destination was pinned.
        // Asserting only the final value would not have shown that, and neither
        // would counting.
        XCTAssertEqual(bookFileManager.resolvedAccounts,
                       ["pp5147-explicit-account", "pp5147-explicit-account", "pp5147-explicit-account"],
                       "all three resolutions on the fetch path — missing-check, licence lookup, destination — must agree on the caller's library. A `nil` in any slot means that step re-resolved the current library for itself, which is the structure PP-5146 removes: the archive could be read from one library's directory and written into another's.")
    }

    /// PP-5148: a download that FAILED must not leave a multi-gigabyte transfer
    /// running behind the error the patron was just shown.
    ///
    /// The fetch sits at the end of `handleDownloadCompletion`, which both the
    /// success and the failure arms fall through to. For most failures the fetch
    /// stops on its own because no licence ever arrived — but a download can fail
    /// AFTER the licence lands, and then the app starts pulling the archive for a
    /// book it has just marked `.downloadFailed`. The patron sees an error, is
    /// told nothing about the transfer, and pays for the data.
    ///
    /// This drives the real completion path rather than calling the fetch
    /// directly: the guard lives in that body, and a test that called the fetch
    /// itself could not see it. A bare `fakeDownloadTask()` reports no MIME type,
    /// which the completion parser rejects outright — that is the failure arm.
    func testHandleDownloadCompletion_whenTheDownloadFailed_startsNoBackgroundFetch() async throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let stateManager = DownloadStateManager()
        let center = try makeDownloadCentre(fulfiller: fulfiller,
                                            connected: true,
                                            downloadOnlyOnWiFi: false,
                                            stateManager: stateManager)

        let task = fakeDownloadTask()
        await stateManager.taskIdentifierToBook.set(task.taskIdentifier, value: book)

        // Precondition: this book is exactly the shape that WOULD be fetched on a
        // success — licence present, archive absent. Without it the assertion
        // below would hold for the wrong reason.
        // The account the PRODUCTION call site computes, not a literal of my own.
        // A literal agrees only because the spy ignores the account, so the
        // precondition would keep passing if the two ever diverged — and a
        // precondition that cannot fail is the thing it is guarding against.
        let productionAccount = appContainer.accountsManager.currentAccountId ?? ""
        XCTAssertTrue(center.lcpContentFileMissing(for: book, account: productionAccount),
                      "precondition: the book must look fetchable, or this test passes even with the guard removed")

        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp5148-\(UUID().uuidString).bin")
        try Data("not a book".utf8).write(to: location)
        defer { try? FileManager.default.removeItem(at: location) }

        await center.handleDownloadCompletion(session: Self.inertSession(), task: task, location: location)

        XCTAssertEqual(fulfiller.callCount, 0,
                       "a failed download must not start a background .lcpa transfer. The patron has been shown an error and marked this book failed; quietly pulling gigabytes for it — on cellular, if their settings allow — is not something they agreed to (PP-5148).")
    }

    /// Builds a download centre whose settings, reachability and local-content
    /// service are all injected, so the policy decision is driven rather than
    /// inherited from the test host.
    private func makeDownloadCentre(fulfiller: SpyLCPContentFulfiller,
                                    connected: Bool,
                                    downloadOnlyOnWiFi: Bool,
                                    stateManager: DownloadStateManager? = nil) throws -> MyBooksDownloadCenter {
        let suiteName = "pp5135-\(UUID().uuidString)"
        let isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName),
                                             "could not create an isolated defaults suite")
        isolatedSuiteNames.append(suiteName)
        let settings = TPPSettings(defaults: isolatedDefaults)
        settings.downloadOnlyOnWiFi = downloadOnlyOnWiFi

        let service = makeService(fulfiller: fulfiller)
        if let stateManager {
            // The completion path reads the book back out of the state manager,
            // so a test that drives it must own the one the centre uses.
            return MyBooksDownloadCenter(
                bookRegistry: registry,
                accountsManager: appContainer.accountsManager,
                bookFileManager: bookFileManager,
                localContentService: service,
                stateManager: stateManager,
                reachability: MockReachability(initiallyConnected: connected),
                settings: settings,
                urlSession: Self.inertSession()
            )
        }
        return MyBooksDownloadCenter(
            bookRegistry: registry,
            accountsManager: appContainer.accountsManager,
            bookFileManager: bookFileManager,
            localContentService: service,
            reachability: MockReachability(initiallyConnected: connected),
            settings: settings
        )
    }

    /// A session that can never reach the network, so an accidental `.resume()`
    /// fails loudly instead of hanging the suite.
    private static func inertSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoNetworkURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - PP-5135: the fetch's PLACEMENT in the completion path

    /// The two tests above pin the guard. These pin the one CALLER whose position
    /// relative to that guard is the entire fix, and which no behavioural test in
    /// this target can reach.
    ///
    /// `MyBooksDownloadCenter.startLCPContentFetchIfNeeded` routes here, and the
    /// duplicate guard consults `downloadCenterHasTransfer` — `downloadInfo(for:)
    /// != nil`. That entry is live during fulfillment and cleared by
    /// `bookIdentifierToDownloadInfo.remove` in the download-completion cleanup.
    /// A fetch triggered BEFORE that removal is swallowed, silently, on every
    /// fresh borrow. That is exactly what the first revision of PP-5135 did; two
    /// reviewers caught it by reading the guard, and no test could, because every
    /// test injected a spy trigger and so asserted the call and never the callee.
    ///
    /// Asserted against the source text rather than by driving the method:
    /// The invariant is positional, not behavioural: the ordering is what makes
    /// the fetch reach its work, and ordering is not something a running test can
    /// observe. (`handleDownloadCompletion` itself IS drivable — see the PP-5148
    /// test above — so the earlier version of this note, which said it was not,
    /// was wrong about the reason even though a lint is still the right tool.) `PalaceTests/MetaTests/` pins
    /// wiring facts the same way for the same reason. Move the call five lines up
    /// and this fails while everything else stays green.
    func testContentFetchIsTriggeredAfterDownloadInfoIsCleared() throws {
        let source = try downloadCenterSource()
        let lines = source.components(separatedBy: .newlines)

        let fetchIndex = try XCTUnwrap(
            lines.firstIndex { $0.contains("startLCPContentFetchIfNeeded(") && !$0.contains("func ") },
            "the call to `startLCPContentFetchIfNeeded(` is gone. Without it a freshly borrowed LCP audiobook never fetches its .lcpa and cannot be played offline (PP-5135).")

        // The NEAREST PRECEDING removal, not `firstIndex`. There is more than one
        // `bookIdentifierToDownloadInfo.remove(` in this file, so anchoring on the
        // first one would let any earlier insertion satisfy the ordering while the
        // fetch sat above the removal that actually governs it.
        let removalIndex = try XCTUnwrap(
            lines[..<fetchIndex].lastIndex { $0.contains("bookIdentifierToDownloadInfo.remove(") },
            "no `bookIdentifierToDownloadInfo.remove(` appears ABOVE the fetch call. Either the cleanup moved below it — which reinstates the defect — or it was renamed, in which case re-point this lint at whatever now clears the transfer record rather than deleting it.")

        // Both lines must live in the SAME function. A `func ` between them means
        // the fetch is no longer downstream of that cleanup at all, and the
        // ordering above would be comparing positions in unrelated bodies.
        let interveningFunc = lines[removalIndex..<fetchIndex].first { $0.contains("    func ") || $0.contains("    private func ") }
        XCTAssertNil(interveningFunc,
            "a function boundary sits between the cleanup and the fetch — they are no longer in the same body, so the ordering this lint checks no longer means the fetch happens after the transfer record is cleared.")

        XCTAssertGreaterThan(fetchIndex, removalIndex,
            """
            startLCPContentFetchIfNeeded is called at line \(fetchIndex + 1), BEFORE \
            bookIdentifierToDownloadInfo.remove at line \(removalIndex + 1). At that \
            point downloadInfo(for:) is still non-nil, so redownloadLCPContentFile \
            returns at its duplicate-suppression guard and fetches nothing — the book \
            stays license-only while the shelf says "Downloaded", and offline playback \
            is impossible. Move the call back below the cleanup.
            """)
    }

    /// The ordering rule above was derived from this predicate. If the guard stops
    /// consulting `downloadInfo`, that derivation no longer holds and a green lint
    /// would be asserting a rule that does not bind any more.
    /// Pins WHICH account the download centre hands to the fetch.
    ///
    /// The expression is evaluated inside `handleDownloadCompletion`, and the
    /// account it produces is not observable from the outside: every path the
    /// completion takes resolves the same live value, so a test that drives the
    /// body cannot tell a correct id from a wrong one. Mutating it to `""`
    /// survives the whole suite — the gap QA raised on PP-5135.
    ///
    /// A correction worth recording, because the first version of this comment
    /// asserted it: the body is NOT unreachable. `DownloadReissuePersistenceTests`
    /// drives it at five call sites, and the PP-5148 test above drives it here.
    /// What is unreachable is the DISTINCTION — which is a different claim, and
    /// the one that actually justifies a lint. Reaching for "no test can call
    /// this" when the truth is "no test can tell the difference" is how an
    /// untested line gets excused instead of covered.
    ///
    /// So this asserts over source what the runtime cannot: that the call takes
    /// its account from the INJECTED `accountsManager`, not from
    /// `AccountsManager.shared` and not from a literal.
    func testContentFetchResolvesTheAccountFromTheInjectedManager() throws {
        let source = try downloadCenterSource()
        let lines = source.components(separatedBy: .newlines)

        // The call may wrap across lines, so read the whole argument list rather
        // than the first line of it. Keying on one line would make this lint fail
        // the moment someone reformatted a correct call — a guard that cries wolf
        // gets deleted, and then it guards nothing.
        let callIndex = try XCTUnwrap(
            lines.firstIndex { $0.contains("startLCPContentFetchIfNeeded(") && !$0.contains("func ") },
            "the call to `startLCPContentFetchIfNeeded(` is gone — see the ordering lint above.")
        let call = lines[callIndex..<min(callIndex + 6, lines.count)].joined(separator: " ")

        XCTAssertTrue(call.contains("accountsManager.currentAccountId"),
            """
            the fetch is no longer given the account from the INJECTED \
            `accountsManager`. Whatever it is given now decides which library's \
            directory the .lcpa is checked against and written into, so a patron \
            with two library cards can have the audio land where the book will \
            never find it. An empty string here is silently wrong, not a crash \
            (PP-5147). Actual call: \(call.trimmingCharacters(in: .whitespaces))
            """)

        // PP-5148's argument is mutation-invisible for the same reason the account
        // is, and worse: hardcoding it to `true` stops PP-5135 fetching for EVERY
        // successful borrow while the whole suite stays green. The success arm
        // cannot be driven here — a `fakeDownloadTask` reports no MIME type, so
        // the completion parser always takes the failure branch — so source is the
        // only place this can be pinned.
        XCTAssertTrue(call.contains("afterFailedDownload: failureRequiringAlert"),
            """
            the fetch no longer takes its failed/succeeded verdict from \
            `failureRequiringAlert`. A literal here is silent in both directions: \
            `true` disables the PP-5135 fix entirely and every test still passes; \
            `false` restores the PP-5148 defect, starting a multi-gigabyte transfer \
            behind an error the patron was just shown (PP-5148). \
            Actual call: \(call.trimmingCharacters(in: .whitespaces))
            """)

        XCTAssertFalse(call.contains("AccountsManager.shared"),
            "the fetch resolves its account through `AccountsManager.shared`. CLAUDE.md forbids `.shared` reads in new code, and a download centre wired to a different account in a test would resolve paths through the live singleton instead of its own.")
    }

    func testDuplicateGuardStillConsultsDownloadInfo() throws {
        let source = try downloadCenterSource()
        XCTAssertTrue(
            source.contains("downloadInfo(forBookIdentifier: identifier) != nil"),
            "`downloadCenterHasTransfer` no longer consults `downloadInfo` — re-derive the ordering rule pinned above before trusting this suite.")
    }

    private func downloadCenterSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MyBooks/
            .deletingLastPathComponent()  // PalaceTests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Palace/MyBooks/MyBooksDownloadCenter.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - PP-5135 background-fetch policy (pure)

    /// The Wi-Fi/connectivity rule, driven over the full input cube. A patron who
    /// set download-only-on-WiFi must not have a multi-hundred-megabyte archive
    /// pulled over cellular, and an offline device has nothing to fetch.
    func testBackgroundFetchAllowed_acrossConnectivityAndPreference() {
        for connected in [true, false] {
            for onWiFi in [true, false] {
                for wifiOnly in [true, false] {
                    let expected = connected && !(wifiOnly && !onWiFi)
                    XCTAssertEqual(
                        LocalBookContentService.backgroundFetchAllowed(
                            isConnectedToNetwork: connected,
                            isOnWiFi: onWiFi,
                            downloadOnlyOnWiFi: wifiOnly),
                        expected,
                        "connected=\(connected) onWiFi=\(onWiFi) wifiOnly=\(wifiOnly)")
                }
            }
        }
    }

    /// The specific cell the regression is about, named so a failure reads as the
    /// patron-facing rule rather than a truth-table cell.
    func testBackgroundFetchAllowed_onCellularWithWiFiOnlySet_refuses() {
        XCTAssertFalse(
            LocalBookContentService.backgroundFetchAllowed(
                isConnectedToNetwork: true, isOnWiFi: false, downloadOnlyOnWiFi: true),
            "cellular + download-only-on-WiFi must refuse the background archive fetch — 3.2.x refused it at DownloadStartReducer (.failWifi)")
    }

    // MARK: - Claim lifetime: idle expiry, heartbeat, token-matched release
    //
    // The first version of this guard held a claim for the process lifetime, so
    // a dropped completion wedged the book forever. The second sized the window
    // to the open gate's 180s ceiling as a TOTAL duration — which every title
    // this change was measured against exceeds, so a healthy transfer aged out
    // of its own slot and the next Listen started a duplicate: the exact defect
    // the guard exists to prevent. It is now an IDLE window with a heartbeat.

    func testClaim_silentPastTheIdleWindow_isReclaimed() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let clock = FakeClock()
        let service = makeService(fulfiller: fulfiller, idleTimeout: 180, clock: clock)

        service.redownloadLCPContentFile(for: book)
        XCTAssertEqual(fulfiller.callCount, 1)

        // No progress, no completion — the transfer is silent. Advance past the
        // idle window rather than sleeping through it.
        clock.advance(seconds: 200)
        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 2,
                       "a transfer that has gone silent past the idle window must be reclaimable, or a dropped callback wedges the book permanently")
    }

    func testClaim_heartbeatedByProgress_isNOTReclaimed() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let clock = FakeClock()
        let service = makeService(fulfiller: fulfiller, idleTimeout: 180, clock: clock)

        service.redownloadLCPContentFile(for: book)
        XCTAssertEqual(fulfiller.callCount, 1)

        // A long but healthy transfer: total elapsed far exceeds the window,
        // but it keeps reporting progress throughout.
        // Total elapsed far exceeds the window, but it keeps reporting.
        for _ in 0..<6 {
            clock.advance(seconds: 60)
            fulfiller.emitProgress(0.1)
        }

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 1,
                       "a live transfer must never age out of its own slot — that is what turned a 1.9 GB download into two")
    }

    func testRelease_fromAReclaimedTransfer_doesNotFreeTheSuccessorsSlot() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let first = SpyLCPContentFulfiller()
        let clock = FakeClock()
        let service = makeService(fulfiller: first, idleTimeout: 180, clock: clock)

        service.redownloadLCPContentFile(for: book)
        clock.advance(seconds: 200)
        service.redownloadLCPContentFile(for: book)   // reclaimed by a second transfer
        XCTAssertEqual(first.callCount, 2)

        // The ABANDONED first transfer finally reports back.
        first.finishWithError(NSError(domain: "test", code: 1), callIndex: 0)

        XCTAssertTrue(service.isContentDownloadInFlight(for: book.identifier),
                      "a late completion from a reclaimed transfer must not release the slot its successor holds, or a third duplicate can start")
    }

    func testRedownload_whileFirstTransferInFlight_doesNotStartADuplicate() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        // Self-heal fires at launch...
        service.redownloadLCPContentFile(for: book)
        // ...then the patron taps Listen mid-transfer, which hits the same seam.
        service.redownloadLCPContentFile(for: book)
        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 1,
                       "a transfer already in flight must not be duplicated — this is the 2x-bandwidth defect")
        XCTAssertTrue(service.isContentDownloadInFlight(for: book.identifier))
    }

    func testRedownload_afterTransferCompletes_allowsAFreshDownload() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)
        // Finish with a fulfillment error so no content lands and the
        // `fileExists` guard stays open — isolating the in-flight release.
        fulfiller.finishWithError(NSError(domain: "test", code: 1))

        XCTAssertFalse(service.isContentDownloadInFlight(for: book.identifier),
                       "the slot must be released on the error path or the book can never retry")

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 2,
                       "once the previous transfer has ended a fresh download must be allowed")
    }

    /// A self-heal that SUCCEEDS must promote the record. Reconciliation moved the
    /// book to `.downloadNeeded` on finding a license with no content, and `load()`
    /// is the ONLY reconciler — it runs at launch, from CarPlay bootstrap and on
    /// no-auth holds changes, but NOT on foreground. Without promotion a fully
    /// downloaded audiobook keeps offering "Download" until the next cold launch,
    /// and every 3.2.0-3.2.2 audiobook marked successful at license time lands in
    /// that state on first 3.2.3 launch.
    func testRedownload_onSuccess_promotesTheRecordToDownloadSuccessful() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        registry.setState(.downloadNeeded, for: book.identifier)
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)
        let landed = try writeFile(at: tempDir.appendingPathComponent("landed-\(UUID().uuidString).lcpa"))
        fulfiller.finishWithSuccess(localURL: landed)

        XCTAssertEqual(
            registry.state(for: book.identifier), .downloadSuccessful,
            "content landed but the shelf still offers Download — the patron re-downloads a book they already have"
        )
    }

    /// Must not overwrite a terminal state a concurrent path already set.
    func testRedownload_onSuccess_doesNotOverwriteATerminalState() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        registry.setState(.used, for: book.identifier)
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)
        let landed = try writeFile(at: tempDir.appendingPathComponent("landed-\(UUID().uuidString).lcpa"))
        fulfiller.finishWithSuccess(localURL: landed)

        XCTAssertEqual(registry.state(for: book.identifier), .used,
                       "a book the patron is already listening to must not be reset by a background re-fetch")
    }

    func testRedownload_whenFileMoveFails_stillReleasesTheSlot() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)
        // Completion reports success but points at a file that does not exist,
        // so `moveItem` throws — the third exit path out of the callback.
        fulfiller.finishWithSuccess(localURL: tempDir.appendingPathComponent("does-not-exist.lcpa"))

        XCTAssertFalse(service.isContentDownloadInFlight(for: book.identifier),
                       "a failed move must not leak the in-flight slot")
    }

    func testRedownload_whenContentAlreadyOnDisk_doesNotTransferAtAll() throws {
        let book = makeLCPAudiobook()
        seedBook(book)
        let contentURL = bookFileManager.fakeURLFor(book)
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        try writeFile(at: licenseURL, bytes: 2569)
        try writeFile(at: contentURL, bytes: 4096)

        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 0,
                       "content already on disk must short-circuit before any transfer starts")
    }

    func testRedownload_withoutLicenseOnDisk_doesNotTransfer() throws {
        let book = makeLCPAudiobook()
        seedBook(book)
        // No .lcpl written — nothing to fulfill from.
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 0,
                       "with no license on disk there is nothing to re-fulfill")
    }

    func testRedownload_nonLCPAudiobook_doesNotTransfer() throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        seedBook(book)
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 0,
                       "this path is LCP-audiobook only")
    }

    // MARK: - redownloadLCPContentFile: progress reporting
    //
    // Before this, progress was discarded (`progress: { _ in }`), so the
    // half-sheet had nothing to draw for a multi-gigabyte transfer and patrons
    // read the silence as a failure.

    /// The wiring itself. `MyBooksDownloadCenter` assigns the reporter to the
    /// content service after `init` (the service is built earlier in that
    /// initializer than the reporter is). Both halves of the progress cue are
    /// otherwise tested with a hand-injected reporter, so deleting that one
    /// assignment line would silently kill the whole feature with every unit
    /// test still green.
    func testDownloadCenter_wiresItsReporterIntoTheContentService() {
        let center = appContainer.downloadCenter

        XCTAssertNotNil(center.localContentService.contentDownloadReporter,
                        "MyBooksDownloadCenter must wire its progress reporter into the content service, or the LCP content download reports to nothing")
        XCTAssertTrue(center.localContentService.contentDownloadReporter === center.progressReporter,
                      "it must be the SAME reporter the rest of the download center publishes through")
    }

    /// The `downloadCenterHasTransfer` BRANCH. This is not belt-and-braces:
    /// `AudiobookSessionManager` calls `redownloadLCPContentFile` DIRECTLY, never
    /// through reconciliation, so on the Listen-tap-during-fulfillment route this
    /// gate is the only thing standing between the patron and a second copy of the
    /// archive — the measured 2 x 778 MB defect.
    func testRedownload_whenTheDownloadCenterIsAlreadyTransferring_doesNotStartASecond() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)
        service.downloadCenterHasTransfer = { _ in true }

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 0,
                       "the fulfillment handler is already transferring this archive; a second fetch doubles the patron's data")
    }

    /// Scoped per book — another title's transfer must not block this recovery.
    func testRedownload_whenAnotherBookIsTransferring_stillStarts() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let service = makeService(fulfiller: fulfiller)
        service.downloadCenterHasTransfer = { $0 != book.identifier }

        service.redownloadLCPContentFile(for: book)

        XCTAssertEqual(fulfiller.callCount, 1,
                       "an unrelated transfer must not strand this book without its content")
    }

    // MARK: - The post-init wiring
    //
    // Each of these is a single assignment in `MyBooksDownloadCenter.init`, and
    // every behavioural test above injects the seam by hand. Without these, any
    // one of those lines could be deleted with the entire suite still green — the
    // inert-guard shape this branch has already paid for repeatedly.

    /// All three post-init assignments, asserted in ONE test.
    ///
    /// Deliberately not three tests: each would stand up its own
    /// `MyBooksDownloadCenter` graph in `setUp`, and measured against the previous
    /// tip that extra construction cost was enough to tip unrelated deadline-poll
    /// suites into failure under parallel clones (three clean full runs before,
    /// two red after). Coverage is unchanged — deleting any one of the three
    /// assignments still fails this test.
    ///
    /// The assertions are behavioural, not non-nil: a probe is registered in the
    /// real reporter and each consumer must SEE it, so a closure wired to the
    /// wrong registry fails too.
    func testDownloadCenter_wiresTheLCPTransferRegistryIntoEveryConsumer() {
        let center = appContainer.downloadCenter
        let probe = "wiring-probe-\(UUID().uuidString)"

        XCTAssertNotNil(center.localContentService.downloadCenterHasTransfer,
                        "the content service must be able to ask about live transfers — on the Listen-tap route this is the only duplicate-download defence")
        XCTAssertNotNil(center.startCoordinator.hasActiveLCPContentTransfer,
                        "a patron tap must be gated on live transfers, or it starts a second archive fetch")
        XCTAssertTrue(center.cancellationHandler.progressReporter === center.progressReporter,
                      "cancel must be able to release the registration — Readium never reports a cancelled transfer")

        center.progressReporter.sendLCPContentDownloadActive(bookIdentifier: probe, active: true)
        defer { center.progressReporter.clearLCPContentTransfer(for: probe) }

        XCTAssertEqual(center.localContentService.downloadCenterHasTransfer?(probe), true,
                       "the content service's closure must consult the SAME registry the fulfillment path registers into")
        XCTAssertEqual(center.startCoordinator.hasActiveLCPContentTransfer?(probe), true,
                       "the manual-start gate must consult the SAME registry")
    }

    func testRedownload_reportsActiveThenProgressThenIdle() throws {
        let book = try seedLicenseOnlyLCPAudiobook()
        let fulfiller = SpyLCPContentFulfiller()
        let reporter = SpyProgressReporter()
        let service = makeService(fulfiller: fulfiller, reporter: reporter)

        service.redownloadLCPContentFile(for: book)
        XCTAssertEqual(reporter.activity, [true],
                       "the UI cue must open when the transfer starts")

        fulfiller.emitProgress(0.25)
        fulfiller.emitProgress(0.75)
        XCTAssertEqual(reporter.progress.map(\.1), [0.25, 0.75],
                       "real transfer progress must reach the reporter, not be discarded")
        XCTAssertEqual(Set(reporter.progress.map(\.0)), [book.identifier])

        fulfiller.finishWithError(NSError(domain: "test", code: 1))
        XCTAssertEqual(reporter.activity, [true, false],
                       "the cue must close on failure too, or the bar would hang forever")
    }

#endif
}

/// Deterministic monotonic clock for the claim-lifetime tests.
private final class FakeClock {
    private(set) var now: UInt64 = 1_000_000_000
    func advance(seconds: TimeInterval) {
        now &+= UInt64(seconds * 1_000_000_000)
    }
}

// MARK: - Test fakes

#if LCP

/// Stands in for the `LCPLibraryService.fulfill` call so the in-flight guard and
/// the progress plumbing can be driven deterministically. The test decides when
/// (and whether) the transfer completes, which is the only way to observe that
/// the slot is held for the duration and released afterwards.
private final class SpyLCPContentFulfiller {
    private(set) var callCount = 0
    private(set) var lastLicenseURL: URL?
    /// Retained PER CALL, not just the latest. A reclaimed transfer's callback
    /// must be firable after its successor has started, which is the only way to
    /// exercise token-matched release.
    private var progressHandlers: [(Double) -> Void] = []
    private var completionHandlers: [(URL?, Error?) -> Void] = []

    private var progressHandler: ((Double) -> Void)? { progressHandlers.last }
    private var completionHandler: ((URL?, Error?) -> Void)? { completionHandlers.last }

    func fulfill(
        licenseURL: URL,
        progress: @escaping (Double) -> Void,
        completion: @escaping (URL?, Error?) -> Void
    ) {
        callCount += 1
        lastLicenseURL = licenseURL
        progressHandlers.append(progress)
        completionHandlers.append(completion)
    }

    /// Fires the completion of the Nth transfer (0-based), so an abandoned
    /// transfer can report back after a successor has claimed the slot.
    func finishWithError(_ error: Error, callIndex: Int) {
        completionHandlers[callIndex](nil, error)
    }

    func emitProgress(_ fraction: Double) {
        progressHandler?(fraction)
    }

    func finishWithError(_ error: Error) {
        completionHandler?(nil, error)
    }

    func finishWithSuccess(localURL: URL) {
        completionHandler?(localURL, nil)
    }
}

/// Records what the service reports so the tests assert on the published
/// signals rather than on internal state.
private final class SpyProgressReporter: DownloadProgressPublishing {
    let downloadProgressPublisher = PassthroughSubject<(String, Double), Never>()
    let downloadErrorPublisher = PassthroughSubject<DownloadErrorInfo, Never>()
    let lcpContentDownloadPublisher = PassthroughSubject<(String, Bool), Never>()

    private(set) var progress: [(String, Double)] = []
    private(set) var activity: [Bool] = []

    func sendProgress(bookIdentifier: String, progress fraction: Double) {
        progress.append((bookIdentifier, fraction))
    }

    func sendLCPContentDownloadActive(bookIdentifier: String, active: Bool) {
        activity.append(active)
        if active {
            active_transfers.insert(bookIdentifier)
        } else {
            active_transfers.remove(bookIdentifier)
        }
    }

    /// Mirrors the real reporter so a caller that consults the registry sees the
    /// same answer the production guard would.
    private var active_transfers = Set<String>()

    func isLCPContentTransferActive(for bookIdentifier: String) -> Bool {
        active_transfers.contains(bookIdentifier)
    }

    func clearLCPContentTransfer(for bookIdentifier: String) {
        active_transfers.remove(bookIdentifier)
    }

    func publishAndAnnounceError(_ errorInfo: DownloadErrorInfo) {}
    func broadcastUpdate() {}
}

#endif

/// BookFileManager subclass that resolves to predictable temp-dir URLs
/// without requiring real per-account directories. Captures the most
/// recent account passed for assertions.
private final class SpyBookFileManager: BookFileManager {
    private let tempDir: URL
    var lastResolvedAccount: String? { resolvedAccounts.last ?? nil }
    /// Retained PER CALL, not just the latest — the same reason
    /// `SpyLCPContentFulfiller` keeps its handlers per call. "Most recent" cannot
    /// distinguish "the destination resolved correctly" from "something resolved
    /// after it and happened to agree", and PP-5146 was found precisely because a
    /// SECOND resolution overwrote the first with the wrong account.
    private(set) var resolvedAccounts: [String?] = []
    /// Identifier whose lookup should return nil — exercises the
    /// "Could not resolve fileUrl" branch.
    var failResolutionForIdentifier: String?

    init(tempDir: URL, bookRegistry: TPPBookRegistryProvider, accountsManager: AccountsManager) {
        self.tempDir = tempDir
        super.init(
            bookRegistry: bookRegistry,
            fileManager: .default
        )
    }

    func fakeURLFor(_ book: TPPBook) -> URL {
        let ext: String
        switch book.defaultBookContentType {
        case .epub: ext = "epub"
        case .pdf: ext = "pdf"
        case .audiobook: ext = "json"
        default: ext = "bin"
        }
        return tempDir.appendingPathComponent(book.identifier).appendingPathExtension(ext)
    }

    override func fileUrl(for book: TPPBook, account: String?) -> URL? {
        resolvedAccounts.append(account)
        if book.identifier == failResolutionForIdentifier { return nil }
        return fakeURLFor(book)
    }
}
