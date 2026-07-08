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
