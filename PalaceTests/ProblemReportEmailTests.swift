//
//  ProblemReportEmailTests.swift
//  PalaceTests
//
//  Tests for ProblemReportEmail body generation.
//

import TriageBotCore
import XCTest
@testable import Palace

@MainActor
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

        let body = emailService.generateBody(book: book, context: context(patron: nil))

        XCTAssertTrue(body.contains("Title: Test Book Title"))
        XCTAssertTrue(body.contains("ID: "))
    }

    func testGenerateBody_withoutBook_doesNotContainBookInfo() {
        let body = emailService.generateBody(book: nil, context: context(patron: nil))

        XCTAssertFalse(body.contains("Title:"))
        XCTAssertFalse(body.contains("ID:"))
    }

    func testGenerateBody_containsDeviceIdiom() {
        let body = emailService.generateBody(book: nil, context: context(patron: nil))

        XCTAssertTrue(body.contains("Idiom:"))
        // The idiom should be one of: phone, pad, tv, mac, carPlay, unspecified
        let validIdioms = ["phone", "pad", "tv", "mac", "carPlay", "unspecified"]
        let containsValidIdiom = validIdioms.contains { body.contains("Idiom: \($0)") }
        XCTAssertTrue(containsValidIdiom, "Body should contain a valid idiom")
    }

    /// Body has a fixed structure: two leading newlines (so the user can
    /// type their message above), then a `---` separator, then the device-info
    /// labels in a known order. Lock the whole structure in one test so a
    /// dropped label, reordered field, or swapped separator fails here.
    func testGenerateBody_includesEnvironmentFieldsInExpectedStructure() {
        let body = emailService.generateBody(book: nil, context: context(patron: nil))

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

        // Order matters: Platform comes before OS, OS comes before Height. Swapping
        // any pair fails one of these.
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

    // MARK: - Patron reference (PP-3651, PP-4818)

    private func context(patron: String?, libraryName: String? = nil, libraryUUID: String? = nil) -> SupportReportContext {
        SupportReportContext(rawPatronIdentifier: patron, libraryName: libraryName, libraryUUID: libraryUUID)
    }

    /// The body carries the hashed patron reference support can match, and
    /// never the raw card number (PP-4818).
    func testGenerateBody_signedIn_carriesTheHashedReferenceNotTheBarcode() {
        let barcode = "23333098765432"

        let body = emailService.generateBody(book: nil, context: context(patron: barcode))

        XCTAssertFalse(body.contains(barcode), "the raw barcode must not reach the email")
        XCTAssertTrue(body.contains("Patron reference: \(ContextRedactor().hashIdentifier(barcode))"))
    }

    /// Signed out: no patron line at all (PP-3651).
    func testGenerateBody_signedOut_hasNoPatronLine() {
        let body = emailService.generateBody(book: nil, context: context(patron: nil))

        XCTAssertFalse(body.contains("Patron"))
    }

    /// The reference sits in the diagnostics block below the separator, next
    /// to the book details.
    func testGenerateBody_withBook_placesTheReferenceAfterTheSeparator() {
        let book = TPPBookMocker.mockBook(title: "Test Book", authors: "Test Author")

        let body = emailService.generateBody(book: book, context: context(patron: "99887766554433"))

        let afterSeparator = body.components(separatedBy: "---").dropFirst().joined()
        XCTAssertTrue(afterSeparator.contains("Patron reference: anon-"))
        XCTAssertTrue(afterSeparator.contains("Title: Test Book"))
    }

    // MARK: - PP-5078: the Library line is never blank

    /// The bare `Library:` line IS the artifact support receives, so this
    /// asserts on the emitted body rather than on the helper's return value —
    /// a return value would be one indirection away from the thing that was wrong.
    ///
    /// This is the half that actually shipped broken: the helper is new code
    /// nobody had a reason to change, while the call site is a one-line
    /// interpolation inside a 60-character string that a merge could clobber.
    /// Reverting the call site to `libraryName ?? ""` must fail this test by name.
    func testPP5078_generateBody_neverEmitsABareLibraryLine() {
        let cases: [(name: String?, uuid: String?, label: String)] = [
            (nil, nil, "no name, no uuid"),
            (nil, "urn:uuid:1234", "no name, uuid known"),
            ("", nil, "empty name"),
            ("   ", nil, "whitespace-only name"),
            ("", "urn:uuid:1234", "empty name, uuid known")
        ]

        for testCase in cases {
            let body = emailService.generateBody(
                book: nil,
                context: context(patron: nil, libraryName: testCase.name, libraryUUID: testCase.uuid)
            )

            // Parse the value actually rendered after `Library:` rather than
            // substring-matching the body. Substring checks miss the primary
            // defect: with a nil name the line reads `Library: ` — one trailing
            // space — which matches neither "Library:\n" nor a bare suffix.
            let libraryValue = Self.libraryLineValue(in: body)

            XCTAssertNotNil(libraryValue,
                            "\(testCase.label): body has no `Library:` line at all")
            XCTAssertFalse(libraryValue?.isEmpty ?? true,
                           "\(testCase.label): emitted a blank Library line — the PP-5078 defect")
        }
    }

    /// Returns the trimmed value rendered after `Library:`, or nil if absent.
    private static func libraryLineValue(in body: String) -> String? {
        body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("Library:") }
            .map { String($0.dropFirst("Library:".count)).trimmingCharacters(in: .whitespaces) }
    }

    /// A known name is passed through verbatim — the common case must not be
    /// disturbed by the fallback.
    func testPP5078_generateBody_usesLibraryNameWhenKnown() {
        let body = emailService.generateBody(
            book: nil,
            context: context(patron: nil, libraryName: "Park Ridge Public Library", libraryUUID: "urn:uuid:should-not-be-used")
        )

        XCTAssertTrue(body.contains("Library: Park Ridge Public Library"),
                      "A resolved name must be used verbatim")
        XCTAssertFalse(body.contains("should-not-be-used"),
                       "The UUID must not appear when the name is known")
    }

    /// The three outcomes stay distinguishable to whoever reads the email.
    /// A blank could equally mean the line was lost in transit; none of these can.
    func testPP5078_libraryFieldValue_distinguishesItsThreeOutcomes() {
        XCTAssertEqual(
            ProblemReportEmail.libraryFieldValue(name: "Boston Public Library", uuid: "urn:uuid:9"),
            "Boston Public Library",
            "A real name wins over the identifier"
        )
        XCTAssertEqual(
            ProblemReportEmail.libraryFieldValue(name: nil, uuid: "urn:uuid:9"),
            "(name unavailable — urn:uuid:9)",
            "Knowing WHICH library but not its name must surface the identifier support can resolve"
        )
        XCTAssertEqual(
            ProblemReportEmail.libraryFieldValue(name: nil, uuid: nil),
            "(none selected)",
            "Genuinely having no library must say so, not go blank"
        )
        XCTAssertEqual(
            ProblemReportEmail.libraryFieldValue(name: "  ", uuid: nil),
            "(none selected)",
            "A whitespace-only name is not a name"
        )
    }
}
