//
//  ProblemReportEmailTests.swift
//  PalaceTests
//
//  Tests for ProblemReportEmail body generation.
//

import XCTest
@testable import Palace

final class ProblemReportEmailTests: XCTestCase {

    private var emailService: ProblemReportEmail!

    override func setUp() {
        super.setUp()
        emailService = ProblemReportEmail.sharedInstance
    }

    override func tearDown() {
        emailService = nil
        super.tearDown()
    }

    // MARK: - generateBody Tests

    func testGenerateBody_withBook_containsBookInfo() {
        let book = TPPBookMocker.mockBook(title: "Test Book Title", authors: "Test Author")

        let body = emailService.generateBody(book: book)

        XCTAssertTrue(body.contains("Title: Test Book Title"))
        XCTAssertTrue(body.contains("ID: "))
    }

    func testGenerateBody_withoutBook_doesNotContainBookInfo() {
        let body = emailService.generateBody(book: nil)

        XCTAssertFalse(body.contains("Title:"))
        XCTAssertFalse(body.contains("ID:"))
    }

    func testGenerateBody_containsDeviceIdiom() {
        let body = emailService.generateBody(book: nil)

        XCTAssertTrue(body.contains("Idiom:"))
        // The idiom should be one of: phone, pad, tv, mac, carPlay, unspecified
        let validIdioms = ["phone", "pad", "tv", "mac", "carPlay", "unspecified"]
        let containsValidIdiom = validIdioms.contains { body.contains("Idiom: \($0)") }
        XCTAssertTrue(containsValidIdiom, "Body should contain a valid idiom")
    }

    /// Body has a fixed structure: two leading newlines (so the user can
    /// type their message above), then a `---` separator, then the device-info
    /// labels in a known order. Lock the whole structure in one test so a
    /// mutant that drops a label, reorders fields, or swaps the separator
    /// fails on a single assertion.
    func testGenerateBody_includesEnvironmentFieldsInExpectedStructure() {
        let body = emailService.generateBody(book: nil)

        // User-message space + separator are the visual scaffolding of the email.
        XCTAssertTrue(body.hasPrefix("\n\n"),
                      "Body MUST start with two newlines to give the user typing room above the device info")
        XCTAssertTrue(body.contains("---"),
                      "Separator delimits the device-info section the user shouldn't edit")

        // All required device-info labels are present.
        for label in ["Idiom:", "Platform: iOS", "OS:", "Height:", "Palace Version:", "Library:"] {
            XCTAssertTrue(body.contains(label),
                          "Body must surface '\(label)' for support triage")
        }

        // OS version + screen height embed the live system values, not just a label.
        XCTAssertTrue(body.contains("OS: \(UIDevice.current.systemVersion)"),
                      "OS field must reflect the live system version")
        XCTAssertTrue(body.contains("Height: \(UIScreen.main.nativeBounds.height)"),
                      "Height field must reflect the live screen height")

        // Order matters: Platform comes before OS, OS comes before Height. A
        // mutant that swaps any pair would fail one of these.
        guard
            let platformIdx = body.range(of: "Platform: iOS")?.lowerBound,
            let osIdx = body.range(of: "OS:")?.lowerBound,
            let heightIdx = body.range(of: "Height:")?.lowerBound,
            let palaceIdx = body.range(of: "Palace Version:")?.lowerBound
        else {
            XCTFail("Body must contain all expected fields"); return
        }
        XCTAssertLessThan(platformIdx, osIdx)
        XCTAssertLessThan(osIdx, heightIdx)
        XCTAssertLessThan(heightIdx, palaceIdx)
    }

    // MARK: - Patron ID Tests (PP-3651)

    /// Regression test for PP-3651: patron ID must be appended when provided
    /// and entirely omitted (no label leak) when nil. Both branches in one
    /// test so a mutant that always-prints or always-omits fails here.
    func testPP3651_generateBody_includesPatronIDOnlyWhenProvided() {
        let withPatron = emailService.generateBody(book: nil, patronIdentifier: "23333098765432")
        let withoutPatron = emailService.generateBody(book: nil, patronIdentifier: nil)

        XCTAssertTrue(withPatron.contains("Patron ID: 23333098765432"),
                      "Patron ID must be appended when provided")
        XCTAssertFalse(withoutPatron.contains("Patron ID:"),
                       "Patron ID label must NOT leak into the body when nil — privacy + correctness")
        XCTAssertFalse(withoutPatron.contains("23333098765432"),
                       "Even raw patron-ID digits must not appear when none was passed")
    }

    /// Regression test for PP-3651: Patron ID should appear alongside book info
    func testPP3651_generateBody_withBookAndPatronID_containsBothBookAndPatronInfo() {
        let book = TPPBookMocker.mockBook(title: "Test Book", authors: "Test Author")
        let patronID = "12345678901234"

        let body = emailService.generateBody(book: book, patronIdentifier: patronID)

        XCTAssertTrue(body.contains("Title: Test Book"),
                      "Email body should contain book title")
        XCTAssertTrue(body.contains("Patron ID: \(patronID)"),
                      "Email body should contain patron ID alongside book info")
    }

    /// Regression test for PP-3651: Patron ID should appear in the device info section (after the separator)
    func testPP3651_generateBody_patronID_appearsAfterSeparator() {
        let patronID = "99887766554433"

        let body = emailService.generateBody(book: nil, patronIdentifier: patronID)

        // The patron ID should appear after the "---" separator along with other device info
        guard let separatorRange = body.range(of: "---") else {
            XCTFail("Body should contain separator")
            return
        }
        let afterSeparator = String(body[separatorRange.upperBound...])
        XCTAssertTrue(afterSeparator.contains("Patron ID: \(patronID)"),
                      "Patron ID should appear in the device info section after the separator")
    }

    // MARK: - Library-scoped Patron ID Tests (PP-3651 follow-up)

    /// Regression test: cross-library patron ID leakage is the bug PP-3651
    /// flagged — the caller must pass the patron ID for the *viewed* library,
    /// and when there is no signed-in patron there, the body must not surface
    /// any other library's identifier. This test covers the contract from the
    /// generateBody side; library-resolution is enforced at the beginComposing
    /// call site (which is exercised end-to-end by the production code path).
    func testPP3651_generateBody_doesNotLeakOtherLibrarysPatronIDWhenNilPassed() {
        // Body produced for "viewed library has no patron" must be free of any
        // patron-shaped digit run. Use a sentinel that would obviously look
        // like a leaked identifier if it appeared.
        let sentinel = "11111122223333"
        let body = emailService.generateBody(book: nil, patronIdentifier: nil)

        XCTAssertFalse(body.contains("Patron ID:"),
                       "Patron ID label must not appear when no patron is passed")
        XCTAssertFalse(body.contains(sentinel),
                       "Sanity check that the body does not contain unrelated identifier-shaped text")
    }

    // MARK: - PP-5078: the Library line must never arrive blank

    /// The reported defect. `generateBody` rendered
    /// `Library: \(accountsManager.currentAccount?.name ?? "")`, so whenever
    /// `currentAccount` was nil the line went out as `Library:` with nothing
    /// after it.
    ///
    /// Real ticket 18864 (1 Sep 2026, app 3.2.3) reached support as:
    ///
    ///     Palace Version: 3.2.3
    ///     Library:
    ///     Patron ID: 21467001510417
    ///
    /// The patron ID resolved and the library name did not, because they come
    /// from different sources — the ID is looked up per-library, the name is
    /// read from `currentAccount`, which is nil until the library registry has
    /// loaded that account. The agent triaging it recorded the summary as
    /// "Sign in prompt - no library?", so the blank actively implied the patron
    /// had no library configured; the patron had written that they were a
    /// member of Park Ridge Public Library.
    func testPP5078_libraryFieldValue_withNoNameAndNoUUID_isNotBlank() {
        let value = ProblemReportEmail.libraryFieldValue(name: nil, uuid: nil)
        XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "Must render a placeholder, never an empty string. A blank cannot be "
                       + "distinguished by support from a line lost in email transit.")
    }

    /// The case that actually produced ticket 18864: the app knows WHICH
    /// library, it just cannot name it yet. Emitting the identifier turns a
    /// dead end into something support can look up.
    func testPP5078_libraryFieldValue_withUUIDButNoName_carriesTheIdentifier() {
        let uuid = "urn:uuid:99d6a227-910c-484b-aaed-e323e247e959"
        let value = ProblemReportEmail.libraryFieldValue(name: nil, uuid: uuid)
        XCTAssertTrue(value.contains(uuid),
                      "When the registry cannot name the library, the report must still say "
                      + "which one it was — support can resolve a UUID, but not a blank.")
    }

    /// Whitespace is a blank line wearing a hat: identical in the email,
    /// equally useless to the agent reading it.
    func testPP5078_libraryFieldValue_withWhitespaceName_fallsBack() {
        for candidate in ["", " ", "   ", "\n", " \t "] {
            let value = ProblemReportEmail.libraryFieldValue(name: candidate, uuid: "urn:uuid:abc")
            XCTAssertTrue(value.contains("urn:uuid:abc"),
                          "Whitespace-only name \(candidate.debugDescription) must fall back, not pass through.")
        }
    }

    /// The fix must not damage the common case — most reports do carry a name.
    func testPP5078_libraryFieldValue_withRealName_isPassedThroughUnchanged() {
        XCTAssertEqual(
            ProblemReportEmail.libraryFieldValue(name: "Park Ridge Public Library",
                                                 uuid: "urn:uuid:whatever"),
            "Park Ridge Public Library",
            "A real library name must reach support verbatim, with no decoration.")
    }

    /// PRODUCER test, not a helper test.
    ///
    /// The four cases above pin `libraryFieldValue` itself. They do not pin
    /// that `generateBody` actually CALLS it — reverting the call site to
    /// `currentAccount?.name ?? ""` leaves every one of them green while
    /// shipping the exact defect of ticket 18864. Caught in SoD review; this is
    /// the test that closes it.
    ///
    /// Asserts on the emitted body rather than on a return value, because the
    /// blank line IS the artifact support receives.
    func testPP5078_generateBody_neverEmitsABareLibraryLine() {
        let body = emailService.generateBody(book: nil, patronIdentifier: "21467001510417")

        XCTAssertTrue(body.contains("Library:"),
                      "precondition: the body must carry a Library line at all")
        XCTAssertFalse(body.contains("Library:\n"),
                       "A bare `Library:` line is ticket 18864 — the value must never be empty, "
                       + "whatever the accounts manager knows.")
        XCTAssertFalse(body.contains("Library: \n"),
                       "…including when the value is whitespace, which renders identically in email.")
        XCTAssertFalse(body.hasSuffix("Library:"),
                       "…including when the Library line is last in the body.")

        // Whatever the environment resolves to, SOMETHING must follow the label.
        if let range = body.range(of: "Library: ") {
            let rest = body[range.upperBound...].prefix(while: { $0 != "\n" })
            XCTAssertFalse(rest.trimmingCharacters(in: .whitespaces).isEmpty,
                           "The Library label must be followed by a non-empty value; got \(rest.debugDescription)")
        }
    }
}
