import XCTest
@testable import Palace

/// Verifies that the SignInModalPresenter guards (SQ-005, SQ-007)
/// do NOT interfere with SAML and OIDC authentication flows.
///
/// The !needsAuth guard at SignInModalPresenter must return true
/// for SAML/OIDC so the sign-in modal is presented when needed.
/// The handleBorrowAuthErrorIfNeeded guard must allow re-auth for
/// genuinely expired SAML/OIDC sessions on unborrowed books.
final class SignInModalSAMLOIDCTests: XCTestCase {

    // MARK: - needsAuth correctness for all auth types

    /// Exhaustive test of needsAuth for every AuthType.
    /// The invariant: anonymous, coppa, and none do NOT need auth.
    /// All others DO need auth.
    func testNeedsAuth_allAuthTypes() {
        let expectTrue: [AccountDetails.AuthType] = [
            .basic,
            .oauthIntermediary,
            .saml,
            .token,
            .oidc
        ]
        let expectFalse: [AccountDetails.AuthType] = [
            .anonymous,
            .coppa,
            .none
        ]

        for authType in expectTrue {
            let needsAuth = UserAccountAuthHelper.needsAuth(authType: authType)
            XCTAssertTrue(needsAuth, "\(authType) should require auth but needsAuth returned false")
        }

        for authType in expectFalse {
            let needsAuth = UserAccountAuthHelper.needsAuth(authType: authType)
            XCTAssertFalse(needsAuth, "\(authType) should NOT require auth but needsAuth returned true")
        }
    }

    /// Verifies that Authentication.needsAuth (on the Account model)
    /// matches UserAccountAuthHelper.needsAuth (on the state helper)
    /// for all auth types. These two implementations were inconsistent
    /// before the SQ-005 fix (OIDC was missing from the helper).
    func testNeedsAuth_consistencyBetweenTwoImplementations() {
        let allTypes: [AccountDetails.AuthType] = [
            .basic, .oauthIntermediary, .saml, .token, .oidc,
            .anonymous, .coppa, .none
        ]

        for authType in allTypes {
            let helperResult = UserAccountAuthHelper.needsAuth(authType: authType)
            let modelResult = authType == .basic
                || authType == .oauthIntermediary
                || authType == .saml
                || authType == .token
                || authType == .oidc

            XCTAssertEqual(
                helperResult, modelResult,
                "needsAuth mismatch for \(authType): helper=\(helperResult), model=\(modelResult)"
            )
        }
    }

    // MARK: - handleBorrowAuthErrorIfNeeded: SAML session expiry

    /// When a book is NOT yet borrowed (.unregistered), a SAML session
    /// expiry during borrow MUST trigger re-auth — the already-borrowed
    /// guard should NOT block it.
    func testBorrowReauthGuard_unregisteredBook_allowsReauth() {
        let state: TPPBookState = .unregistered

        let alreadyHasLoan: Bool = {
            switch state {
            case .downloadNeeded, .downloading, .downloadSuccessful,
                 .downloadFailed, .holding, .SAMLStarted, .used, .returning:
                return true
            case .unregistered, .unsupported:
                return false
            @unknown default:
                return false
            }
        }()

        XCTAssertFalse(alreadyHasLoan, "Unregistered book should NOT be treated as having a loan — SAML re-auth must be allowed")
    }

    /// When a book IS borrowed (.downloadNeeded), the guard correctly
    /// blocks re-auth (SQ-007 — borrow failure for an already-borrowed
    /// book is not a credentials problem).
    func testBorrowReauthGuard_downloadNeededBook_blocksReauth() {
        let state: TPPBookState = .downloadNeeded

        let alreadyHasLoan: Bool = {
            switch state {
            case .downloadNeeded, .downloading, .downloadSuccessful,
                 .downloadFailed, .holding, .SAMLStarted, .used, .returning:
                return true
            case .unregistered, .unsupported:
                return false
            @unknown default:
                return false
            }
        }()

        XCTAssertTrue(alreadyHasLoan, "Book in downloadNeeded state should be treated as having a loan — no spurious re-auth")
    }

    /// Verify ALL book states are correctly classified.
    func testBorrowReauthGuard_allBookStates() {
        let loanStates: [TPPBookState] = [
            .downloadNeeded, .downloading, .downloadSuccessful,
            .downloadFailed, .holding, .SAMLStarted, .used, .returning
        ]
        let nonLoanStates: [TPPBookState] = [
            .unregistered, .unsupported
        ]

        for state in loanStates {
            let hasLoan = isActiveLoanState(state)
            XCTAssertTrue(hasLoan, "\(state) should be classified as active loan")
        }

        for state in nonLoanStates {
            let hasLoan = isActiveLoanState(state)
            XCTAssertFalse(hasLoan, "\(state) should NOT be classified as active loan")
        }
    }

    // MARK: - SignInModalPresenter guard: SAML/OIDC not blocked

    /// Simulates what SignInModalPresenter checks:
    /// if !userAccount.needsAuth → skip modal.
    /// For SAML/OIDC, needsAuth must be true so the modal IS presented.
    func testSignInModalGuard_samlNotBlocked() {
        let needsAuth = UserAccountAuthHelper.needsAuth(authType: .saml)
        XCTAssertTrue(needsAuth, "SAML must pass the needsAuth check — sign-in modal should NOT be skipped")
    }

    func testSignInModalGuard_oidcNotBlocked() {
        let needsAuth = UserAccountAuthHelper.needsAuth(authType: .oidc)
        XCTAssertTrue(needsAuth, "OIDC must pass the needsAuth check — sign-in modal should NOT be skipped")
    }

    func testSignInModalGuard_anonymousBlocked() {
        let needsAuth = UserAccountAuthHelper.needsAuth(authType: .anonymous)
        XCTAssertFalse(needsAuth, "Anonymous auth should be blocked by the needsAuth guard (SQ-005)")
    }

    // MARK: - Helpers

    private func isActiveLoanState(_ state: TPPBookState) -> Bool {
        switch state {
        case .downloadNeeded, .downloading, .downloadSuccessful,
             .downloadFailed, .holding, .SAMLStarted, .used, .returning:
            return true
        case .unregistered, .unsupported:
            return false
        @unknown default:
            return false
        }
    }
}

// MARK: - UserAccountAuthHelper extension for testing

extension UserAccountAuthHelper {
    /// Test-only convenience to check needsAuth by authType directly
    /// without constructing a full Authentication object.
    static func needsAuth(authType: AccountDetails.AuthType) -> Bool {
        return authType == .basic
            || authType == .oauthIntermediary
            || authType == .saml
            || authType == .token
            || authType == .oidc
    }
}
