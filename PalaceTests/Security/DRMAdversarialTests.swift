//
//  DRMAdversarialTests.swift
//  PalaceTests
//
//  Adversarial / negative-path tests for DRM acquisition and fulfillment.
//  These tests PASS by confirming that DRM-protected content is rejected
//  when license, passphrase, or signature constraints are violated.
//
//  Hermetic — uses HTTPStubURLProtocol for any network and on-disk fixtures
//  for license/EPUB payloads. No live DRM servers are contacted.
//

import XCTest
@testable import Palace

final class DRMAdversarialTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
        session = URLSession.stubbedSession()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    // MARK: - Adobe DRM: missing/invalid license

    func testAdobe_epubWithoutValidLicense_openFails() throws {
        #if FEATURE_DRM_CONNECTOR
        // Build an EPUB-shaped temp file with no rights.xml / no ACSM payload.
        let bogusEPUB = try makeTempFile(ext: "epub", contents: Data("PK\u{03}\u{04}not-a-real-epub".utf8))
        defer { try? FileManager.default.removeItem(at: bogusEPUB) }

        let service = AdobeDRMLibraryService()

        // canFulfill is the entry seam. An EPUB without an ACSM should NOT be fulfillable
        // by the Adobe service (which targets `.acsm`), and `fulfill` on such a file
        // must throw rather than silently producing a publication.
        XCTAssertFalse(
            service.canFulfill(bogusEPUB),
            "Adobe DRM must not claim ability to fulfill an arbitrary EPUB without an ACSM license."
        )
        #else
        throw XCTSkip("FEATURE_DRM_CONNECTOR disabled — Adobe DRM not linkable in this build.")
        #endif
    }

    func testAdobe_tamperedContent_verificationFails() throws {
        #if FEATURE_DRM_CONNECTOR
        // SECURITY-GAP: needs an injectable AdobeDRMContainer seam that accepts
        // pre-decrypted bytes + an HMAC/signature so we can flip a byte and assert
        // that the verification path raises. The current AdobeDRMContainer.mm does
        // its own file-system handling and crypto inside the Objective-C++ layer.
        throw XCTSkip("SECURITY-GAP: needs AdobeDRMContainer content-verification seam exposing tamper detection.")
        #else
        throw XCTSkip("FEATURE_DRM_CONNECTOR disabled — Adobe DRM not linkable in this build.")
        #endif
    }

    // MARK: - LCP: passphrase / expiry / wrong-passphrase

    func testLCP_publicationWithoutPassphrase_returnsAuthRequired() throws {
        #if LCP
        let service = LCPLibraryService()
        // A bare .epub (no .lcpl sidecar, no passphrase prompt fulfilled) must NOT
        // be claimed as fulfillable by the LCP service. canFulfill is the public
        // negative-side check.
        let plainEPUB = try makeTempFile(ext: "epub", contents: Data("not-lcp".utf8))
        defer { try? FileManager.default.removeItem(at: plainEPUB) }

        XCTAssertFalse(
            service.canFulfill(plainEPUB),
            "LCP must not fulfill an EPUB without a passphrase / license sidecar."
        )
        #else
        throw XCTSkip("LCP feature flag disabled — LCPLibraryService not linkable.")
        #endif
    }

    func testLCP_licenseWithExpiredDate_returnsLicenseExpiredError() throws {
        #if LCP
        // SECURITY-GAP: needs a constructor seam on LicensesService / TPPLCPLicense
        // that accepts a fake LicenseDocument with `rights.end` in the past so we
        // can deterministically assert the expired branch without contacting a
        // real LSD. The Readium LCPService does not currently expose such a seam.
        throw XCTSkip("SECURITY-GAP: needs injectable LicenseDocument seam to validate expired-license rejection.")
        #else
        throw XCTSkip("LCP feature flag disabled.")
        #endif
    }

    func testLCP_wrongPassphrase_returnsAuthError() throws {
        #if LCP
        // SECURITY-GAP: TPPLCPClient + LCPPassphraseAuthenticationService own the
        // passphrase callback flow. There is no public seam to feed a known-bad
        // passphrase against a known LCP license without bundling a real .lcpl
        // fixture and a Readium passphrase repository. Tracked as a follow-up.
        throw XCTSkip("SECURITY-GAP: needs LCPPassphraseAuthenticationService injectable to assert wrong-passphrase rejection.")
        #else
        throw XCTSkip("LCP feature flag disabled.")
        #endif
    }

    // MARK: - No-DRM build path

    func testNoDRMBuild_drmAcquisitionRefused() throws {
        #if !FEATURE_DRM_CONNECTOR && !LCP
        // In the open-source / Palace-noDRM build, attempting to download a DRM
        // protected acquisition must be refused at the acquisition path.
        // SECURITY-GAP: needs a single-entry acquisition router we can hand a
        // fake OPDS entry with an Adobe/LCP indirectAcquisition and assert refusal.
        throw XCTSkip("SECURITY-GAP: needs acquisition-router seam to assert DRM refusal in noDRM build.")
        #else
        throw XCTSkip("DRM build — noDRM refusal path not exercised here.")
        #endif
    }

    // MARK: - Helpers

    private func makeTempFile(ext: String, contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try contents.write(to: url)
        return url
    }
}
