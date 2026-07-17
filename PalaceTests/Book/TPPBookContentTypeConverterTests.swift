//
//  TPPBookContentTypeConverterTests.swift
//  PalaceTests
//
//  PP-4161: pins the `.streamingHTML` token + the F-011 exhaustiveness
//  behaviour. The converter drops its `default:` clause in v2 so that
//  the next enum-case addition compile-errors here (forcing a touch);
//  this test fixture covers all enum cases so a missing arm would also
//  produce a missing-string regression.
//

import XCTest
import PalaceCatalog
@testable import Palace

// Renamed to avoid collision with the legacy class of the same name embedded
// in `TPPBookLocationTests.swift` — Module A created this file but the
// pre-existing class lived inline in TPPBookLocationTests. The new class
// scopes to streamingHTML token coverage; legacy `TPPBookContentTypeConverterTests`
// in TPPBookLocationTests still owns the .epub/.audiobook/.pdf/.unsupported cases.
@MainActor
final class TPPBookContentTypeConverterStreamingHTMLTests: XCTestCase {

    // MARK: - PP-4161: Streaming-HTML token

    /// PP-4161: `.streamingHTML` must round-trip to the exact token
    /// "StreamingHTML". Downstream callers (Logging, DeviceSpecificErrorMonitor)
    /// log this string verbatim; a mutant that returns the wrong string
    /// would break log analysis but not crash.
    func testTPPBookContentTypeConverter_stringValue_streamingHTML_returnsExpectedToken() {
        let value = TPPBookContentTypeConverter.stringValue(of: .streamingHTML)
        XCTAssertEqual(value, "StreamingHTML",
                       ".streamingHTML must map to the canonical token 'StreamingHTML' for log/analytics consumers")
        XCTAssertFalse(value.isEmpty)
        // Token must be distinct from every other content-type token
        XCTAssertNotEqual(value, TPPBookContentTypeConverter.stringValue(of: .epub))
        XCTAssertNotEqual(value, TPPBookContentTypeConverter.stringValue(of: .audiobook))
        XCTAssertNotEqual(value, TPPBookContentTypeConverter.stringValue(of: .pdf))
        XCTAssertNotEqual(value, TPPBookContentTypeConverter.stringValue(of: .unsupported))
    }

    /// All five enum cases (epub, audiobook, pdf, unsupported, streamingHTML)
    /// must produce distinct, non-empty tokens. Catches a mutant that returns
    /// the same string for two cases (e.g. defaulting unhandled cases to ""
    /// or to another case's value).
    func testTPPBookContentTypeConverter_stringValue_allCases_returnDistinctNonEmptyTokens() {
        let cases: [TPPBookContentType] = [.epub, .audiobook, .pdf, .unsupported, .streamingHTML]
        let tokens = cases.map { TPPBookContentTypeConverter.stringValue(of: $0) }

        XCTAssertEqual(tokens.count, 5)
        for token in tokens {
            XCTAssertFalse(token.isEmpty, "Every case must produce a non-empty token")
        }
        XCTAssertEqual(Set(tokens).count, 5,
                       "Every enum case must produce a UNIQUE token — duplicates indicate a mis-routed switch arm")
    }
}
