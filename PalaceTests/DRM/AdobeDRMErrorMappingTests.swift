//
//  AdobeDRMErrorMappingTests.swift
//  PalaceTests
//
//  PP-3649. The activation failure path threw a hardcoded
//  `PalaceError.drm(.authenticationFailed)` no matter what Adobe reported, so
//  every failure showed "Please sign out and sign in again."
//
//  For E_ACT_TOO_MANY_ACTIVATIONS that advice is worse than useless: signing
//  back in consumes ANOTHER activation — the very resource that has run out.
//  Observed on device 2026-09-09: adobeOriginalCode
//  `E_ACT_TOO_MANY_ACTIVATIONS ... 7528:528:7528` reached the patron as a
//  sign-in prompt.
//
//  These pin the mapping AT THE SOURCE, which is the last point where the
//  original NSError still exists — downstream it is a PalaceError and Adobe's
//  code is gone. A first attempt at this mapped downstream and silently did
//  nothing for exactly that reason.
//

import XCTest
@testable import Palace

final class AdobeDRMErrorMappingTests: XCTestCase {

    private func adeptError(_ code: NYPLADEPTError) -> NSError {
        NSError(domain: NYPLADEPTErrorDomain, code: code.rawValue, userInfo: nil)
    }

    /// The regression: quota exhaustion must NOT advise signing in again.
    func test_tooManyActivations_mapsToTooManyActivations_notAuthFailure() {
        let mapped = AdobeDRMService.drmError(for: adeptError(.tooManyActivations))

        XCTAssertEqual(mapped, .tooManyActivations,
                       "quota exhaustion told to sign in again sends the patron to consume another activation")
        XCTAssertEqual(mapped.recoverySuggestion, "Please deauthorize a device and try again.")
    }

    func test_authenticationFailed_mapsToAuthenticationFailed() {
        let mapped = AdobeDRMService.drmError(for: adeptError(.authenticationFailed))

        XCTAssertEqual(mapped, .authenticationFailed)
        XCTAssertEqual(mapped.recoverySuggestion, "Please sign out and sign in again.")
    }

    func test_notActivatedCases_mapToNoActivation() {
        XCTAssertEqual(AdobeDRMService.drmError(for: adeptError(.userNotActivated)), .noActivation)
        XCTAssertEqual(AdobeDRMService.drmError(for: adeptError(.invalidUserActivation)), .noActivation)
    }

    func test_otherAdeptCodes_mapToGenericAdobeError() {
        XCTAssertEqual(AdobeDRMService.drmError(for: adeptError(.documentExpired)), .adobeError)
        XCTAssertEqual(AdobeDRMService.drmError(for: adeptError(.deviceNotActivated)), .adobeError)
    }

    /// A non-ADEPT error must not be mis-attributed to Adobe.
    func test_foreignDomain_fallsBackToAuthenticationFailed() {
        let foreign = NSError(domain: "SomeOtherDomain", code: 5, userInfo: nil)

        XCTAssertEqual(AdobeDRMService.drmError(for: foreign), .authenticationFailed,
                       "code 5 in another domain is not TooManyActivations")
    }

    /// The exact shape that defeated the first attempt: an already-flattened
    /// PalaceError carries no ADEPT domain, so mapping it yields the fallback.
    /// This is why the mapping lives at the source and not at the call site.
    func test_alreadyFlattenedPalaceError_cannotBeRemapped() {
        let flattened = PalaceError.drm(.tooManyActivations)

        XCTAssertEqual(AdobeDRMService.drmError(for: flattened), .authenticationFailed,
                       "documents WHY mapping must happen where the NSError still exists")
    }
}
