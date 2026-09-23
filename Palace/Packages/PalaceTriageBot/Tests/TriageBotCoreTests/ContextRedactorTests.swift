import XCTest
@testable import TriageBotCore

final class ContextRedactorTests: XCTestCase {
    private let redactor = ContextRedactor()

    // MARK: - Token / credential stripping

    func testRedactsBearerTokenInLogLine() {
        let input = "GET /loans Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        XCTAssertTrue(output.contains("[REDACTED]"))
    }

    func testRedactsBasicAuthInLogLine() {
        let input = "Authorization: Basic dGVzdHVzZXI6dGVzdHBhc3N3b3JkMTIz"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("dGVzdHVzZXI6dGVzdHBhc3N3b3JkMTIz"))
        XCTAssertTrue(output.contains("[REDACTED]"))
    }

    func testRedactsSAMLSessionCookies() {
        let input = "Cookie: simpleSAMLSessionID=abc123def456; PHPSESSID=xyz789"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("abc123def456"))
        XCTAssertFalse(output.contains("xyz789"))
        XCTAssertTrue(output.contains("simpleSAMLSessionID=[REDACTED]"))
    }

    func testRedactsBarcodeAndPin() {
        let input = "Sending barcode: 1234567890123 pin: 1234"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("1234567890123"))
        XCTAssertFalse(output.contains("pin: 1234"))
    }

    func testRedactsEmailByDefault() {
        let input = "User patron-jane@example.com signed in"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("patron-jane@example.com"))
        XCTAssertTrue(output.contains("[email-redacted]"))
    }

    func testRedactsUUIDsInLogLines() {
        let input = "Account 9F8E7D6C-5B4A-3210-FEDC-BA9876543210 fetched catalog"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("9F8E7D6C-5B4A-3210-FEDC-BA9876543210"))
        XCTAssertTrue(output.contains("[uuid-redacted]"))
    }

    // MARK: - Payment card / PAN redaction (PP-4842)

    // Root cause of PP-4842: redaction was keyword-triggered (barcode/pin/token
    // had rules, "card" did not), so a 16-digit PAN a patron typed into the
    // description survived raw into the support ticket. These pin the generic
    // long-digit-run rule: a Luhn-valid 13–19 digit run is a PAN regardless of
    // any surrounding keyword, and an unlabeled card number must not leak.

    func testRedactsCardNumber_spaced_stripsAllDigits() {
        let input = "cant pay, my card 4111 1111 1111 1111 keeps declining"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("4111"), "No fragment of the PAN may survive")
        XCTAssertFalse(output.contains("1111 1111"), "Spaced PAN must be fully redacted")
        XCTAssertTrue(output.contains("[number-redacted]"))
    }

    func testRedactsCardNumber_dashed_stripsAllDigits() {
        let input = "charge failed on 4111-1111-1111-1111 today"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("4111"))
        XCTAssertFalse(output.contains("1111-1111"))
        XCTAssertTrue(output.contains("[number-redacted]"))
    }

    func testRedactsCardNumber_contiguous_stripsAllDigits() {
        // No keyword, no separators — pure 16-digit Luhn-valid run. This is the
        // exact shape that survived in the reproduced bug.
        let input = "4111111111111111"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("4111111111111111"))
        XCTAssertEqual(output, "[number-redacted]")
    }

    func testRedactsCardNumber_inProse_stripsDigits() {
        let input = "cant pay, card 4111 1111 1111 1111 declined at checkout"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("4111"))
        XCTAssertFalse(output.contains("1111"))
        XCTAssertTrue(output.contains("declined at checkout"), "Surrounding prose is preserved")
    }

    func testRedactsCardNumber_19digitMaestro_stripsDigits() {
        // Upper bound of the PAN range (19 digits) — Luhn-valid Maestro-length.
        let input = "tried 6011111111111111110 no luck"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("6011111111111111110"))
        XCTAssertTrue(output.contains("[number-redacted]"))
    }

    func testRedactsCardNumber_labeledButLuhnInvalid_viaKeyword_stripsDigits() {
        // A mistyped (Luhn-invalid) number that is explicitly labeled "card"
        // must still be redacted via the payment-keyword path — defense in depth.
        let input = "my card 4111 1111 1111 1112 was rejected"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("4111"), "Keyword-labeled card must redact even when Luhn-invalid")
        XCTAssertFalse(output.contains("1112"))
        XCTAssertTrue(output.contains("[number-redacted]"))
    }

    func testRedactsBarcode_prose14Digits_stillRedacts() {
        // The existing barcode rule needs a colon/equals; a prose "barcode is
        // <14 digits>" has neither. The generic run + barcode keyword covers it.
        let input = "my barcode is 21234567890123 and it wont scan"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("21234567890123"), "Prose 14-digit barcode must still redact")
        XCTAssertTrue(output.contains("[number-redacted]"))
    }

    func testDoesNotRedact_isbn13_withoutPaymentKeyword() {
        // ISBN-13 is not sensitive and is not Luhn-valid; with no payment
        // keyword nearby it must pass through so we don't over-redact.
        let input = "Catalog lookup for ISBN 9780306406157 returned no match"
        let output = redactor.redactLine(input)
        XCTAssertTrue(output.contains("9780306406157"), "A bare non-Luhn ISBN must NOT be redacted")
        XCTAssertFalse(output.contains("[number-redacted]"))
    }

    func testDoesNotRedact_yearAndVersionNumbers() {
        let input = "app 3.3.0 (487) launched in 2024 build 487"
        let output = redactor.redactLine(input)
        XCTAssertEqual(output, input, "Short numbers (versions, years, builds) must not trip the PAN rule")
    }

    func testDoesNotRedact_shortPinLikeNumber() {
        let input = "session code 1234 issued"
        let output = redactor.redactLine(input)
        XCTAssertTrue(output.contains("1234"), "A short 4-digit number is not a PAN")
        XCTAssertFalse(output.contains("[number-redacted]"))
    }

    func testDoesNotRedact_benignLongNumber_whenKeywordOnlyFollowsIt() {
        // The payment-keyword path is scoped to the run's *preceding* context.
        // A non-Luhn number followed later by "card" must NOT be redacted — this
        // is what stops a card keyword from swallowing an ISBN sharing the line.
        let input = "reference 9780306406157 was later charged to my card"
        let output = redactor.redactLine(input)
        XCTAssertTrue(output.contains("9780306406157"), "Keyword after a benign number must not trigger redaction")
        XCTAssertFalse(output.contains("[number-redacted]"))
    }

    // MARK: - Bidi / RTL-override control stripping (PP-4842)

    func testStripsBidiControlCharacters() {
        // U+202E (RLO) + U+2066 (LRI) can visually reverse/spoof displayed text.
        let input = "amount \u{202E}drac\u{2069} due \u{200F}now\u{200E}"
        let output = redactor.redactLine(input)
        for scalar: UInt32 in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F] {
            XCTAssertFalse(
                output.unicodeScalars.contains { $0.value == scalar },
                "Bidi control U+\(String(scalar, radix: 16)) must be stripped"
            )
        }
        XCTAssertTrue(output.contains("drac"), "Visible text content is preserved, only controls removed")
    }

    func testStripsBidiControl_cannotSplitCardNumberToEvadeRedaction() {
        // A PAN with bidi controls spliced between its digits would dodge a
        // naive digit-run match. Stripping controls FIRST re-joins the run so
        // it is caught and redacted.
        let input = "card 4111\u{202E}1111\u{2066}1111\u{2069}1111 declined"
        let output = redactor.redactLine(input)
        XCTAssertFalse(output.contains("4111"), "Bidi-spliced PAN must not survive")
        XCTAssertFalse(output.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x2066 })
        XCTAssertTrue(output.contains("[number-redacted]"))
    }

    // MARK: - Library UUID hashing

    func testHashesLibraryUUIDDeterministically() {
        let raw = "9F8E7D6C-5B4A-3210-FEDC-BA9876543210"
        let first = redactor.hashIdentifier(raw)
        let second = redactor.hashIdentifier(raw)
        XCTAssertEqual(first, second, "Same input must hash to same output for cluster bucketing")
        XCTAssertTrue(first.hasPrefix("anon-"))
        XCTAssertFalse(first.contains(raw), "Hash must not contain the raw UUID")
    }

    func testHashesDifferentUUIDsToDifferentValues() {
        let a = redactor.hashIdentifier("aaaa1111-2222-3333-4444-555566667777")
        let b = redactor.hashIdentifier("bbbb2222-3333-4444-5555-666677778888")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Snapshot-level redaction

    func testRedactSnapshot_redactsLibraryUUIDAndLogLines() {
        let raw = ContextSnapshot(
            appVersion: "3.0.3",
            appBuild: "478",
            osVersion: "26.4.2",
            deviceModel: "iPhone17,2",
            libraryName: "Morton Public Library",
            libraryUUID: "ABCDEF12-3456-7890-ABCD-EF1234567890",
            recentLogLines: [
                "Authorization: Bearer real-token-value-12345",
                "Connecting to LCP server"
            ]
        )

        let redacted = redactor.redact(raw)

        XCTAssertNotEqual(redacted.libraryUUID, raw.libraryUUID, "UUID must be hashed")
        XCTAssertEqual(redacted.libraryName, raw.libraryName, "Library name is not sensitive")
        XCTAssertEqual(redacted.appVersion, raw.appVersion, "Version is not sensitive")
        XCTAssertFalse(
            redacted.recentLogLines[0].contains("real-token-value-12345"),
            "Token must be stripped from log line"
        )
        XCTAssertEqual(
            redacted.recentLogLines[1],
            "Connecting to LCP server",
            "Non-sensitive log lines pass through untouched"
        )
    }

    // Fix 2 (PP-4807): the opt-in library barcode is hashed by redact(_:) via
    // `.map(hashIdentifier)`. Mirror the libraryUUID hashing test so that if the
    // `.map(hashIdentifier)` is ever dropped, an opted-in RAW card number would
    // ship — and this test catches it.
    func testRedactSnapshot_hashesLibraryBarcode() {
        let rawBarcode = "21234000012345"
        let raw = ContextSnapshot(
            appVersion: "3.3.0",
            appBuild: "500",
            osVersion: "26.4.2",
            deviceModel: "iPhone17,2",
            libraryBarcode: rawBarcode
        )

        let redacted = redactor.redact(raw)

        XCTAssertNotEqual(redacted.libraryBarcode, rawBarcode, "Barcode must be hashed, never raw")
        XCTAssertEqual(redacted.libraryBarcode?.hasPrefix("anon-"), true, "Barcode must be hash-shaped")
    }

    func testRedactSnapshot_isIdempotent() {
        let raw = ContextSnapshot(
            appVersion: "3.0.3",
            appBuild: "478",
            osVersion: "26.4.2",
            deviceModel: "iPhone17,2",
            recentLogLines: ["Authorization: Bearer token-abc-12345-def"]
        )

        let once = redactor.redact(raw)
        let twice = redactor.redact(once)
        XCTAssertEqual(once, twice, "Redacting twice must produce the same snapshot")
    }
}
