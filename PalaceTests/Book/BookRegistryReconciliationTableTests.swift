//
//  BookRegistryReconciliationTableTests.swift
//  PalaceTests
//
//  A table test over the load-time reconciliation decision, plus the two
//  properties that make the table trustworthy.
//
//  Why this file exists
//  --------------------
//  `BookRegistrySync`'s reconciliation is an else-if chain whose arms were
//  accreted one incident at a time. No arm knows the goal condition; each
//  encodes "what we saw once and how we patched it". Changing WHEN a state
//  transition happens changes which arm a record lands in, so a state-machine
//  change has nonlocal effects by construction.
//
//  Three separate defects in this file were found by review rather than by
//  tests, and all three were the same shape: an arm treated "a file exists" as
//  "the book is playable", which is false for an LCP audiobook holding only its
//  `.lcpl` license. Two of them were introduced by the FIX for the previous one,
//  25 lines away in a neighbouring arm.
//
//  Per-arm unit tests would not have caught them. What catches them is asserting
//  over the whole decision at once, plus:
//
//   - CONVERGENCE: reconciliation settles to a fixpoint. The "comes back one
//     load later" recurrence is a settling failure — arm A wrote a state that
//     arm B then promoted on the next launch. Note this is convergence, NOT
//     single-step idempotence: `.SAMLStarted` with content present legitimately
//     resolves in two passes. The first draft of this file asserted the stricter
//     property and failed on that legitimate settle, which is the table earning
//     its keep before it ever guarded a regression.
//   - THE SAFETY PROPERTY, checked at EVERY step of the settle: no outcome
//     leaves a book claiming to be playable when its content is absent, with no
//     recovery scheduled. That is the user-visible defect ("Listen" with no
//     audio) stated directly, so it holds no matter which arm changes. Checking
//     only the endpoint would have missed the recurrence, which passed through a
//     safe-looking intermediate state.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class BookRegistryReconciliationTableTests: XCTestCase {

    // MARK: - Fixtures

    private var tempDir: URL!
    /// Per-test container so file-path resolution and the sync manager agree,
    /// and so this file does not reach for `AppContainer.production()`
    /// (swarm_47883816 work package A).
    private var appContainer: AppContainer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        appContainer = makeTestAppContainer()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReconciliationTable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        appContainer = nil
        try super.tearDownWithError()
    }

    /// The three disk conditions the predicate distinguishes.
    private enum Disk: String, CaseIterable {
        case absent
        case licenseOnly
        case present

        var presence: BookRegistrySync.ContentPresence {
            switch self {
            case .absent: return .absent
            case .licenseOnly: return .licenseOnly
            case .present: return .present
            }
        }
    }

    /// Drives the PRODUCTION decision. An earlier draft of this file modelled
    /// the expected outcome in a private local function and never executed
    /// `BookRegistrySync` at all — an inert gate: reintroducing the exact
    /// recurrence from earlier rounds left every test in this file green.
    /// Review caught that. The table now calls the real thing.
    private func outcome(
        entry: TPPBookState,
        disk: Disk,
        inFlight: Bool = false
    ) -> BookRegistrySync.ReconciliationDecision {
        BookRegistrySync.reconcile(
            entryState: entry,
            presence: disk.presence,
            isDownloadInFlight: inFlight
        )
    }

    // MARK: - The safety property
    //
    // Stated in terms of the patron-visible defect rather than any arm, so it
    // survives a rewrite of the chain.

    /// A book that claims to be playable while its content is absent, with no
    /// recovery scheduled, is the "Listen with no audio" bug.
    private func violatesSafety(_ outcome: BookRegistrySync.ReconciliationDecision, disk: Disk) -> Bool {
        let claimsPlayable = (outcome.state == .downloadSuccessful || outcome.state == .used)
        let contentAbsent = (disk != .present)
        let noRecovery = !outcome.schedulesContentRedownload && !outcome.schedulesOrphanRedownload
        return claimsPlayable && contentAbsent && noRecovery
    }

    private var entryStates: [TPPBookState] {
        [.downloading, .downloadNeeded, .downloadSuccessful, .used, .SAMLStarted]
    }

    func testNoOutcomeClaimsPlayableWhileContentIsAbsent() {
        for entry in entryStates {
            for disk in Disk.allCases {
                let outcome = outcome(entry: entry, disk: disk)
                XCTAssertFalse(
                    violatesSafety(outcome, disk: disk),
                    "entry \(entry) with disk \(disk.rawValue) yields \(outcome.state) and schedules nothing — that is a book offering Listen with no audio"
                )
            }
        }
    }

    /// Reconciliation must SETTLE. Some entries legitimately take two passes —
    /// `.SAMLStarted` with content present resolves to `.downloadNeeded`, which
    /// the next pass heals to `.downloadSuccessful` — so the property is
    /// convergence to a fixpoint, not single-step idempotence. (The first draft
    /// of this test asserted the stricter thing and failed on that legitimate
    /// settle, which is the table doing its job.)
    func testReconciliationConvergesToAFixpoint() {
        for entry in entryStates {
            for disk in Disk.allCases {
                var state = entry
                var settled = false
                for _ in 0..<6 {
                    let next = outcome(entry: state, disk: disk).state
                    if next == state { settled = true; break }
                    state = next
                }
                XCTAssertTrue(
                    settled,
                    "entry \(entry) with disk \(disk.rawValue) never settled — it keeps changing answer every launch"
                )
            }
        }
    }

    /// The property that actually protects the patron, asserted at EVERY step of
    /// the settle rather than only at the end. The recurrence that survived a
    /// review round passed through a safe-looking intermediate state and only
    /// became wrong on the following launch, so checking the endpoint alone
    /// would have missed it.
    func testSafetyHoldsAtEveryStepOfTheSettle() {
        for entry in entryStates {
            for disk in Disk.allCases {
                var state = entry
                for pass in 0..<6 {
                    let outcome = outcome(entry: state, disk: disk)
                    XCTAssertFalse(
                        violatesSafety(outcome, disk: disk),
                        "pass \(pass + 1) from entry \(entry) with disk \(disk.rawValue) produced \(outcome.state) with no recovery scheduled — Listen with no audio"
                    )
                    if outcome.state == state { break }
                    state = outcome.state
                }
            }
        }
    }

    /// The specific class that bit us three times: a book holding only its
    /// license must never settle into a state that claims it is playable, from
    /// any entry state.
    ///
    /// Asserts SETTLEMENT before inspecting the endpoint. An earlier version
    /// read the state after a fixed number of iterations, which made it pass by
    /// parity for the one entry state whose mutated arm happened to land back on
    /// itself — the mutated arm, of all of them. Every visited state is checked,
    /// so an oscillation cannot hide the violation in a trough.
    func testLicenseOnlyNeverSettlesIntoAPlayableState() {
        for entry in entryStates {
            var state = entry
            var visited: [TPPBookState] = [state]
            var settled = false

            for _ in 0..<6 {
                let next = outcome(entry: state, disk: .licenseOnly).state
                if next == state { settled = true; break }
                state = next
                visited.append(state)
            }

            XCTAssertTrue(
                settled,
                "entry \(entry) never settled with only a license — visited \(visited); an oscillating chain has no safe endpoint to check"
            )

            // Skip the entry itself: `.downloadSuccessful` and `.used` ARE
            // playable states, and starting there is the whole point — the chain
            // must demote them. What must never happen is the chain PRODUCING or
            // returning to a playable state while only a license is on disk.
            for produced in visited.dropFirst() {
                XCTAssertFalse(
                    produced == .downloadSuccessful || produced == .used,
                    "entry \(entry) was reconciled INTO \(produced) with only a license — visited \(visited). That is the Listen-with-no-audio defect, and checking only the endpoint is how it survived a review round."
                )
            }
        }
    }

    // MARK: - The predicate itself, against real files
    //
    // The table above pins the DECISION. This pins the input it consumes, so the
    // two cannot drift apart silently.

    private func makeLCPAudiobook() -> TPPBook {
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/vnd.readium.lcp.license.v1.0+json",
            hrefURL: URL(string: "https://library.test/book.lcpl")!,
            indirectAcquisitions: [
                TPPOPDSIndirectAcquisition(type: "application/audiobook+lcp", indirectAcquisitions: [])
            ],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition], authors: [], categoryStrings: [],
            distributor: "Test", identifier: UUID().uuidString,
            imageURL: nil, imageThumbnailURL: nil, published: Date(),
            publisher: "Test", subtitle: nil, summary: nil,
            title: "Reconciliation Fixture", updated: Date(),
            annotationsURL: nil, analyticsURL: nil, alternateURL: nil,
            relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil,
            contributors: [:], bookDuration: nil, imageCache: MockImageCache()
        )
    }

    private func makeSync() -> BookRegistrySync {
        BookRegistrySync(
            store: BookRegistryStore(),
            accountsManager: appContainer.accountsManager,
            downloadCenterProvider: { [appContainer] in appContainer!.downloadCenter },
            opdsFeedServiceProvider: { [appContainer] in appContainer!.opdsFeedService }
        )
    }

    func testContentPresence_licenseWithoutContent_isLicenseOnlyNotPresent() throws {
        let sync = makeSync()
        let book = makeLCPAudiobook()
        let account = "reconciliation-test"

        let contentURL = try XCTUnwrap(
            appContainer.downloadCenter.fileUrl(for: book, account: account)
        )
        let licenseURL = contentURL.deletingPathExtension().appendingPathExtension("lcpl")
        try FileManager.default.createDirectory(at: contentURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x01, count: 512).write(to: licenseURL)
        defer { try? FileManager.default.removeItem(at: licenseURL) }

        XCTAssertEqual(sync.contentPresence(for: book, account: account), .licenseOnly,
                       "a license without its .lcpa must NOT read as present — that conflation is what promoted interrupted downloads to Listen-with-no-audio")
    }

    func testContentPresence_withContent_isPresent() throws {
        let sync = makeSync()
        let book = makeLCPAudiobook()
        let account = "reconciliation-test"

        let contentURL = try XCTUnwrap(
            appContainer.downloadCenter.fileUrl(for: book, account: account)
        )
        try FileManager.default.createDirectory(at: contentURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x02, count: 512).write(to: contentURL)
        defer { try? FileManager.default.removeItem(at: contentURL) }

        XCTAssertEqual(sync.contentPresence(for: book, account: account), .present)
    }

    func testContentPresence_nothingOnDisk_isAbsent() {
        let sync = makeSync()
        let book = makeLCPAudiobook()

        XCTAssertEqual(sync.contentPresence(for: book, account: "reconciliation-test"), .absent)
    }

    // MARK: - In-flight guard
    //
    // A warm `load()` — TPPAppDelegate on foreground, HoldsViewModel on hold
    // changes — can land in the middle of a healthy multi-minute transfer.

    func testDownloading_whileATransferIsInFlight_isLeftAlone() {
        for disk in Disk.allCases {
            let decision = outcome(entry: .downloading, disk: disk, inFlight: true)
            XCTAssertEqual(decision.state, .downloading,
                           "a live transfer must not be reconciled away (disk: \(disk.rawValue))")
            XCTAssertFalse(decision.schedulesContentRedownload,
                           "and must not have a duplicate transfer scheduled alongside it")
            XCTAssertFalse(decision.schedulesOrphanRedownload)
        }
    }

    func testDownloading_withNoTransferInFlight_isReconciled() {
        XCTAssertEqual(outcome(entry: .downloading, disk: .absent, inFlight: false).state, .downloadFailed,
                       "with nothing in flight and nothing on disk the download really did fail")
    }
}
