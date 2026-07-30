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

    // MARK: - The expectation table
    //
    // Every (entry, presence) cell pinned explicitly. An earlier version of this
    // file had NO table at all — it asserted only properties, and no licenseOnly
    // cell was pinned anywhere, so flipping `.downloadSuccessful` + `.licenseOnly`
    // back to the shipped defect failed zero tests. Properties alone are not a
    // gate; they need the cells underneath them.

    private struct Cell {
        let entry: TPPBookState
        let disk: Disk
        let expected: TPPBookState
        let content: Bool
        let orphan: Bool
    }

    private var table: [Cell] {
        [
            // A live transfer settles its own state — see the in-flight tests.
            Cell(entry: .downloading, disk: .present,     expected: .downloadSuccessful, content: false, orphan: false),
            Cell(entry: .downloading, disk: .licenseOnly, expected: .downloadNeeded,     content: true,  orphan: false),
            Cell(entry: .downloading, disk: .absent,      expected: .downloadFailed,     content: false, orphan: false),

            Cell(entry: .downloadNeeded, disk: .present,     expected: .downloadSuccessful, content: false, orphan: false),
            Cell(entry: .downloadNeeded, disk: .licenseOnly, expected: .downloadNeeded,     content: true,  orphan: false),
            Cell(entry: .downloadNeeded, disk: .absent,      expected: .downloadNeeded,     content: false, orphan: false),

            Cell(entry: .downloadSuccessful, disk: .present,     expected: .downloadSuccessful, content: false, orphan: false),
            // THE cell the shipped defect got wrong: a license is not playable.
            Cell(entry: .downloadSuccessful, disk: .licenseOnly, expected: .downloadNeeded,     content: true,  orphan: false),
            Cell(entry: .downloadSuccessful, disk: .absent,      expected: .downloadNeeded,     content: false, orphan: true),

            Cell(entry: .used, disk: .present,     expected: .used,           content: false, orphan: false),
            Cell(entry: .used, disk: .licenseOnly, expected: .downloadNeeded, content: true,  orphan: false),
            Cell(entry: .used, disk: .absent,      expected: .downloadNeeded, content: false, orphan: true),

            Cell(entry: .SAMLStarted, disk: .present,     expected: .downloadNeeded, content: false, orphan: false),
            Cell(entry: .SAMLStarted, disk: .licenseOnly, expected: .downloadNeeded, content: false, orphan: false),
            Cell(entry: .SAMLStarted, disk: .absent,      expected: .downloadFailed, content: false, orphan: false),
        ]
    }

    func testEveryCellOfTheReconciliationTable() {
        for cell in table {
            let got = outcome(entry: cell.entry, disk: cell.disk)
            XCTAssertEqual(got.state, cell.expected,
                           "entry \(cell.entry) + disk \(cell.disk.rawValue) should reconcile to \(cell.expected)")
            XCTAssertEqual(got.schedulesContentRedownload, cell.content,
                           "entry \(cell.entry) + disk \(cell.disk.rawValue): content re-download scheduling")
            XCTAssertEqual(got.schedulesOrphanRedownload, cell.orphan,
                           "entry \(cell.entry) + disk \(cell.disk.rawValue): orphan re-download scheduling")
        }
    }

    /// States `reconcile` must pass through untouched. This became load-bearing
    /// when the entry-state gate was removed from `load()`: every record now
    /// goes through `reconcile`, so a mutation of the identity branch would
    /// rewrite every `.holding` record in the registry.
    func testStatesOutsideTheChainAreReturnedUnchanged() {
        let untouched: [TPPBookState] = [.unregistered, .holding, .downloadFailed, .returning, .unsupported]
        for state in untouched {
            for disk in Disk.allCases {
                let got = outcome(entry: state, disk: disk)
                XCTAssertEqual(got.state, state,
                               "\(state) must pass through untouched (disk: \(disk.rawValue)) — load() no longer gates on entry state")
                XCTAssertFalse(got.schedulesContentRedownload)
                XCTAssertFalse(got.schedulesOrphanRedownload)
            }
        }
    }

    /// An in-flight transfer must settle EVERY entry state that could be reached
    /// mid-download, not just `.downloading`. The device trace's 2nd and 3rd
    /// duplicate schedules both came from `.downloadNeeded`, which returns
    /// `content: true` on its own.
    /// F3: the in-flight COLUMN, pinned cell by cell. The not-in-flight half had
    /// all 15 cells; this half had only a scheduling assertion, so the states it
    /// produces were unpinned — including the `.used` + present identity that keeps
    /// a listening patron's Listen button during a background re-download.
    func testEveryCellOfTheInFlightColumn() {
        let cells: [(TPPBookState, Disk, TPPBookState)] = [
            // Content present: the record passes through untouched.
            (.downloading, .present, .downloading),
            (.downloadNeeded, .present, .downloadNeeded),
            (.downloadSuccessful, .present, .downloadSuccessful),
            (.used, .present, .used),
            // A first-borrow fulfillment is genuinely downloading.
            (.downloading, .licenseOnly, .downloading),
            (.downloading, .absent, .downloading),
            // The background re-download must NOT claim `.downloading`: that offers
            // a Cancel that cannot stop the transfer.
            (.downloadNeeded, .licenseOnly, .downloadNeeded),
            (.downloadSuccessful, .licenseOnly, .downloadNeeded),
            (.used, .licenseOnly, .downloadNeeded),
            (.downloadSuccessful, .absent, .downloadNeeded),
            (.used, .absent, .downloadNeeded),
        ]

        for (entry, disk, expected) in cells {
            let got = outcome(entry: entry, disk: disk, inFlight: true)
            XCTAssertEqual(got.state, expected,
                           "in-flight, entry \(entry), disk \(disk.rawValue)")
            XCTAssertFalse(got.schedulesContentRedownload,
                           "in-flight, entry \(entry), disk \(disk.rawValue): must not schedule")
            XCTAssertFalse(got.schedulesOrphanRedownload,
                           "in-flight, entry \(entry), disk \(disk.rawValue): must not schedule")
        }
    }

    /// No in-flight outcome may claim the book is playable without its content —
    /// the same safety property the not-in-flight column carries.
    func testInFlightOutcomesNeverClaimPlayableWithoutContent() {
        for entry in entryStates {
            for disk in Disk.allCases where disk != .present {
                let got = outcome(entry: entry, disk: disk, inFlight: true)
                XCTAssertFalse(
                    got.state == .downloadSuccessful || got.state == .used,
                    "entry \(entry) + \(disk.rawValue) while downloading yields \(got.state) — Listen with no audio"
                )
            }
        }
    }

    func testInFlightTransfer_leavesEveryMidDownloadEntryStateAlone() {
        for entry in [TPPBookState.downloading, .downloadNeeded, .downloadSuccessful, .used] {
            let got = outcome(entry: entry, disk: .licenseOnly, inFlight: true)
            XCTAssertFalse(
                got.schedulesContentRedownload,
                "entry \(entry) scheduled a re-download while the archive was already transferring — that is the doubled download"
            )
        }
    }

    // MARK: - The safety property
    //
    // Stated in terms of the patron-visible defect rather than any arm, so it
    // survives a rewrite of the chain.

    /// A state that claims the book is playable while its content is absent is
    /// the "Listen with no audio" bug — FULL STOP.
    ///
    /// An earlier version of this predicate also required "and no recovery is
    /// scheduled", which made it excuse the exact defect that shipped: that bug
    /// DID schedule a background re-download, and still handed the patron a
    /// Listen button that could not play. Recovery running in the background
    /// does not make the button work now.
    private func claimsPlayableWithoutContent(_ outcome: BookRegistrySync.ReconciliationDecision, disk: Disk) -> Bool {
        let claimsPlayable = (outcome.state == .downloadSuccessful || outcome.state == .used)
        return claimsPlayable && disk != .present
    }

    private var entryStates: [TPPBookState] {
        [.downloading, .downloadNeeded, .downloadSuccessful, .used, .SAMLStarted]
    }

    func testNoOutcomeClaimsPlayableWhileContentIsAbsent() {
        for entry in entryStates {
            for disk in Disk.allCases {
                let got = outcome(entry: entry, disk: disk)
                XCTAssertFalse(
                    claimsPlayableWithoutContent(got, disk: disk),
                    "entry \(entry) with disk \(disk.rawValue) yields \(got.state) — a book offering Listen with no audio"
                )
            }
        }
    }

    /// Reconciliation must SETTLE. Some entries legitimately take two passes —
    /// `.SAMLStarted` with content present resolves to `.downloadNeeded`, which
    /// the next pass heals to `.downloadSuccessful` — so the property is
    /// convergence to a fixpoint, not single-step idempotence.
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
                XCTAssertTrue(settled,
                              "entry \(entry) with disk \(disk.rawValue) never settled — it changes answer every launch")
            }
        }
    }

    /// The class that bit us repeatedly: with only a license on disk, the chain
    /// must never REST in — or pass through — a state claiming to be playable.
    ///
    /// Checks the settled state as well as every intermediate. An earlier version
    /// used `visited.dropFirst()`, which asserts NOTHING when the chain settles
    /// on step zero — precisely the `.downloadSuccessful` / `.used` entries the
    /// defect lived in.
    func testLicenseOnlyNeverRestsOrPassesThroughAPlayableState() {
        for entry in entryStates {
            var state = entry
            var settled = false
            var produced: [TPPBookState] = []

            for _ in 0..<6 {
                let next = outcome(entry: state, disk: .licenseOnly).state
                produced.append(next)
                if next == state { settled = true; break }
                state = next
            }

            XCTAssertTrue(settled, "entry \(entry) never settled with only a license — produced \(produced)")

            for state in produced {
                XCTAssertFalse(
                    state == .downloadSuccessful || state == .used,
                    "entry \(entry) reconciled INTO \(state) with only a license — produced \(produced). That is Listen-with-no-audio."
                )
            }
        }
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
