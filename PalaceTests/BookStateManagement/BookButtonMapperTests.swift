//
//  BookButtonMapperTests.swift
//  PalaceTests
//
//  Tests for BookButtonMapper - the single source of truth for
//  mapping TPPBookState to BookButtonState.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class BookButtonMapperTests: XCTestCase {

    // MARK: - Direct State Mappings

    func testMapDownloading() {
        let result = BookButtonMapper.map(
            registryState: .downloading,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadInProgress)
    }

    func testMapDownloadFailed() {
        let result = BookButtonMapper.map(
            registryState: .downloadFailed,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadFailed)
    }

    func testMapDownloadSuccessful() {
        let result = BookButtonMapper.map(
            registryState: .downloadSuccessful,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadSuccessful)
    }

    func testMapDownloadNeeded() {
        let result = BookButtonMapper.map(
            registryState: .downloadNeeded,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadNeeded)
    }

    func testMapUsed() {
        let result = BookButtonMapper.map(
            registryState: .used,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .used)
    }

    func testMapHolding() {
        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .holding)
    }

    func testMapReturning() {
        let result = BookButtonMapper.map(
            registryState: .returning,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .returning)
    }

    /// Phase 7 siblings audit fix: `.SAMLStarted` was previously falling through
    /// the if-cascade to `.unsupported` silently. The exhaustive switch now maps
    /// it to `.downloadInProgress`, matching the parallel `BookButtonState.init?`
    /// mapper (BookButtonState.swift) which treats SAML as part of the download
    /// flow. A user mid-SAML must NOT see "unsupported" — they must see progress.
    func testMapSAMLStarted_returnsDownloadInProgress() {
        let result = BookButtonMapper.map(
            registryState: .SAMLStarted,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadInProgress,
                       "SAMLStarted is part of the download flow — must render as in-progress, not unsupported")
    }

    // MARK: - isProcessingDownload Override

    func testProcessingDownloadOverridesState() {
        // Even if registry says downloadFailed, isProcessingDownload should show downloadInProgress
        let result = BookButtonMapper.map(
            registryState: .downloadFailed,
            availability: nil,
            isProcessingDownload: true
        )
        XCTAssertEqual(result, .downloadInProgress)
    }

    func testProcessingDownloadOverridesDownloadSuccessful() {
        let result = BookButtonMapper.map(
            registryState: .downloadSuccessful,
            availability: nil,
            isProcessingDownload: true
        )
        XCTAssertEqual(result, .downloadInProgress)
    }

    // MARK: - Unregistered Falls Back to Availability

    func testUnregisteredWithNilAvailability() {
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .unsupported)
    }

    // MARK: - stateForAvailability Tests

    func testStateForNilAvailability() {
        let result = BookButtonMapper.stateForAvailability(nil)
        XCTAssertNil(result)
    }

    // MARK: - Consistency Tests

    /// Parameterized `.allCases` exhaustive coverage. Iterates **every**
    /// `TPPBookState` case (driven by the compiler-synthesized `.allCases`,
    /// NOT a hand-maintained list) and pins each case's expected mapping
    /// with neutral inputs (nil availability, isProcessingDownload=false).
    ///
    /// This is the **safety net** for the exhaustive-switch refactor: if a
    /// future contributor adds a new `TPPBookState` case, the production
    /// switch will fail to compile until they map it, AND this test will
    /// fail until they pin the expected button-state result here. The pair
    /// makes the "silent fall-through to .unsupported" trap impossible.
    ///
    /// Reference: Phase 7 siblings audit
    /// (`.forgeos/audits/phase7-synthesis-2026-05-26.md`). The same trap
    /// produced F-011 (audiobook first-open hang) when a `default:` arm
    /// swallowed `.downloadNeeded` silently.
    func testMap_coversAllTPPBookStates_withNeutralInputs() {
        let expected: [TPPBookState: BookButtonState] = [
            .unregistered:       .unsupported,        // nil availability → no signal → unsupported
            .downloadNeeded:     .downloadNeeded,
            .downloading:        .downloadInProgress,
            .downloadFailed:     .downloadFailed,
            .downloadSuccessful: .downloadSuccessful,
            .returning:          .returning,
            .holding:            .holding,            // no .ready availability → still in queue
            .used:               .used,
            .unsupported:        .unsupported,
            .SAMLStarted:        .downloadInProgress  // part of download flow (fixed in this PR)
        ]

        // .allCases is the source of truth — verify our expectations
        // dictionary is exhaustive. A new TPPBookState case will fail this
        // assertion before reaching the per-case mapping checks.
        XCTAssertEqual(Set(expected.keys), Set(TPPBookState.allCases),
                       "expected mappings must cover every TPPBookState.allCases — add the new case here AND to the production switch")

        for state in TPPBookState.allCases {
            let result = BookButtonMapper.map(
                registryState: state,
                availability: nil,
                isProcessingDownload: false
            )
            XCTAssertEqual(result, expected[state],
                           "TPPBookState.\(state) must map to \(expected[state]!) with neutral inputs (got \(result))")
        }
    }

    func testMappingIsDeterministic() {
        // Same inputs should always produce same outputs
        for _ in 0..<10 {
            let result1 = BookButtonMapper.map(
                registryState: .downloadSuccessful,
                availability: nil,
                isProcessingDownload: false
            )
            let result2 = BookButtonMapper.map(
                registryState: .downloadSuccessful,
                availability: nil,
                isProcessingDownload: false
            )
            XCTAssertEqual(result1, result2)
        }
    }

    // MARK: - stateForAvailability(.limited(...)) — kills the only surviving
    // mutants on BookButtonMapper.swift:83 (the copiesAvailable predicate).
    //
    // The line `limited.copiesAvailable == TPPOPDSAcquisitionAvailabilityCopiesUnknown
    // || limited.copiesAvailable > 0` decides whether a `.limited` availability
    // routes to `.canBorrow` (copies present) or `.canHold` (none left). Three
    // input regions exercise each operator distinctly:
    //
    //   - copiesAvailable = TPPOPDSAcquisitionAvailabilityCopiesUnknown
    //     → `==` branch fires → canBorrow. Flipping `==` to `!=` would route
    //     to canHold, failing this assertion.
    //   - copiesAvailable = 3 (positive)
    //     → `>` branch fires → canBorrow. Flipping `>` to `<` or `>=` would
    //     route to canHold (since 3 is neither < 0 nor matches the unknown
    //     sentinel ≡ -1 on iOS), failing this assertion. Flipping `||` to
    //     `&&` would require BOTH the unknown-sentinel AND positive copies,
    //     also failing.
    //   - copiesAvailable = 0
    //     → both clauses false → canHold. Flipping `>` to `>=` would route
    //     zero copies to canBorrow, failing this assertion.
    //
    // The existing `BookButtonMapperHoldReadyTests` cover `.limited` only via
    // `.holding` state, where the mapper short-circuits to `.holding` before
    // reaching `stateForAvailability` — so those tests do not exercise this
    // predicate. These three drive the path directly through `.unregistered`
    // (which falls through to availability) so the predicate runs.

    /// `.limited` with `copiesAvailable == TPPOPDSAcquisitionAvailabilityCopiesUnknown`
    /// (the sentinel value, currently -1) must route to `.canBorrow`. Kills the
    /// `==` → `!=` mutant on line 83 (the sentinel-equality clause).
    func testMap_unregistered_limitedWithUnknownCopies_returnsCanBorrow() {
        let limited = TPPOPDSAcquisitionAvailabilityLimited(
            copiesAvailable: TPPOPDSAcquisitionAvailabilityCopiesUnknown,
            copiesTotal: TPPOPDSAcquisitionAvailabilityCopiesUnknown,
            since: nil,
            until: nil
        )
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: limited,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .canBorrow,
                       "Unknown copies must route to canBorrow — server didn't tell us, so we offer the borrow attempt")
    }

    /// `.limited` with positive `copiesAvailable` must route to `.canBorrow`.
    /// Kills the `>` → `<` mutant, the `>` → `>=` mutant (3 > 0 is true; 3 >=
    /// 0 is also true so this is a partial discriminator — see the zero test
    /// below for the other side), and the `||` → `&&` mutant on line 83.
    func testMap_unregistered_limitedWithPositiveCopies_returnsCanBorrow() {
        let limited = TPPOPDSAcquisitionAvailabilityLimited(
            copiesAvailable: 3,
            copiesTotal: 10,
            since: nil,
            until: nil
        )
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: limited,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .canBorrow,
                       "Copies available > 0 must route to canBorrow — flipping > to < would route this to canHold")
    }

    /// `.limited` with `copiesAvailable == 0` must route to `.canHold`. Kills
    /// the `>` → `>=` mutant on line 83 — that mutant would route zero copies
    /// to canBorrow because 0 >= 0 is true.
    func testMap_unregistered_limitedWithZeroCopies_returnsCanHold() {
        let limited = TPPOPDSAcquisitionAvailabilityLimited(
            copiesAvailable: 0,
            copiesTotal: 10,
            since: nil,
            until: nil
        )
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: limited,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .canHold,
                       "Zero copies must route to canHold — flipping > to >= would silently let users borrow when there are no copies")
    }

    // MARK: - Exhaustive-switch META-regression
    //
    // Source-level invariant pin: `BookButtonMapper.map(...)` MUST remain an
    // exhaustive `switch registryState` with no `default:` clause. This is the
    // F-011-shape regression net referenced in
    // `.forgeos/audits/phase7-synthesis-2026-05-26.md` and the
    // `phase7_borrow_path_regressions_2026_05_14` memory pin.
    //
    // A `default:` clause would silently swallow any future `TPPBookState`
    // case — that is the exact trap that produced F-011 (audiobook first-open
    // hang). The exhaustive switch makes adding a `TPPBookState` case a
    // compile error until the mapping is decided.
    //
    // The companion behavioral test `testMap_coversAllTPPBookStates_withNeutralInputs`
    // (above) iterates `.allCases` and pins the per-case expected output.
    // This META test pins the *shape* of the switch — even if a future
    // contributor disables the per-case test, the source-level invariant
    // here will still flag the regression.

    /// Source-level META-regression. Reads `BookButtonMapper.swift` and asserts
    /// the switch in `map(...)` contains no `default:` clause, so a future PR
    /// cannot silently re-introduce the F-011 fall-through.
    ///
    /// Failure modes (each catches a distinct regression):
    ///   1. File missing → repo restructure caught.
    ///   2. `default:` appears → exhaustive-switch contract broken.
    ///   3. `case .SAMLStarted:` missing → SAML download flow regressed (PR #1006
    ///      shipped this case explicitly because of the silent-fall-through bug).
    func testMap_exhaustiveSwitch_noDefaultClause_andSAMLStartedExplicit() throws {
        let candidatePaths = [
            // Worktree-aware lookup: walk up from this test file to find the
            // repo root and resolve the production file path. The test bundle
            // doesn't embed Swift source files, so we read from disk.
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()    // BookStateManagement
                .deletingLastPathComponent()    // PalaceTests
                .deletingLastPathComponent()    // repo root
                .appendingPathComponent("Palace/Book/UI/BookDetail/BookButtonMapper.swift")
        ]

        let path = try XCTUnwrap(
            candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            "BookButtonMapper.swift not found relative to test file — repo layout changed"
        )

        let source = try String(contentsOf: path, encoding: .utf8)

        // (1) No `default:` clause inside the `map` function body. The whole
        // file's switch is the one inside `map(...)`; `stateForAvailability`
        // uses `availability.match(...)` not a `switch`, so a file-wide grep
        // for `default:` is the right check.
        //
        // Use a regex with word-boundary to avoid matching `// default behaviour`
        // in comments — we want the actual `default:` arm of a switch.
        let defaultClauseRegex = #"^\s*default\s*:"#
        let lines = source.components(separatedBy: "\n")
        let defaultLines = lines.filter { line in
            line.range(of: defaultClauseRegex, options: .regularExpression) != nil
        }
        XCTAssertTrue(defaultLines.isEmpty,
                      "BookButtonMapper.swift must remain an exhaustive switch with NO `default:` clauses. " +
                      "Found: \(defaultLines). Adding `default:` re-opens the F-011 silent fall-through trap " +
                      "(see .forgeos/audits/phase7-synthesis-2026-05-26.md).")

        // (2) `case .SAMLStarted:` must remain explicit. PR #1006 shipped this
        // case because the prior if-cascade silently mapped it to .unsupported.
        // If a future refactor removes the explicit case, the test fails so
        // the developer is forced to confirm the SAML download flow still
        // renders `.downloadInProgress`.
        XCTAssertTrue(
            source.contains("case .SAMLStarted:"),
            "BookButtonMapper.swift must contain an explicit `case .SAMLStarted:` arm. " +
            "Removing it returns to the F-011-shape pre-PR-#1006 trap: a SAML-mid-download " +
            "book would render as .unsupported, leaving the user with no actionable button."
        )
    }
}
