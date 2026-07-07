// AnonymousBorrowFixtureTests.swift
//
// Behavior-level assertions against the captured fixture corpus for the
// anonymous-borrow flow (Palace Bookshelf → catalog → book detail → borrow → My Books).
//
// Each test case asserts what the user actually sees at a known step. These
// tests kill mutation classes that ViewModel-property tests (XCTAssertEqual on
// vm.x) cannot — see .simdrive/fixtures/flows/anonymous-borrow.yaml for the
// per-step mutation_targets list.

import XCTest

@MainActor
final class AnonymousBorrowBaselineFixtureTests: XCTestCase {

  override func tearDown() {
    super.tearDown()
  }

  // MARK: - 02 after-allow-notif

  func test_02_afterAllowNotif_libraryPickerShowsPalaceBookshelfAtTop() throws {
    let f = try MarksFixture.load("anonymous-borrow/02-after-allow-notif", version: "3.0.0")
    f.assertText("Add Library", nearY: 302, tolerancePx: 20)
    f.assertText("Palace Bookshelf", nearY: 622, tolerancePx: 20)
    f.assertContainsText("Popular books free to download and keep")
  }

  func test_02_afterAllowNotif_notifPermissionOverlayDismissed() throws {
    let f = try MarksFixture.load("anonymous-borrow/02-after-allow-notif", version: "3.0.0")
    f.assertNoText("Allow")
    f.assertNoText("Don't Allow")
    f.assertNoText("Would Like to Send")
  }

  // MARK: - 03 catalog (Phase 6.5 + 6.6 architectural sanity-check)

  func test_03_catalog_titleIsPalaceBookshelf() throws {
    let f = try MarksFixture.load("anonymous-borrow/03-catalog", version: "3.0.0")
    f.assertText("Palace Bookshelf", nearY: 238, tolerancePx: 15)
  }

  /// Kills mutants in TPPSignInBusinessLogic.swift line 506 (anonymous detection).
  /// Flipping `!=` → `==` would route this flow through sign-in instead of
  /// rendering the catalog directly.
  func test_03_catalog_anonymousFlowDoesNotShowSignInModal() throws {
    let f = try MarksFixture.load("anonymous-borrow/03-catalog", version: "3.0.0")
    f.assertNoText("Sign In")
    f.assertNoText("Sign-in required")
    f.assertNoText("Library card")
  }

  /// Kills mutants in AccountsManager.swift that would yield empty catalog
  /// (e.g., line 308 return-value flip).
  func test_03_catalog_threeLanesRenderInOrder() throws {
    let f = try MarksFixture.load("anonymous-borrow/03-catalog", version: "3.0.0")
    f.assertOrderedTexts(["DPLA Publications", "Big Ten Open Books Collection", "Fiction"])
  }

  func test_03_catalog_tabBarHasFourTabs() throws {
    let f = try MarksFixture.load("anonymous-borrow/03-catalog", version: "3.0.0")
    f.assertOrderedTexts(["Catalog", "My Books", "Holds", "Settings"])
  }

  // MARK: - 04 book detail

  // NOTE on assertion design: do NOT assert specific book titles, authors, or
  // absolute Y positions for content-driven elements. The Palace Bookshelf
  // catalog is server-driven and rotates; carousels show different books on
  // different cold launches. Asserting "A Night in Acadie at y=2244" will fail
  // on the next re-capture even when the code is correct. Assert STABLE
  // elements (UI controls, lane labels, library names, section headers) and
  // RELATIVE positions (Borrow appears AFTER Description), not absolute ones.

  func test_04_bookDetail_borrowButtonPresent() throws {
    let f = try MarksFixture.load("anonymous-borrow/04-book-detail", version: "3.0.0")
    f.assertContainsText("Borrow")              // present, position depends on title length
    f.assertContainsText("DESCRIPTION")
    f.assertContainsText("< Back")
  }

  /// The Borrow button must appear ABOVE the DESCRIPTION header. Asserting
  /// relative ordering is content-stable; asserting absolute Y is not.
  func test_04_bookDetail_borrowButtonAppearsAboveDescription() throws {
    let f = try MarksFixture.load("anonymous-borrow/04-book-detail", version: "3.0.0")
    guard let borrow = f.firstMark(withText: "Borrow"),
          let description = f.firstMark(containing: "DESCRIPTION") else {
      XCTFail("Expected both 'Borrow' and 'DESCRIPTION' in 04-book-detail")
      return
    }
    XCTAssertLessThan(borrow.centerY, description.centerY,
                      "Borrow CTA at y=\(borrow.centerY) should be above DESCRIPTION at y=\(description.centerY)")
  }

  func test_04_bookDetail_preBorrowDoesNotShowReadOrRemove() throws {
    let f = try MarksFixture.load("anonymous-borrow/04-book-detail", version: "3.0.0")
    f.assertNoText("Read")
    f.assertNoText("Remove")
  }

  // MARK: - 05 after-borrow (the strongest mutation-killing assertion)

  /// Kills mutants in BorrowReducer.swift, MyBooksDownloadCenter.swift, and
  /// BookActionHandler.swift that fail to transition the action button row from
  /// [Borrow] to [Read, Remove]. Any of those mutations leave Borrow visible,
  /// which `assertNoText("Borrow")` flags.
  func test_05_afterBorrow_borrowButtonGoneReadAndRemoveAppear() throws {
    let f = try MarksFixture.load("anonymous-borrow/05-after-borrow", version: "3.0.0")
    f.assertNoText("Borrow")
    f.assertContainsText("Read")
    f.assertContainsText("Remove")
  }

  func test_05_afterBorrow_libraryAttributionShowsPalaceBookshelf() throws {
    let f = try MarksFixture.load("anonymous-borrow/05-after-borrow", version: "3.0.0")
    f.assertContainsText("Palace Bookshelf")
  }

  // MARK: - 06 my-books (Phase 6.6 TPPBookRegistry singleton kill)

  /// Kills mutants in TPPBookRegistry.swift, MyBooksViewModel.swift, and
  /// MyBooksView.swift that would leave My Books empty after a successful borrow.
  /// This is the integration test for the registry-via-DI path that replaced
  /// the deleted `TPPBookRegistry.shared` singleton.
  func test_06_myBooks_borrowedBookAppears() throws {
    let f = try MarksFixture.load("anonymous-borrow/06-my-books", version: "3.0.0")
    f.assertContainsText("Read")
    f.assertContainsText("Remove")
    f.assertNoText("Empty")
    f.assertNoText("Sign In")
  }

  func test_06_myBooks_sortIndicatorShowsTitle() throws {
    let f = try MarksFixture.load("anonymous-borrow/06-my-books", version: "3.0.0")
    f.assertContainsText("Title")
  }
}

/// Same assertions against the candidate (3.0.1) corpus. Failures here are
/// regressions introduced between 3.0.0 and the candidate. Keeping this in a
/// separate XCTestCase makes the regression delta visible at the top of the
/// test report.
final class AnonymousBorrowCandidateFixtureTests: XCTestCase {

  func test_03_catalog_titleIsPalaceBookshelf() throws {
    let f = try MarksFixture.load("anonymous-borrow/03-catalog", version: "3.0.1")
    f.assertText("Palace Bookshelf", nearY: 238, tolerancePx: 15)
  }

  func test_03_catalog_anonymousFlowDoesNotShowSignInModal() throws {
    let f = try MarksFixture.load("anonymous-borrow/03-catalog", version: "3.0.1")
    f.assertNoText("Sign In")
    f.assertNoText("Sign-in required")
  }

  func test_03_catalog_threeLanesRenderInOrder() throws {
    let f = try MarksFixture.load("anonymous-borrow/03-catalog", version: "3.0.1")
    f.assertOrderedTexts(["DPLA Publications", "Big Ten Open Books Collection", "Fiction"])
  }

  func test_03_catalog_tabBarHasFourTabs() throws {
    let f = try MarksFixture.load("anonymous-borrow/03-catalog", version: "3.0.1")
    f.assertOrderedTexts(["Catalog", "My Books", "Holds", "Settings"])
  }

  func test_05_afterBorrow_borrowButtonGoneReadAndRemoveAppear() throws {
    let f = try MarksFixture.load("anonymous-borrow/05-after-borrow", version: "3.0.1")
    f.assertNoText("Borrow")
    f.assertContainsText("Read")
    f.assertContainsText("Remove")
  }

  func test_06_myBooks_borrowedBookAppears() throws {
    let f = try MarksFixture.load("anonymous-borrow/06-my-books", version: "3.0.1")
    f.assertContainsText("Read")
    f.assertContainsText("Remove")
    f.assertNoText("Empty")
  }
}

/// Regression-delta tests that compare baseline vs candidate fixtures directly.
/// Failures here mean a behavior changed between versions in a way the per-version
/// asserts didn't catch. Tolerance is set high (50px) because some shifts are
/// content-driven (different book titles) rather than code-driven.
final class AnonymousBorrowDeltaTests: XCTestCase {

  func test_03_catalog_structureMatchesBetweenVersions() throws {
    let baseline = try MarksFixture.load("anonymous-borrow/03-catalog", version: "3.0.0")
    let candidate = try MarksFixture.load("anonymous-borrow/03-catalog", version: "3.0.1")
    let movements = baseline.movedMarks(vs: candidate, tolerancePx: 50)

    // Lane labels and tab bar must not move significantly across versions.
    let stableTexts: Set<String> = [
      "Palace Bookshelf",
      "DPLA Publications",
      "Big Ten Open Books Collection",
      "Fiction",
      "Catalog", "My Books", "Holds", "Settings"
    ]
    let regressionMovements = movements.filter { stableTexts.contains($0.text) }
    XCTAssertTrue(
      regressionMovements.isEmpty,
      "Catalog structure shifted between 3.0.0 and 3.0.1: " +
      regressionMovements.map { "'\($0.text)' Δ=(\($0.deltaX), \($0.deltaY))" }.joined(separator: ", ")
    )
  }

  func test_06_myBooks_postBorrowStateMatchesBetweenVersions() throws {
    let baseline = try MarksFixture.load("anonymous-borrow/06-my-books", version: "3.0.0")
    let candidate = try MarksFixture.load("anonymous-borrow/06-my-books", version: "3.0.1")

    // Both versions must show Read+Remove and lack Borrow. The book TITLE may differ
    // (carousel non-determinism), but the action-button structure is invariant.
    XCTAssertNotNil(baseline.firstMark(containing: "Read"))
    XCTAssertNotNil(baseline.firstMark(containing: "Remove"))
    XCTAssertNil(baseline.firstMark(containing: "Borrow"))

    XCTAssertNotNil(candidate.firstMark(containing: "Read"))
    XCTAssertNotNil(candidate.firstMark(containing: "Remove"))
    XCTAssertNil(candidate.firstMark(containing: "Borrow"))
  }
}
