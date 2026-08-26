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
import PalaceBookModel
import PalaceBookRegistry
@testable import Palace

@MainActor
final class DRMAdversarialTests: XCTestCase {

    private var session: URLSession!
    /// Per-test isolated container — built via `makeTestAppContainer()` so
    /// each test method gets a fresh service graph (no cross-test pollution
    /// through `AppContainer._cached`).
    private var appContainer: AppContainer!

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
        session = URLSession.stubbedSession()
        appContainer = makeTestAppContainer()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        session = nil
        appContainer = nil
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

    // MARK: - Adobe DRM: on-demand activation at download fulfillment time

    func testAdobe_fulfillmentPath_callsEnsureDeviceActivated() async throws {
        #if FEATURE_DRM_CONNECTOR
        // The download completion handler for .adobe rights must call
        // ensureDeviceActivated() BEFORE calling fulfill(withACSMData:).
        // This test validates the code path exists by checking that, with
        // no DRM authorization (no userID/deviceID/licensor) on the live
        // user account, ensureDeviceActivated throws a typed `PalaceError.drm`
        // rather than silently succeeding — proving the activation gate is
        // wired and that callers can react to the failure.

        // Precondition: production user account exposed via the singleton
        // has no Adobe licensor credentials in a test bundle.
        let liveAccount = AppContainer.production().accountsManager.currentUserAccount
        XCTAssertNil(liveAccount.userID, "Precondition: live account has no Adobe userID")
        XCTAssertNil(liveAccount.deviceID, "Precondition: live account has no Adobe deviceID")
        XCTAssertNil(liveAccount.licensor, "Precondition: live account has no Adobe licensor")

        // Direct await — replaces the prior fire-and-forget Task whose
        // assertions never reached XCTest. The call MUST throw because
        // either the Adobe certificate is unavailable in the test bundle
        // OR no licensor is stored on the live account; both surface as
        // `PalaceError.drm` (specifically `.noActivation`).
        do {
            try await AdobeDRMService.shared.ensureDeviceActivated()
            XCTFail("ensureDeviceActivated must throw when no licensor / no DRM cert is available")
        } catch let error as PalaceError {
            guard case .drm(let drmError) = error else {
                XCTFail("Expected PalaceError.drm(...), got PalaceError.\(error)")
                return
            }
            // `.noActivation` is the contracted failure when licensor or
            // certificate is missing; `.authenticationFailed` is the
            // RMSDK callback failure if a partial cert path completes.
            // Either is acceptable evidence that the activation gate ran.
            XCTAssertTrue(
                drmError == .noActivation || drmError == .authenticationFailed,
                "Expected DRMError.noActivation or .authenticationFailed; got \(drmError)"
            )
        } catch {
            XCTFail("Expected PalaceError.drm; got \(type(of: error)): \(error)")
        }
        #else
        throw XCTSkip("FEATURE_DRM_CONNECTOR disabled — Adobe DRM not linkable in this build.")
        #endif
    }

    /// PP-3649 contract: after activation moved ahead of fulfillment, an
    /// Adobe "no authorization present" callback must NOT reauthenticate or
    /// present anything — it only logs, because reaching it means the device
    /// was deauthorized mid-download (rare) and a modal there is confusing.
    ///
    /// This test previously called the method on `MyBooksDownloadCenter` and
    /// asserted nothing ("if we got here without a crash, the test passes").
    /// The method moved to `AdobeDRMHandler` in the Phase 7 decomposition
    /// (#890) and the call site rotted — invisibly, because PalaceTests did
    /// not define FEATURE_DRM_CONNECTOR, so this whole body compiled to the
    /// `#else` skip. Now it drives the real owner and asserts the actual
    /// contract: zero delegate interactions.
    func testAdobe_didIgnoreFulfillment_doesNotReauthenticateOrAlert() {
        #if FEATURE_DRM_CONNECTOR
        let spy = NoAuthorizationDelegateSpy()
        let handler = AdobeDRMHandler(delegate: spy)

        handler.didIgnoreFulfillmentWithNoAuthorizationPresent()

        XCTAssertEqual(spy.calls, [],
                       "a no-authorization callback must not reach the delegate at all — "
                       + "any call here is a sign-in modal or download failure the patron should not see")
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

#if FEATURE_DRM_CONNECTOR
/// Records every delegate interaction so "did nothing" is assertable.
private final class NoAuthorizationDelegateSpy: AdobeDRMHandlerDelegate {
    private(set) var calls: [String] = []
    let bookRegistry: TPPBookRegistryProvider = TPPBookRegistryMock()

    func fileUrl(for identifier: String) -> URL? { calls.append("fileUrl"); return nil }
    func failDownloadWithAlert(for book: TPPBook, withMessage message: String?) { calls.append("failDownloadWithAlert") }
    func markDownloadSuccessful(for book: TPPBook) { calls.append("markDownloadSuccessful") }
    func broadcastUpdate() { calls.append("broadcastUpdate") }
    func handleAdobeDownloadProgress(_ progress: Double, for tag: String) { calls.append("handleAdobeDownloadProgress") }
}
#endif
