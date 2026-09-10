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
        let mapped = PalaceError.drmError(for: adeptError(.tooManyActivations))

        XCTAssertEqual(mapped, .tooManyActivations,
                       "quota exhaustion told to sign in again sends the patron to consume another activation")
        XCTAssertEqual(mapped.recoverySuggestion, "Please deauthorize a device and try again.")
    }

    func test_authenticationFailed_mapsToAuthenticationFailed() {
        let mapped = PalaceError.drmError(for: adeptError(.authenticationFailed))

        XCTAssertEqual(mapped, .authenticationFailed)
        XCTAssertEqual(mapped.recoverySuggestion, "Please sign out and sign in again.")
    }

    func test_notActivatedCases_mapToNoActivation() {
        XCTAssertEqual(PalaceError.drmError(for: adeptError(.userNotActivated)), .noActivation)
        XCTAssertEqual(PalaceError.drmError(for: adeptError(.invalidUserActivation)), .noActivation)
    }

    func test_otherAdeptCodes_mapToGenericAdobeError() {
        XCTAssertEqual(PalaceError.drmError(for: adeptError(.documentExpired)), .adobeError)
        XCTAssertEqual(PalaceError.drmError(for: adeptError(.deviceNotActivated)), .adobeError)
    }

    /// A non-ADEPT error must not be mis-attributed to Adobe, and must not
    /// inherit the "sign out and sign in again" advice either.
    ///
    /// This assertion is INVERTED from its first version. The mapper originally
    /// fell back to `.authenticationFailed`, which is the one recovery hint that
    /// tells a patron to spend another activation — the advice PP-3649 exists to
    /// stop giving. An error we cannot name is not evidence the credentials are
    /// bad. `.adobeError` says "contact support if this persists", which is what
    /// an unrecognised DRM fault actually warrants, and it is what the
    /// pre-existing `PalaceError.from` mapping already answered for every
    /// unmapped ADEPT code (`AdobeDRMCharacterizationTests`). Two mapping tables
    /// disagreeing on the fallback is exactly why there is now only one.
    func test_foreignDomain_fallsBackToAdobeError_notAuthenticationFailed() {
        let foreign = NSError(domain: "SomeOtherDomain", code: 5, userInfo: nil)

        XCTAssertEqual(PalaceError.drmError(for: foreign), .adobeError,
                       "code 5 in another domain is not TooManyActivations, and is not proof of bad credentials")
        XCTAssertEqual(PalaceError.drmError(for: foreign).recoverySuggestion,
                       "Please contact support if this problem persists.")
    }

    /// The activation path synthesises this exact error when RMSDK reports
    /// failure with no error object. Before consolidation it mapped to
    /// `.authenticationFailed` and told the patron to sign in again.
    func test_synthesisedActivationFailure_fallsBackToAdobeError() {
        let synthesised = NSError(domain: "AdobeDRM", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Adobe device activation failed"])

        XCTAssertEqual(PalaceError.drmError(for: synthesised), .adobeError)
    }

    /// An ADEPT-domain code with no enum case must still land on the fallback
    /// rather than escaping the switch.
    func test_unknownAdeptCode_inAdeptDomain_fallsBackToAdobeError() {
        let unknown = NSError(domain: NYPLADEPTErrorDomain, code: 9_999, userInfo: nil)

        XCTAssertEqual(PalaceError.drmError(for: unknown), .adobeError)
    }

    /// The exact shape that defeated the first attempt: an already-flattened
    /// PalaceError carries no ADEPT domain, so mapping it yields the fallback.
    /// This is why the mapping lives at the source and not at the call site.
    func test_alreadyFlattenedPalaceError_cannotBeRemapped() {
        let flattened = PalaceError.drm(.tooManyActivations)

        XCTAssertEqual(PalaceError.drmError(for: flattened), .adobeError,
                       "documents WHY mapping must happen where the NSError still exists")
    }

    // MARK: - One table, reached from both directions

    /// `PalaceError.from` and the activation path must agree, because they are
    /// now the same table. A second copy is how `.userNotActivated` came to mean
    /// two different things to the patron depending on which call site raised it.
    func test_palaceErrorFrom_andDirectMapping_agreeOnEveryAdeptCase() {
        let cases: [NYPLADEPTError] = [
            .unknown, .cancelled, .invalidUserActivation, .userNotActivated,
            .authenticationFailed, .tooManyActivations, .documentExpired,
            .loanNotOnRecord, .badLoanIDReturn, .deviceNotActivated,
            .expiredACSM, .alreadyFulfilledByOther, .alreadyReturned,
            .credentialsRequiredToFulfill, .wrongDeviceType, .notReady,
            .documentCreateError
        ]
        for adept in cases {
            let ns = adeptError(adept)
            guard case .drm(let viaFrom) = PalaceError.from(ns) else {
                XCTFail("ADEPT-domain error \(adept) must route into .drm, got \(PalaceError.from(ns))")
                continue
            }
            XCTAssertEqual(viaFrom, PalaceError.drmError(for: ns),
                           "the two entry points disagree for \(adept)")
        }
    }
}
