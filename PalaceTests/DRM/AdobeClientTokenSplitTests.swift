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
        let result = AdobeDRMService.splitClientToken("vendorUser|secretPassword")
        XCTAssertEqual(result?.username, "vendorUser")
        XCTAssertEqual(result?.password, "secretPassword")
    }

    /// A token may legitimately contain separators before the final one; only
    /// the LAST is the password boundary. Rejoining with "|" preserves that.
    func test_split_multipleSeparators_onlyTheLastIsThePasswordBoundary() {
        let result = AdobeDRMService.splitClientToken("a|b|c|secret")
        XCTAssertEqual(result?.username, "a|b|c",
                       "everything before the final separator is the username")
        XCTAssertEqual(result?.password, "secret")
    }

    func test_split_stripsNewlines() {
        let result = AdobeDRMService.splitClientToken("vendor\nUser|secret\n")
        XCTAssertEqual(result?.username, "vendorUser")
        XCTAssertEqual(result?.password, "secret")
    }

    // MARK: - Malformed — the defect

    /// THE regression case. Before the guard this produced
    /// (username: "", password: "<whole token>") and handed it to Adobe.
    func test_split_noSeparator_returnsNilRatherThanAnEmptyUsername() {
        XCTAssertNil(AdobeDRMService.splitClientToken("tokenWithNoSeparator"),
                     "a token with no separator must be rejected here — sending Adobe an empty username surfaces as an indistinguishable authenticationFailed")
    }

    func test_split_emptyPassword_returnsNil() {
        XCTAssertNil(AdobeDRMService.splitClientToken("username|"),
                     "an empty password cannot authenticate; fail with a distinct error instead")
    }

    func test_split_emptyUsername_returnsNil() {
        XCTAssertNil(AdobeDRMService.splitClientToken("|secret"),
                     "an empty username cannot authenticate; fail with a distinct error instead")
    }

    func test_split_emptyToken_returnsNil() {
        XCTAssertNil(AdobeDRMService.splitClientToken(""))
    }

    func test_split_separatorOnly_returnsNil() {
        XCTAssertNil(AdobeDRMService.splitClientToken("|"))
    }
}
