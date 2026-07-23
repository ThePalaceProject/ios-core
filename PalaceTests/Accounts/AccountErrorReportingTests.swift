//
//  AccountErrorReportingTests.swift
//  PalaceTests
//
//  Wave 1c (cycle 2): behavior test of the Account error-reporting seam. The
//  Account error paths (auth-doc load/parse, logo failure, profile document)
//  route through an injected `any ErrorReporting` instead of naming
//  TPPErrorLogger directly. This exercises the seam through a REAL error path
//  (loadAuthenticationDocument with no auth-document URL) so a reporter-drop
//  or wrong-code mutant fails.
//

import XCTest
@testable import Palace
import PalaceCatalog
import PalaceLogging

final class AccountErrorReportingTests: XCTestCase {

    private final class SpyErrorReporter: ErrorReporting, @unchecked Sendable {
        private let lock = NSLock()
        private var _codes: [Int] = []
        private var _summaries: [String] = []
        var codes: [Int] { lock.lock(); defer { lock.unlock() }; return _codes }
        var summaries: [String] { lock.lock(); defer { lock.unlock() }; return _summaries }
        func report(_ error: any Error, summary: String, metadata: [String: Any]?) {
            lock.lock(); _summaries.append(summary); lock.unlock()
        }
        func report(code: Int, summary: String, metadata: [String: Any]?) {
            lock.lock(); _codes.append(code); _summaries.append(summary); lock.unlock()
        }
    }

    /// loadAuthenticationDocument with no auth-document URL must report .noURL
    /// through the injected reporter AND complete(false) — the error path that
    /// previously hard-wired TPPErrorLogger. Publication is built WITHOUT the
    /// "application/vnd.opds.authentication.v1.0+json" link so
    /// Account.authenticationDocumentUrl (Account.swift:747) is nil.
    func testLoadAuthenticationDocument_missingURL_reportsNoURL_andCompletesFalse() {
        let account = Account(publication: Self.publicationWithoutAuthDocLink(),
                              imageCache: MockImageCache())
        let spy = SpyErrorReporter()
        account.errorReporter = spy

        let exp = expectation(description: "completion")
        var result: Bool?
        account.loadAuthenticationDocument { ok in result = ok; exp.fulfill() }
        wait(for: [exp], timeout: 2)

        XCTAssertEqual(result, false)
        XCTAssertEqual(spy.codes, [TPPErrorCode.noURL.rawValue])
        XCTAssertTrue(spy.summaries.first?.contains("authentication document") == true)
    }

    /// A publication whose links carry NO auth-document link — so
    /// `authenticationDocumentUrl` resolves to nil and the `.noURL` guard fires.
    /// Mirrors NYPLLibraryAccountsProviderMock.createOPDS2Publication() (a single
    /// non-auth-doc link).
    private static func publicationWithoutAuthDocLink() -> OPDS2Publication {
        let link = OPDS2Link(href: "https://example.org/catalog",
                             type: "application/atom+xml;profile=opds-catalog",
                             rel: "http://opds-spec.org/catalog",
                             templated: false,
                             displayNames: nil,
                             descriptions: nil)
        let metadata = OPDS2Publication.Metadata(updated: Date(),
                                                 description: "no-auth-doc fixture",
                                                 id: "no-auth-doc-id",
                                                 title: "No Auth Doc Library")
        return OPDS2Publication(links: [link], metadata: metadata, images: nil)
    }
}
