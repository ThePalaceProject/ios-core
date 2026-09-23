//
//  ProblemDocumentTests.swift
//  PalaceTests
//
//  Tests for TPPProblemDocument parsing and error handling
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class ProblemDocumentTests: XCTestCase {

    // MARK: - Problem Document Creation Tests

    func testProblemDocument_fromData_parsesCorrectly() throws {
        let json = """
    {
      "type": "http://librarysimplified.org/terms/problem/credentials-suspended",
      "title": "Suspended credentials.",
      "status": 403,
      "detail": "Your library card has been suspended. Contact your branch library."
    }
    """
        let data = json.data(using: .utf8)!

        let problemDoc = try TPPProblemDocument.fromData(data)

        XCTAssertEqual(problemDoc.type, TPPProblemDocument.TypeCredentialsSuspended)
        XCTAssertEqual(problemDoc.title, "Suspended credentials.")
        XCTAssertEqual(problemDoc.status, 403)
        XCTAssertEqual(problemDoc.detail, "Your library card has been suspended. Contact your branch library.")
    }

    func testProblemDocument_fromDictionary_parsesCorrectly() {
        let dict: [String: Any] = [
            "type": "http://librarysimplified.org/terms/problem/loan-limit-reached",
            "title": "Loan limit reached.",
            "status": 403,
            "detail": "You have reached your loan limit for this library."
        ]

        let problemDoc = TPPProblemDocument.fromDictionary(dict)

        XCTAssertEqual(problemDoc.type, TPPProblemDocument.TypePatronLoanLimit)
        XCTAssertEqual(problemDoc.title, "Loan limit reached.")
        XCTAssertEqual(problemDoc.status, 403)
        XCTAssertEqual(problemDoc.detail, "You have reached your loan limit for this library.")
    }

    // MARK: - show_title (server-controlled title suppression)
    //
    // The manager sends `show_title: false` on a problem document whose
    // `detail` is meant to stand on its own — a library's patron-blocking-rule
    // message redirecting the patron elsewhere, where the standard
    // "Blocked by library policy." title adds framing the library does not
    // want. Absence of the member means "show the title", so every problem
    // document that predates the flag keeps today's behavior.

    func testProblemDocument_fromData_showTitleFalse_suppressesTitle() throws {
        let json = """
    {
      "type": "http://librarysimplified.org/terms/problem/credentials-blocked-by-policy",
      "title": "Blocked by library policy.",
      "status": 403,
      "detail": "Please sign in at your local library instead.",
      "show_title": false
    }
    """
        let problemDoc = try TPPProblemDocument.fromData(Data(json.utf8))

        XCTAssertFalse(problemDoc.shouldShowTitle)
        XCTAssertEqual(problemDoc.detail, "Please sign in at your local library instead.",
                       "Suppressing the title must not affect the library's message.")
        XCTAssertEqual(problemDoc.title, "Blocked by library policy.",
                       "The title is still delivered; only its display is suppressed.")
    }

    func testProblemDocument_fromData_absentShowTitle_showsTitle() throws {
        let json = """
    {
      "type": "http://librarysimplified.org/terms/problem/credentials-blocked-by-policy",
      "title": "Blocked by library policy.",
      "status": 403,
      "detail": "Your access is restricted by library policy."
    }
    """
        let problemDoc = try TPPProblemDocument.fromData(Data(json.utf8))

        XCTAssertNil(problemDoc.showTitle,
                     "The member is absent unless the server asks for suppression.")
        XCTAssertTrue(problemDoc.shouldShowTitle,
                      "An absent flag must preserve today's behavior.")
    }

    func testProblemDocument_fromData_showTitleTrue_showsTitle() throws {
        let json = #"{"type":"about:blank","title":"T","detail":"D","show_title":true}"#

        let problemDoc = try TPPProblemDocument.fromData(Data(json.utf8))

        XCTAssertTrue(problemDoc.shouldShowTitle)
    }

    func testProblemDocument_showTitle_survivesDictionaryRoundTrip() {
        let suppressed = TPPProblemDocument.fromDictionary([
            "type": "about:blank",
            "title": "Blocked by library policy.",
            "detail": "Please sign in at your local library instead.",
            "show_title": false
        ])
        XCTAssertFalse(suppressed.shouldShowTitle)

        let restored = TPPProblemDocument.fromDictionary(suppressed.dictionaryValue)
        XCTAssertFalse(restored.shouldShowTitle,
                       "dictionaryValue must carry the flag so relayed documents keep it.")

        let unflagged = TPPProblemDocument.fromDictionary([
            "type": "about:blank", "title": "T", "detail": "D"
        ])
        XCTAssertNil(unflagged.dictionaryValue["show_title"],
                     "A document without the flag must not acquire one.")
    }

    // MARK: - show_title must never be able to kill the document
    //
    // Declaring `showTitle: Bool?` moved `show_title` from the "unknown key,
    // ignored whatever its type" group into the "must be exactly right or the
    // WHOLE decode aborts" group — synthesized `Codable`'s `decodeIfPresent`
    // returns nil only for an ABSENT or `null` value, and throws `typeMismatch`
    // on a present-but-wrong-typed one.
    //
    // That is a sign-in regression, not a cosmetic one: `TPPNetworkResponder`
    // parses with the strict `fromData`, its catch arm returns an NSError with no
    // problem document, and `userFacingSignInError` then falls through to
    // "invalid credentials" — telling a patron blocked by library policy that
    // their password is wrong, and dropping the library's message entirely.
    //
    // These rows are exactly what a well-formed-JSON-only suite cannot see.

    func testProblemDocument_fromData_showTitleAsString_keepsDocumentAndShowsTitle() throws {
        let json = """
    {
      "type": "http://librarysimplified.org/terms/problem/credentials-blocked-by-policy",
      "title": "Blocked by library policy.",
      "status": 403,
      "detail": "Please sign in at your local library instead.",
      "show_title": "false"
    }
    """
        // Must not throw: before the lenient decode this was `typeMismatch(Bool)`
        // and the caller got NO document at all.
        let problemDoc = try TPPProblemDocument.fromData(Data(json.utf8))

        XCTAssertEqual(problemDoc.detail, "Please sign in at your local library instead.",
                       "A flag we cannot read must not cost the patron the library's message.")
        XCTAssertEqual(problemDoc.status, 403,
                       "The rest of the document must survive the unreadable member.")
        XCTAssertNil(problemDoc.showTitle,
                     "An unreadable flag degrades to `absent`, not to `false`.")
        XCTAssertTrue(problemDoc.shouldShowTitle,
                      "Degrading to `absent` must mean today's behavior: show the title. "
                      + "Defaulting the other way would let a server typo silently suppress "
                      + "titles app-wide.")
    }

    func testProblemDocument_fromData_showTitleAsNumber_keepsDocumentAndShowsTitle() throws {
        let json = #"{"type":"about:blank","title":"T","detail":"D","show_title":0}"#

        let problemDoc = try TPPProblemDocument.fromData(Data(json.utf8))

        XCTAssertEqual(problemDoc.detail, "D")
        XCTAssertNil(problemDoc.showTitle)
        XCTAssertTrue(problemDoc.shouldShowTitle)
    }

    func testProblemDocument_fromData_showTitleNull_keepsDocumentAndShowsTitle() throws {
        // `null` is NOT a type mismatch — `decodeIfPresent` returns nil for it
        // without throwing. Pinned because the lenient path must not be
        // "rescued" later with `container.contains(.showTitle)`, which is true
        // for an explicit null and would misreport this legitimate body.
        let json = #"{"type":"about:blank","title":"T","detail":"D","show_title":null}"#

        let problemDoc = try TPPProblemDocument.fromData(Data(json.utf8))

        XCTAssertNil(problemDoc.showTitle)
        XCTAssertTrue(problemDoc.shouldShowTitle)
    }

    func testProblemDocument_fromData_unknownKeyOfAnyType_stillIgnored() throws {
        // The pre-PR behavior for `show_title` itself, kept as the control: an
        // UNDECLARED key is ignored whatever its type. This is what made the
        // regression possible, and it must stay true for the next extension.
        let json = #"{"type":"about:blank","detail":"D","some_future_flag":"false"}"#

        let problemDoc = try TPPProblemDocument.fromData(Data(json.utf8))

        XCTAssertEqual(problemDoc.detail, "D")
    }

    func testProblemDocument_fromData_otherMembersStayStrict() {
        // The leniency is scoped to `show_title` ONLY. A wrong-typed `status` is
        // still fatal — pre-existing behavior this change deliberately does not
        // widen. If someone later makes the whole decode lenient, this fails.
        let json = #"{"type":"about:blank","title":"T","detail":"D","status":"403"}"#

        XCTAssertThrowsError(try TPPProblemDocument.fromData(Data(json.utf8)),
                             "Only `show_title` is lenient; widening that is a separate decision.")
    }

    // MARK: - show_title round trips
    //
    // `init(from:)` keys on the POST-strategy camelCase name, so the synthesized
    // encoder (also camelCase) round-trips through a plain decoder. These two
    // tests pin that pairing from both sides. A hand-written `encode(to:)`
    // emitting `show_title` would pass the first and FAIL the second — which is
    // why this type deliberately has no custom encoder.

    func testProblemDocument_snakeCaseEncoderDecoderRoundTrip_preservesShowTitle() throws {
        let original = try TPPProblemDocument.fromData(
            Data(#"{"title":"T","detail":"D","show_title":false}"#.utf8))
        XCTAssertFalse(original.shouldShowTitle, "Precondition: the flag was read.")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let wire = try encoder.encode(original)

        XCTAssertTrue(String(decoding: wire, as: UTF8.self).contains("show_title"),
                      "The snake_case wire format is what the server speaks.")

        let restored = try TPPProblemDocument.fromData(wire)
        XCTAssertFalse(restored.shouldShowTitle,
                       "A document relayed through the wire format must keep the flag.")
    }

    func testProblemDocument_plainEncoderDecoderRoundTrip_preservesShowTitle() throws {
        let original = try TPPProblemDocument.fromData(
            Data(#"{"title":"T","detail":"D","show_title":false}"#.utf8))

        let wire = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(TPPProblemDocument.self, from: wire)

        XCTAssertEqual(restored.showTitle, false,
                       "Plain encoder + plain decoder must agree. This fails if anyone adds a "
                       + "custom `encode(to:)` emitting snake_case, because `init(from:)` keys "
                       + "on the post-strategy camelCase name.")
        XCTAssertEqual(restored.detail, "D")
    }

    func testProblemDocument_stringValue_combinesTitleAndDetail() throws {
        let json = """
    {
      "type": "http://librarysimplified.org/terms/problem/hold-limit-reached",
      "title": "Hold limit reached",
      "detail": "You cannot place any more holds."
    }
    """
        let data = json.data(using: .utf8)!

        let problemDoc = try TPPProblemDocument.fromData(data)

        XCTAssertEqual(problemDoc.stringValue, "Hold limit reached: You cannot place any more holds.")
    }

    func testProblemDocument_stringValue_handlesMissingTitle() throws {
        let json = """
    {
      "detail": "Something went wrong."
    }
    """
        let data = json.data(using: .utf8)!

        let problemDoc = try TPPProblemDocument.fromData(data)

        XCTAssertEqual(problemDoc.stringValue, "Something went wrong.")
    }

    // MARK: - NSError Problem Document Extraction Tests

    func testNSError_problemDocument_extractsCorrectly() throws {
        let json = """
    {
      "type": "http://librarysimplified.org/terms/problem/credentials-suspended",
      "title": "Account Suspended",
      "detail": "Please contact your library."
    }
    """
        let data = json.data(using: .utf8)!
        let problemDoc = try TPPProblemDocument.fromData(data)

        let error = NSError.makeFromProblemDocument(
            problemDoc,
            domain: "TestDomain",
            code: 403,
            userInfo: nil
        )

        XCTAssertNotNil(error.problemDocument)
        XCTAssertEqual(error.problemDocument?.title, "Account Suspended")
        XCTAssertEqual(error.problemDocument?.detail, "Please contact your library.")
        XCTAssertEqual(error.userFriendlyTitle, "Account Suspended")
        XCTAssertEqual(error.userFriendlyMessage, "Please contact your library.")
    }

    func testNSError_withoutProblemDocument_hasNilProperties() {
        let error = NSError(
            domain: "TestDomain",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Server error"]
        )

        XCTAssertNil(error.problemDocument)
        XCTAssertNil(error.userFriendlyTitle)
        // userFriendlyMessage falls back to localized description
        XCTAssertEqual(error.userFriendlyMessage, "Server error")
    }

    // MARK: - Problem Document Type Constants Tests

    func testProblemDocumentTypes_areCorrect() {
        XCTAssertEqual(
            TPPProblemDocument.TypeCredentialsSuspended,
            "http://librarysimplified.org/terms/problem/credentials-suspended"
        )
        XCTAssertEqual(
            TPPProblemDocument.TypePatronLoanLimit,
            "http://librarysimplified.org/terms/problem/loan-limit-reached"
        )
        XCTAssertEqual(
            TPPProblemDocument.TypePatronHoldLimit,
            "http://librarysimplified.org/terms/problem/hold-limit-reached"
        )
        XCTAssertEqual(
            TPPProblemDocument.TypeNoActiveLoan,
            "http://librarysimplified.org/terms/problem/no-active-loan"
        )
        XCTAssertEqual(
            TPPProblemDocument.TypeLoanAlreadyExists,
            "http://librarysimplified.org/terms/problem/loan-already-exists"
        )
        XCTAssertEqual(
            TPPProblemDocument.TypeInvalidCredentials,
            "http://librarysimplified.org/terms/problem/credentials-invalid"
        )
    }

    // MARK: - Problem Document Response Error Tests

    func testProblemDocument_fromResponseError_extractsFromNSError() throws {
        let json = """
    {
      "title": "Error from server",
      "detail": "Detailed message"
    }
    """
        let data = json.data(using: .utf8)!
        let problemDoc = try TPPProblemDocument.fromData(data)

        let nsError = NSError.makeFromProblemDocument(
            problemDoc,
            domain: "Test",
            code: 400,
            userInfo: nil
        )

        let extracted = TPPProblemDocument.fromResponseError(nsError, responseData: nil)

        XCTAssertNotNil(extracted)
        XCTAssertEqual(extracted?.title, "Error from server")
        XCTAssertEqual(extracted?.detail, "Detailed message")
    }

    func testProblemDocument_fromResponseError_fallsBackToData() throws {
        let json = """
    {
      "title": "Data-based error",
      "detail": "From response data"
    }
    """
        let data = json.data(using: .utf8)!

        // Error without problem document
        let error = NSError(domain: "Test", code: 500, userInfo: nil)

        let extracted = TPPProblemDocument.fromResponseError(error, responseData: data)

        XCTAssertNotNil(extracted)
        XCTAssertEqual(extracted?.title, "Data-based error")
        XCTAssertEqual(extracted?.detail, "From response data")
    }

    func testProblemDocument_fromResponseError_returnsNilWhenNoDocument() {
        let error = NSError(domain: "Test", code: 500, userInfo: nil)
        let invalidData = Data("not json".utf8)

        let extracted = TPPProblemDocument.fromResponseError(error, responseData: invalidData)

        XCTAssertNil(extracted)
    }

    // MARK: - Real-World Scenario Tests

    /// Tests the scenario from Sonoma County loan issue
    /// Server returns 403 with credentials-suspended problem document
    func testBorrowError_credentialsSuspended_extractsDetails() throws {
        // Simulates the actual server response from the ticket
        let serverResponse = """
    {
      "type": "http://librarysimplified.org/terms/problem/credentials-suspended",
      "title": "Suspended credentials.",
      "status": 403,
      "detail": "Your library card has been suspended. Contact your branch library."
    }
    """
        let data = serverResponse.data(using: .utf8)!
        let problemDoc = try TPPProblemDocument.fromData(data)

        // Create an NSError like OPDSFeedService would
        let nsError = NSError.makeFromProblemDocument(
            problemDoc,
            domain: "Api call failure: problem document available",
            code: TPPErrorCode.apiCall.rawValue,
            userInfo: nil
        )

        // Verify we can extract the user-friendly details
        XCTAssertEqual(nsError.userFriendlyTitle, "Suspended credentials.")
        XCTAssertEqual(
            nsError.userFriendlyMessage,
            "Your library card has been suspended. Contact your branch library."
        )

        // Verify the problem document is accessible
        XCTAssertNotNil(nsError.problemDocument)
        XCTAssertEqual(nsError.problemDocument?.type, TPPProblemDocument.TypeCredentialsSuspended)
    }

    /// Tests the scenario: patron reaches loan limit at Hinsdale Library
    func testBorrowError_loanLimitReached_extractsDetails() throws {
        let serverResponse = """
    {
      "type": "http://librarysimplified.org/terms/problem/loan-limit-reached",
      "title": "Loan limit reached",
      "status": 403,
      "detail": "You have reached your checkout limit. Please return a title to borrow more."
    }
    """
        let data = serverResponse.data(using: .utf8)!
        let problemDoc = try TPPProblemDocument.fromData(data)

        let nsError = NSError.makeFromProblemDocument(
            problemDoc,
            domain: "Api call failure: problem document available",
            code: TPPErrorCode.apiCall.rawValue,
            userInfo: nil
        )

        XCTAssertEqual(nsError.userFriendlyTitle, "Loan limit reached")
        XCTAssertEqual(
            nsError.userFriendlyMessage,
            "You have reached your checkout limit. Please return a title to borrow more."
        )
    }
}
