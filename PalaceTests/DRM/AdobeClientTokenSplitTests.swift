//
//  AdobeClientTokenSplitTests.swift
//  PalaceTests
//
//  PP-3649. Adobe device activation has failed for 4,013 production users
//  across 25,421 events since 3.0.0, always reported as `authenticationFailed`
//  and never with a cause. One shape hiding inside that number is a client
//  token the app itself mangles before Adobe ever sees it: the previous
//  inline split set `password` to the whole string and `username` to "" when
//  the token carried no "|" separator. Adobe answers an empty username with
//  `authenticationFailed` — the same answer it gives a genuinely rejected
//  credential, which is why the two were indistinguishable in the field.
//
//  These pin the split so the malformed case is REPRESENTABLE (nil) rather
//  than silently producing credentials that cannot succeed.
//

import XCTest
@testable import Palace

final class AdobeClientTokenSplitTests: XCTestCase {

    // MARK: - Well-formed

    func test_split_wellFormedToken_returnsBothHalves() {
        let result = AdobeClientToken.split("vendorUser|secretPassword")
        XCTAssertEqual(result?.username, "vendorUser")
        XCTAssertEqual(result?.password, "secretPassword")
    }

    /// A token may legitimately contain separators before the final one; only
    /// the LAST is the password boundary. Rejoining with "|" preserves that.
    func test_split_multipleSeparators_onlyTheLastIsThePasswordBoundary() {
        let result = AdobeClientToken.split("a|b|c|secret")
        XCTAssertEqual(result?.username, "a|b|c",
                       "everything before the final separator is the username")
        XCTAssertEqual(result?.password, "secret")
    }

    func test_split_stripsNewlines() {
        let result = AdobeClientToken.split("vendor\nUser|secret\n")
        XCTAssertEqual(result?.username, "vendorUser")
        XCTAssertEqual(result?.password, "secret")
    }

    // MARK: - Malformed — the defect

    /// THE regression case. Before the guard this produced
    /// (username: "", password: "<whole token>") and handed it to Adobe.
    func test_split_noSeparator_returnsNilRatherThanAnEmptyUsername() {
        XCTAssertNil(AdobeClientToken.split("tokenWithNoSeparator"),
                     "a token with no separator must be rejected here — sending Adobe an empty username surfaces as an indistinguishable authenticationFailed")
    }

    func test_split_emptyPassword_returnsNil() {
        XCTAssertNil(AdobeClientToken.split("username|"),
                     "an empty password cannot authenticate; fail with a distinct error instead")
    }

    func test_split_emptyUsername_returnsNil() {
        XCTAssertNil(AdobeClientToken.split("|secret"),
                     "an empty username cannot authenticate; fail with a distinct error instead")
    }

    func test_split_emptyToken_returnsNil() {
        XCTAssertNil(AdobeClientToken.split(""))
    }

    func test_split_separatorOnly_returnsNil() {
        XCTAssertNil(AdobeClientToken.split("|"))
    }

    // MARK: - Expiry (the CM's 60-minute TTL, made local and testable)

    func test_expiry_readsTheNumericDateFromTheSecondField() {
        // SHORTNAME|expires|patronIdentifier|signature, `expires` a NumericDate.
        XCTAssertEqual(AdobeClientToken.expiry("PALACE|1893456000|patron-1|sig"),
                       Date(timeIntervalSince1970: 1_893_456_000))
    }

    /// The boundary the `fields.count >= 2` guard sits on. A four-segment token
    /// (what the CM actually mints) leaves THREE fields in the username, so it
    /// never exercises the edge; a three-segment one leaves exactly two. Without
    /// this, tightening the guard to `> 2` makes every such token report no
    /// expiry — i.e. never stale — with the suite green. Measured: that mutant
    /// survived until this test existed.
    func test_expiry_threeSegmentToken_stillYieldsAnExpiry() {
        XCTAssertEqual(AdobeClientToken.expiry("PALACE|1893456000|sig"),
                       Date(timeIntervalSince1970: 1_893_456_000))
    }

    func test_expiry_unparseableToken_isNilNotZero() {
        // Zero would read as 1970 — i.e. "expired" — and manufacture staleness
        // out of a DIFFERENT defect. `split` owns the malformed case.
        XCTAssertNil(AdobeClientToken.expiry("tokenWithNoSeparator"))
    }

    func test_expiry_nonNumericExpiresField_isNil() {
        XCTAssertNil(AdobeClientToken.expiry("PALACE|not-a-number|patron-1|sig"))
    }

    func test_expiry_tokenWithTooFewFields_isNil() {
        // Splits fine (one separator) but carries no expiry field.
        XCTAssertNotNil(AdobeClientToken.split("PALACE|sig"))
        XCTAssertNil(AdobeClientToken.expiry("PALACE|sig"))
    }

    // MARK: - Redaction (these tokens are live credentials for 60 minutes)

    func test_redacted_neverContainsTheSignature() {
        // `Documents/Logs/palace_error.log` is exportable by the patron and is
        // routinely attached to support tickets. This is the assertion that
        // matters: the secret half must not survive.
        let signature = "s3cr3tSignatureValue"
        let output = AdobeClientToken.redacted("PALACE|1893456000|patron-1|\(signature)")

        XCTAssertFalse(output.contains(signature),
                       "the signature reached the log: \(output)")
    }

    func test_redacted_neverContainsThePatronIdentifier() {
        // The third field identifies the patron to the CM. It is not the
        // barcode, but it is a stable per-patron identifier and has no
        // diagnostic use that the library name and expiry do not already serve.
        let output = AdobeClientToken.redacted("PALACE|1893456000|urn:uuid:patron-4a1f|sig")

        XCTAssertFalse(output.contains("urn:uuid:patron-4a1f"),
                       "the patron identifier reached the log: \(output)")
    }

    func test_redacted_keepsWhatDiagnosisActuallyNeeds() {
        // Which library minted it and when it dies are the two questions asked
        // of this value in every investigation so far; both are non-secret.
        let output = AdobeClientToken.redacted("PALACE|1893456000|patron-1|sig")

        XCTAssertTrue(output.contains("PALACE"), output)
        XCTAssertTrue(output.contains("2030-01-01"), "expiry should be readable: \(output)")
    }

    func test_redacted_reportsTheSignatureLength_soAnEmptyOneIsDistinguishable() {
        let output = AdobeClientToken.redacted("PALACE|1893456000|patron-1|abcdefgh")

        XCTAssertTrue(output.contains("8-char"),
                      "length is how a truncated signature is told from a whole one: \(output)")
    }

    func test_redacted_distinguishesAbsentFromMalformed() {
        // "none" and "unparseable" are different defects with different fixes,
        // and collapsing them is how a malformed token reads as no token.
        XCTAssertEqual(AdobeClientToken.redacted(nil), "none")
        XCTAssertEqual(AdobeClientToken.redacted(""), "none")
        XCTAssertTrue(AdobeClientToken.redacted("garbage").contains("unparseable"))
    }

    func test_redacted_malformedTokenIsNotEchoedBack() {
        // An unparseable value is still whatever the server sent, and this
        // branch is reached with real credentials often enough (a truncated
        // token still contains most of a live signature).
        let output = AdobeClientToken.redacted("A-LONG-UNSPLITTABLE-SECRET")

        XCTAssertFalse(output.contains("A-LONG-UNSPLITTABLE-SECRET"), output)
        XCTAssertTrue(output.contains("26 chars"), output)
    }
}
