//
//  LCPClientTests.swift
//  PalaceTests
//
//  Critical-path coverage for TPPLCPClient — the Swift wrapper around
//  R2LCPClient / Botan / LCPWrapper that backs LCP fulfillment + decrypt.
//
//  F-002 (Botan/LCP) on Crashlytics: Crashlytics 0ca62d8244, 27 users / 249
//  events on 3.0.0, all in TPPLCPClient.createContext where Botan's BER
//  parser threw an uncaught C++ exception. The fix is a two-layer defense:
//
//    1) Pre-validate the PEM CRL header BEFORE calling R2LCPClient
//       (TPPLCPClient.swift:55-60). Rejects HTML/JSON/garbage up front and
//       throws LCPContextError.invalidPemCrl.
//    2) Wrap the R2LCPClient call in TPPObjCExceptionCatcher.catchAllExceptions
//       so any C++ exception that does sneak through Botan's parser surfaces
//       as LCPContextError.nativeException instead of std::terminate.
//
//  These tests exercise the Swift-side guards without hitting R2LCPClient
//  (which is a private binary framework). The "happy path" createContext +
//  decrypt with valid context paths are excluded because they would require
//  a real LCP license signed by an LCP CA — covered by integration tests
//  in LCPSessionOrphaningTests.swift.
//
//  Build gate: TPPLCPClient lives behind `#if LCP` and is only present in
//  LCP-enabled Palace targets. Tests inherit the gate.
//

#if LCP

import XCTest
@testable import Palace
import ReadiumLCP
import ReadiumShared
import R2LCPClient

@MainActor
final class LCPClientTests: XCTestCase {

    // MARK: - createContext — input validation guards

    func test_createContext_invalidPemCrl_throwsInvalidPemCrl() {
        // The new PEM-header guard added today: a pemCrl that doesn't begin
        // with "-----BEGIN X509 CRL-----" must throw LCPContextError
        // .invalidPemCrl(prefix:) before Botan ever sees the bytes. Trying
        // a HTML response shape (what CDNs serve when the CRL endpoint is
        // misconfigured) — Botan used to crash on this.
        let client = TPPLCPClient()
        let htmlGarbage = "<html><body>Not Found</body></html>"

        XCTAssertThrowsError(
            try client.createContext(
                jsonLicense: "{}",
                hashedPassphrase: "deadbeef",
                pemCrl: htmlGarbage
            ),
            "PEM-CRL header check must reject non-CRL bytes BEFORE handing to Botan"
        ) { error in
            guard case LCPContextError.invalidPemCrl(let prefix) = error else {
                XCTFail("Expected LCPContextError.invalidPemCrl, got \(error)")
                return
            }
            // Prefix should be the first 40 chars of the rejected input so
            // diagnostics can identify what the server actually returned.
            XCTAssertTrue(prefix.hasPrefix("<html>"),
                          "invalidPemCrl prefix must surface the rejected payload's leading bytes for triage, got: \(prefix)")
            XCTAssertLessThanOrEqual(prefix.count, 40,
                                     "invalidPemCrl prefix must be bounded to 40 chars to avoid log spam")
        }
    }

    func test_createContext_botanThrowsDecoding_isCaughtByObjCExceptionWrapper() throws {
        // F-002 fix layer 2: even past the PEM-header guard, R2LCPClient can
        // throw a C++ exception (Botan::Decoding_Error) on a structurally
        // valid PEM with garbage internals. The TPPObjCExceptionCatcher
        // .catchAllExceptions wrapper turns that into a Swift-throwable
        // LCPContextError.nativeException. Without the wrapper, the C++
        // exception bypasses Swift's error machinery entirely and reaches
        // std::terminate — Crashlytics 0ca62d8244.
        //
        // We construct a PEM that PASSES the header guard (so we reach
        // R2LCPClient) but is malformed internally. R2LCPClient throws (or
        // the underlying Botan parser throws), and the catcher must convert
        // that into either:
        //   - LCPContextError.nativeException — the C++ exception path, OR
        //   - a Swift Error rethrown from the do/catch — the Swift path, OR
        //   - LCPContextError.creationReturnedNil — R2LCPClient returned nil
        // What MUST NOT happen: a crash, std::terminate, or silent nil
        // return that downstream code would dereference.
        let client = TPPLCPClient()
        let validHeaderGarbageBody = """
        -----BEGIN X509 CRL-----
        SGVsbG8gV29ybGQhIFRoaXMgaXMgbm90IGEgdmFsaWQgQ1JMLg==
        -----END X509 CRL-----
        """

        do {
            _ = try client.createContext(
                jsonLicense: "{\"not\": \"a license\"}",
                hashedPassphrase: "deadbeef",
                pemCrl: validHeaderGarbageBody
            )
            XCTFail("Garbage CRL body must throw — never silently return")
        } catch let LCPContextError.nativeException(name, reason) {
            // C++ exception was caught by the ObjC wrapper — exactly the
            // F-002 fix path.
            XCTAssertFalse(name.isEmpty,
                           "Native-exception path must surface the C++ exception name for diagnostics")
            _ = reason // reason may be nil on some platforms
        } catch LCPContextError.creationReturnedNil {
            // Alternate failure shape: R2LCPClient returned nil without
            // throwing. Also acceptable — the contract is "do not crash".
        } catch LCPContextError.invalidPemCrl {
            XCTFail("PEM-header guard should have ACCEPTED this input (it has the right header). Rejecting it here means the guard is too aggressive.")
        } catch {
            // R2LCPClient threw a Swift Error — also acceptable. The
            // contract is "produce a Swift-throwable failure, do not crash".
        }
    }

    func test_createContext_validHeaderGarbageJSON_throwsRatherThanReturningNilSilently() {
        // The contract we shipped: every failure mode must throw, never
        // silently return nil. A reverted fix where R2LCPClient.createContext
        // returns nil on garbage would slip through the wrapper if we
        // collapsed the nil-check — guard against that regression by asserting
        // the wrapper always throws on garbage input.
        let client = TPPLCPClient()
        do {
            _ = try client.createContext(
                jsonLicense: "{\"this is not\": \"a valid license\"}",
                hashedPassphrase: "deadbeef",
                pemCrl: ""  // empty pemCrl is accepted by the header guard (trimmed.isEmpty short-circuit)
            )
            XCTFail("Garbage license + empty CRL must throw or propagate underlying error")
        } catch {
            // Any thrown error is acceptable — the contract is no silent
            // success.
        }
    }

    // MARK: - decrypt — empty + non-DRMContext guards

    func test_decrypt_emptyData_returnsNil() {
        // Empty data must short-circuit BEFORE reaching R2LCPClient.decrypt
        // — Botan would attempt to decode 0 bytes and previously crashed.
        let client = TPPLCPClient()
        let context = NotADRMContext() // any LCPClientContext works; data is empty so the type-check guard never runs
        let result = client.decrypt(data: Data(), using: context)
        XCTAssertNil(result,
                     "Empty data must short-circuit to nil — Botan must NEVER be asked to decode 0 bytes")
    }

    func test_decrypt_nonDRMContext_returnsNilWithoutCallingR2LCPClient() {
        // The type-check guard: contexts that aren't DRMContext must bounce
        // before R2LCPClient sees them, so Botan never decodes against a
        // garbage context. Without this guard, R2LCPClient would crash on
        // an `as!` cast inside the framework.
        let client = TPPLCPClient()
        let invalidContext = NotADRMContext()
        let nonEmpty = Data([0x01, 0x02, 0x03])
        let result = client.decrypt(data: nonEmpty, using: invalidContext)
        XCTAssertNil(result,
                     "Non-DRMContext must be rejected before R2LCPClient is called — type-check guard prevents `as!` crash")
    }

    // MARK: - decrypt (extension) — same guards via convenience overload

    func test_decryptExtension_withoutContext_returnsNil() {
        // The extension uses the same type-check guard on `self._context`
        // — calling decrypt(data:) before createContext must return nil
        // rather than dereferencing a nil context.
        let client = TPPLCPClient()
        let result = client.decrypt(data: Data([0x01, 0x02]))
        XCTAssertNil(result,
                     "decrypt(data:) without prior createContext must return nil — no context, no decryption")
    }

    func test_decryptExtension_withEmptyData_returnsNil() {
        // Same empty-data guard on the extension overload.
        let client = TPPLCPClient()
        let result = client.decrypt(data: Data())
        XCTAssertNil(result,
                     "decrypt(data:) with empty data must short-circuit to nil — symmetric with decrypt(data:using:)")
    }

    // MARK: - findOneValidPassphrase — F-002 symmetric wrapper

    func test_findOneValidPassphrase_garbageLicenseJSON_returnsNilWithoutCrashing() {
        // F-002 symmetric gap closure: findOneValidPassphrase used to be a
        // raw pass-through to R2LCPClient with NO exception wrapper. Garbage
        // license JSON ("not-json-at-all", empty string, malformed payload)
        // makes Botan raise std::logic_error ("id value cannot not be null",
        // "expected null, got not") — a C++ exception that escaped Swift's
        // do/catch entirely and crashed the app via std::terminate.
        //
        // The fix mirrors createContext's TPPObjCExceptionCatcher
        // .catchAllExceptions wrapper. The contract this test asserts: any
        // adversarial license JSON returns nil (no valid passphrase found)
        // instead of crashing the test process. If the wrapper is removed
        // or short-circuited, this test crashes the test runner — which is
        // the load-bearing failure signal we want.
        let client = TPPLCPClient()

        // Three garbage shapes that previously triggered std::logic_error
        // from Botan when passed through R2LCPClient.findOneValidPassphrase:
        //   1) Empty license string
        //   2) Non-JSON literal
        //   3) Structurally JSON but missing every license field
        let garbageInputs = [
            "",
            "not-json-at-all",
            "{\"missing\": \"every license field\"}",
        ]
        let hashedPassphrases = [
            "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
        ]

        for garbage in garbageInputs {
            // If the wrapper is present, this returns nil. If the wrapper
            // is removed, Botan's std::logic_error escapes Swift and crashes
            // the test process — the assertion below is never reached, and
            // the test fails by SIGABRT rather than by XCTFail. That crash-
            // shaped failure mode is exactly what makes this test load-bearing
            // for the F-002 symmetric fix.
            let result = client.findOneValidPassphrase(
                jsonLicense: garbage,
                hashedPassphrases: hashedPassphrases
            )
            XCTAssertNil(
                result,
                "findOneValidPassphrase must return nil on garbage license JSON (\(garbage.prefix(40))) — never crash, never return a bogus passphrase"
            )
        }
    }

    // MARK: - getSupportedLCPProfileURIs — PP-4848 (Readium 3.11) facade forwarding

    func test_getSupportedLCPProfileURIs_forwardsLiblcpAdvertisedProfiles() {
        // PP-4848: Readium 3.11 added getSupportedLCPProfileURIs() to the
        // LCPClient protocol WITH a hardcoded default implementation. The
        // facade must NOT rely on that default — it must forward the set the
        // embedded liblcp (R2LCPClient) actually advertises, so ReadiumLCP can
        // raise the correct "profile not supported" error for a license whose
        // profile this liblcp build can't handle (AC #2). If the override were
        // dropped, the facade would silently fall back to Readium's default
        // list — which could claim support liblcp doesn't have.
        let client = TPPLCPClient()
        let facade = client.getSupportedLCPProfileURIs()
        let liblcp = R2LCPClient.getSupportedLCPProfileURIs() ?? []

        // Forwarding contract: facade == exactly what liblcp reports. Kills the
        // "return Readium's default" and "return []" mutants.
        XCTAssertEqual(facade, liblcp,
                       "Facade must forward R2LCPClient.getSupportedLCPProfileURIs() verbatim, not Readium's hardcoded default")
        // Sanity: this liblcp build advertises the standard production profile.
        XCTAssertFalse(facade.isEmpty,
                       "liblcp must advertise at least one supported LCP profile")
        XCTAssertTrue(facade.contains("http://readium.org/lcp/profile-1.0"),
                      "The standard LCP production profile 1.0 must be advertised by this liblcp build")
    }
}

/// A type that is intentionally NOT a DRMContext, used to trip the
/// type-check guard in decrypt(data:using:). Mirrors the same helper used
/// in PalaceTests/RegressionGuards/LCPBotanCRLGuardTests.swift.
private final class NotADRMContext: LCPClientContext {}

// MARK: - Seam Recommendations (do not modify production code from here)
//
// Observations for protocol-extraction follow-up (comment only — do NOT
// modify production from this file):
//
// 1) TPPLCPClient is a concrete class, not a protocol-conforming type. The
//    ReadiumLCP.LCPClient protocol it conforms to is the seam we'd want for
//    LCPLibraryService tests — those currently can't substitute a fake
//    client without subclassing TPPLCPClient. The protocol surface is small
//    (createContext + decrypt + findOneValidPassphrase) — a `protocol
//    TPPLCPClientProtocol` exposing only those three methods would let
//    higher-level tests stub the entire LCP fulfillment path.
//
// 2) The pemCrl header check uses a hardcoded "-----BEGIN X509 CRL-----"
//    literal in TPPLCPClient.swift:56. If RFC 7468 ever extends the PEM
//    label set (it won't, realistically), this comparison would silently
//    reject valid CRLs. Consider routing through a tiny PemValidator type
//    so the test surface for "is this a CRL?" can grow without touching
//    the LCP client itself.
//
// 3) `LCPContextError.nativeException(name:reason:)` exposes the C++
//    exception name as a String. If R2LCPClient changes its exception
//    naming (e.g. "Botan::Decoding_Error" → "Botan_4::Decoding_Error" on
//    a major-version bump), downstream consumers that string-match on the
//    name will silently break. A semantic enum on top of the name (e.g.
//    `.botanDecoding`, `.unknown`) would harden this seam.
//
// 4) findOneValidPassphrase NOW wraps R2LCPClient.findOneValidPassphrase
//    in TPPObjCExceptionCatcher.catchAllExceptions, mirroring the
//    createContext fix and closing the F-002 symmetric gap. The wrapper
//    returns nil on caught C++ exceptions (the same shape callers already
//    handle for the no-match case). The test
//    test_findOneValidPassphrase_garbageLicenseJSON_returnsNilWithoutCrashing
//    locks the wrapper in — removing it crashes the test runner with
//    std::logic_error from Botan rather than failing softly.

#endif
