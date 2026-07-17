#if LCP

import XCTest
@testable import Palace
import ReadiumLCP
import ReadiumShared

/// Regression guards for the Botan X509 CRL decode crash family
/// (249 events on Crashlytics post-3.0.0). When R2LCPClient decrypts data
/// or builds an LCP context against a malformed CRL or invalid context,
/// Botan throws a C++ exception that escapes Swift. The first line of
/// defense is the upstream short-circuit in TPPLCPClient:
/// empty data + non-DRMContext context never reach R2LCPClient.
///
/// The fix surface: Palace/Reader2/ReaderStackConfiguration/LCP/TPPLCPClient.swift.
/// See PalaceTests/RegressionGuards/README.md for the full crash narrative.
@MainActor
final class LCPBotanCRLGuardTests: XCTestCase {

    // MARK: - decrypt(data:using:) — empty data short-circuit

    func testDecrypt_WithEmptyData_ReturnsNilWithoutCallingR2LCPClient() {
        // The fix prevents empty Data from reaching R2LCPClient.decrypt,
        // where Botan would attempt to decode 0 bytes and may throw.
        let client = TPPLCPClient()
        let invalidContext = NotADRMContext()
        let result = client.decrypt(data: Data(), using: invalidContext)
        XCTAssertNil(result, "empty data must short-circuit to nil before reaching R2LCPClient")
    }

    // MARK: - decrypt(data:using:) — non-DRMContext short-circuit

    func testDecrypt_WithNonDRMContext_ReturnsNilWithoutCallingR2LCPClient() {
        // The fix's type-check guard: contexts that aren't DRMContext are
        // bounced before R2LCPClient sees them, so Botan never decodes
        // garbage that could trigger the CRL exception path.
        let client = TPPLCPClient()
        let invalidContext = NotADRMContext()
        let nonEmpty = Data([0x01, 0x02, 0x03])
        let result = client.decrypt(data: nonEmpty, using: invalidContext)
        XCTAssertNil(result, "non-DRMContext must be rejected before R2LCPClient is called")
    }

    // MARK: - decrypt(data:) extension — same guards apply

    func testDecryptExtension_WithoutContext_ReturnsNil() {
        // The convenience-overload extension uses the same guards. Verify
        // that calling it without ever creating a context returns nil
        // safely (rather than dereferencing a nil context).
        let client = TPPLCPClient()
        let result = client.decrypt(data: Data([0x01, 0x02]))
        XCTAssertNil(result, "extension decrypt with no context must return nil, not crash")
    }

    func testDecryptExtension_WithEmptyData_ReturnsNil() {
        let client = TPPLCPClient()
        let result = client.decrypt(data: Data())
        XCTAssertNil(result)
    }

    // MARK: - createContext — error propagation

    func testCreateContext_WithGarbageJSONLicense_ThrowsRatherThanReturningNilSilently() {
        // The fix's contract: when R2LCPClient.createContext returns nil OR
        // throws, our wrapper turns both into a thrown error. Reverting this
        // — silent nil-return on failure — re-introduces the crash because
        // downstream code dereferences the assumed-non-nil context.
        let client = TPPLCPClient()
        do {
            _ = try client.createContext(
                jsonLicense: "{\"this is not\": \"a valid license\"}",
                hashedPassphrase: "deadbeef",
                pemCrl: "garbage"
            )
            XCTFail("createContext should throw or propagate underlying error for garbage input")
        } catch {
            // Either LCPContextError.creationReturnedNil or an underlying
            // R2LCPClient error — both are acceptable; the contract is "throw,
            // don't return silently".
        }
    }
}

/// A type that is intentionally NOT a DRMContext, used to trip the
/// type-check guard in decrypt(data:using:).
private final class NotADRMContext: LCPClientContext {}

#endif
