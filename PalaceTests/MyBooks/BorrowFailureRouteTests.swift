//
//  BorrowFailureRouteTests.swift
//  PalaceTests
//
//  The pure borrow failure route in `BorrowReducerCore`: which failures count
//  as auth errors, and the ordered effect plan for every (account kind,
//  failure kind) cell. `BorrowOperationFailureContractTests` pins the same
//  cells end to end through the runner.
//

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceAuth
import PalaceBookModel

final class BorrowFailureRouteTests: XCTestCase {

    private typealias Core = BorrowReducerCore
    private typealias Effect = BorrowReducerCore.FailureEffect

    // MARK: - authErrorReason

    func testAuthErrorReason_AuthenticationCase_WinsOverANonAuthProblemDocument() {
        XCTAssertEqual(reason(.authentication, doc: Self.loanLimitDoc), .authenticationError)
        XCTAssertEqual(reason(.authentication), .authenticationError)
    }

    func testAuthErrorReason_EachCredentialsProblemType_IsAnAuthError() {
        let types = [
            TPPProblemDocument.TypeInvalidCredentials,
            "http://librarysimplified.org/terms/problem/invalid-credentials",
            "http://palaceproject.io/terms/problem/auth/unrecoverable/credentials/invalid",
        ]
        for type in types {
            XCTAssertEqual(reason(.other, doc: .init(type: type, isRecoverableAuthError: false)),
                           .credentialsProblemType, type)
        }
    }

    func testAuthErrorReason_CredentialsTypeThatIsAlsoRecoverable_ReportsCredentialsType() {
        let doc = Core.FailureProblemDocument(type: TPPProblemDocument.TypeInvalidCredentials, isRecoverableAuthError: true)
        XCTAssertEqual(reason(.other, doc: doc), .credentialsProblemType)
    }

    func testAuthErrorReason_RecoverableProblemDocument_IsAnAuthError() {
        let doc = Core.FailureProblemDocument(type: "http://example.com/recoverable", isRecoverableAuthError: true)
        XCTAssertEqual(reason(.other, doc: doc), .recoverableProblemDocument)
    }

    func testAuthErrorReason_NoActiveLoan_IsAnAuthErrorOnlyForBrowserSignInWithCredentials() {
        XCTAssertEqual(reason(.other, doc: Self.noActiveLoanDoc, browser: true, credentials: true), .browserNoActiveLoan)
        XCTAssertNil(reason(.other, doc: Self.noActiveLoanDoc, browser: false, credentials: true))
        XCTAssertNil(reason(.other, doc: Self.noActiveLoanDoc, browser: true, credentials: false))
    }

    /// PP-5359: a loan limit arrives as a 403 with a document; signing in cannot fix it.
    func testAuthErrorReason_NonAuthProblemDocumentOn403_IsNotAnAuthError() {
        XCTAssertNil(reason(.networkForbidden, doc: Self.loanLimitDoc))
        XCTAssertNil(reason(.networkUnauthorized, doc: Self.loanLimitDoc))
        XCTAssertNil(reason(.other, doc: Self.loanLimitDoc, code: TPPErrorCode.invalidCredentials.rawValue))
    }

    func testAuthErrorReason_DocumentWithNoType_IsNotAnAuthError() {
        XCTAssertNil(reason(.networkUnauthorized, doc: .init(type: nil, isRecoverableAuthError: false)))
    }

    func testAuthErrorReason_Bare401And403WithoutDocument_AreAuthErrors() {
        XCTAssertEqual(reason(.networkUnauthorized), .networkUnauthorized)
        XCTAssertEqual(reason(.networkForbidden), .networkForbidden)
    }

    func testAuthErrorReason_InvalidCredentialsCodeWithoutDocument_IsAnAuthError() {
        XCTAssertEqual(reason(.other, code: TPPErrorCode.invalidCredentials.rawValue), .invalidCredentialsCode)
    }

    func testAuthErrorReason_TimeoutOrServerErrorWithoutDocument_IsNotAnAuthError() {
        XCTAssertNil(reason(.other, code: 0))
        XCTAssertNil(reason(.other, code: 500))
    }

    // MARK: - Error case and auth kind mapping (runner helpers)

    func testFailureErrorCase_MapsOnlyTheAuthRelevantCases() {
        XCTAssertEqual(BorrowOperation.failureErrorCase(.authentication(.invalidCredentials)), .authentication)
        XCTAssertEqual(BorrowOperation.failureErrorCase(.network(.unauthorized)), .networkUnauthorized)
        XCTAssertEqual(BorrowOperation.failureErrorCase(.network(.forbidden)), .networkForbidden)
        XCTAssertEqual(BorrowOperation.failureErrorCase(.network(.timeout)), .other)
        XCTAssertEqual(BorrowOperation.failureErrorCase(.bookRegistry(.holdCopyUnavailable)), .other)
    }

    func testFailureAuthKind_MapsEachAuthenticationType() throws {
        XCTAssertEqual(BorrowOperation.failureAuthKind(nil), .noAuthentication)
        let cases: [(String, Core.FailureAuthKind)] = [
            ("http://opds-spec.org/auth/basic", .basic),
            ("http://thepalaceproject.org/authtype/basic-token", .token),
            ("http://librarysimplified.org/authtype/SAML-2.0", .saml),
            ("http://palaceproject.io/authtype/OpenIDConnect", .oidc),
            ("http://librarysimplified.org/authtype/OAuth-with-intermediary", .oauthIntermediary),
            ("http://librarysimplified.org/rel/auth/anonymous", .noAuthentication),
            ("http://librarysimplified.org/terms/authentication/gate/coppa", .noAuthentication),
        ]
        for (type, expected) in cases {
            XCTAssertEqual(BorrowOperation.failureAuthKind(try Self.authentication(type: type)), expected, type)
        }
    }

    func testFailureAuthKind_OnlySAMLOIDCAndOAuthAreBrowserBased() {
        XCTAssertTrue(Core.FailureAuthKind.saml.isBrowserBased)
        XCTAssertTrue(Core.FailureAuthKind.oidc.isBrowserBased)
        XCTAssertTrue(Core.FailureAuthKind.oauthIntermediary.isBrowserBased)
        XCTAssertFalse(Core.FailureAuthKind.basic.isBrowserBased)
        XCTAssertFalse(Core.FailureAuthKind.token.isBrowserBased)
        XCTAssertFalse(Core.FailureAuthKind.noAuthentication.isBrowserBased)
    }

    // MARK: - failureEffects: account kind x failure kind
    //
    // Rows are (auth kind, credentials, coordinator); columns are an auth error,
    // a loan-already-exists document, and any other non-auth failure. The book
    // is not on loan and the breaker is not armed.

    private struct Row {
        let name: String
        let kind: Core.FailureAuthKind
        let credentials: Bool
        let coordinator: Bool
        let onAuthError: [Effect]
    }

    private static let show = Effect.showBorrowError(includesOriginalError: true)

    private static let basicNoCredentials = Row(name: "basic, no credentials", kind: .basic, credentials: false, coordinator: false,
            onAuthError: [.markReauthAttempted, .presentSignInModal(authLabel: "Sign-in", requiresSignedIn: false)])
    private static let basicWithCredentials = Row(name: "basic, credentials", kind: .basic, credentials: true, coordinator: false,
            onAuthError: [.markReauthAttempted, .markCredentialsStale,
                          .presentSignInModal(authLabel: "Basic", requiresSignedIn: true)])
    private static let tokenWithCredentials = Row(name: "token, credentials", kind: .token, credentials: true, coordinator: false,
            onAuthError: [.markReauthAttempted, .markCredentialsStale, .noAutomaticRecovery, show])

    private static let rows: [Row] = [
        Row(name: "no auth, no credentials", kind: .noAuthentication, credentials: false, coordinator: false,
            onAuthError: [.markReauthAttempted, .noAutomaticRecovery, show]),
        Row(name: "no auth, credentials", kind: .noAuthentication, credentials: true, coordinator: false,
            onAuthError: [.markReauthAttempted, .markCredentialsStale, .noAutomaticRecovery, show]),
        basicNoCredentials,
        Row(name: "basic, no credentials, coordinator", kind: .basic, credentials: false, coordinator: true,
            onAuthError: [.markReauthAttempted, .presentSignInModal(authLabel: "Sign-in", requiresSignedIn: false)]),
        basicWithCredentials,
        Row(name: "basic, credentials, coordinator", kind: .basic, credentials: true, coordinator: true,
            onAuthError: [.markReauthAttempted, .markCredentialsStale,
                          .presentSignInModal(authLabel: "Basic", requiresSignedIn: true)]),
        Row(name: "token, no credentials", kind: .token, credentials: false, coordinator: false,
            onAuthError: [.markReauthAttempted, .presentSignInModal(authLabel: "Sign-in", requiresSignedIn: false)]),
        tokenWithCredentials,
        Row(name: "SAML, no credentials", kind: .saml, credentials: false, coordinator: true,
            onAuthError: [.markReauthAttempted, .presentSignInModal(authLabel: "Sign-in", requiresSignedIn: false)]),
        Row(name: "SAML, credentials, coordinator", kind: .saml, credentials: true, coordinator: true,
            onAuthError: [.markReauthAttempted, .markCredentialsStale,
                          .coordinatorRefresh(reason: .samlSessionExpired, authLabel: "SAML")]),
        Row(name: "SAML, credentials, no coordinator", kind: .saml, credentials: true, coordinator: false,
            onAuthError: [.markReauthAttempted, .markCredentialsStale,
                          .presentSignInModal(authLabel: "SAML", requiresSignedIn: false)]),
        Row(name: "OAuth, no credentials", kind: .oauthIntermediary, credentials: false, coordinator: false,
            onAuthError: [.markReauthAttempted, .presentSignInModal(authLabel: "Sign-in", requiresSignedIn: false)]),
        Row(name: "OAuth, credentials, coordinator", kind: .oauthIntermediary, credentials: true, coordinator: true,
            onAuthError: [.markReauthAttempted, .markCredentialsStale,
                          .coordinatorRefresh(reason: .invalidCredentials, authLabel: "OAuth-intermediary")]),
        Row(name: "OAuth, credentials, no coordinator", kind: .oauthIntermediary, credentials: true, coordinator: false,
            onAuthError: [.markReauthAttempted, .markCredentialsStale,
                          .presentSignInModal(authLabel: "SAML", requiresSignedIn: false)]),
        Row(name: "OIDC, no credentials", kind: .oidc, credentials: false, coordinator: true,
            onAuthError: [.markReauthAttempted, .presentSignInModal(authLabel: "Sign-in", requiresSignedIn: false)]),
        Row(name: "OIDC, credentials, coordinator", kind: .oidc, credentials: true, coordinator: true,
            onAuthError: [.markReauthAttempted, .markCredentialsStale,
                          .oidcSilentReauth(fallback: .coordinatorRefresh(reason: .oidcRefreshFailed, authLabel: "OIDC"))]),
        Row(name: "OIDC, credentials, no coordinator", kind: .oidc, credentials: true, coordinator: false,
            onAuthError: [.markReauthAttempted, .markCredentialsStale,
                          .oidcSilentReauth(fallback: .presentSignInModal(authLabel: "OIDC", requiresSignedIn: false))]),
    ]

    func testFailureEffects_AuthError_RoutesEachAccountKindToItsRecovery() {
        for row in Self.rows {
            XCTAssertEqual(plan(row, authError: .networkUnauthorized), row.onAuthError, row.name)
        }
    }

    func testFailureEffects_LoanAlreadyExistsNotOnLoan_ShowsTheErrorForEveryAccountKind() {
        for row in Self.rows {
            XCTAssertEqual(plan(row, authError: nil, docType: TPPProblemDocument.TypeLoanAlreadyExists),
                           [Self.show], row.name)
        }
    }

    func testFailureEffects_NonAuthFailure_ShowsTheErrorForEveryAccountKind() {
        for row in Self.rows {
            XCTAssertEqual(plan(row, authError: nil, docType: TPPProblemDocument.TypePatronLoanLimit), [Self.show], row.name)
            XCTAssertEqual(plan(row, authError: nil), [Self.show], row.name)
        }
    }

    /// Every auth-error reason takes the same route; only "is it one" matters.
    func testFailureEffects_EveryAuthErrorReason_TakesTheSameRoute() {
        let reasons: [Core.AuthErrorReason] = [.authenticationError, .credentialsProblemType, .recoverableProblemDocument,
                                               .browserNoActiveLoan, .networkUnauthorized, .networkForbidden,
                                               .invalidCredentialsCode]
        let basic = Self.basicWithCredentials
        for reason in reasons {
            XCTAssertEqual(plan(basic, authError: reason), basic.onAuthError, "\(reason)")
        }
    }

    // MARK: - failureEffects: SQ-007 already on loan

    func testFailureEffects_AuthErrorOnLoanWithCredentials_SuppressesForEveryAccountKind() {
        for row in Self.rows where row.credentials {
            XCTAssertEqual(plan(row, authError: .networkUnauthorized, state: .downloadNeeded),
                           [.suppressAndReclearProcessing], row.name)
        }
    }

    func testFailureEffects_LoanAlreadyExistsOnLoanWithCredentials_Suppresses() {
        XCTAssertEqual(plan(Self.basicWithCredentials, authError: nil, docType: TPPProblemDocument.TypeLoanAlreadyExists,
                            state: .downloadSuccessful),
                       [.suppressAndReclearProcessing])
    }

    func testFailureEffects_OtherFailureOnLoan_ShowsTheError() {
        XCTAssertEqual(plan(Self.basicWithCredentials, authError: nil, docType: TPPProblemDocument.TypePatronLoanLimit,
                            state: .downloadNeeded),
                       [Self.show])
    }

    func testFailureEffects_AuthErrorOnLoanWithoutCredentials_RoutesToSignIn() {
        let basicNoCredentials = Self.basicNoCredentials
        XCTAssertEqual(plan(basicNoCredentials, authError: .networkUnauthorized, state: .downloadNeeded),
                       basicNoCredentials.onAuthError)
        XCTAssertEqual(plan(basicNoCredentials, authError: nil, docType: TPPProblemDocument.TypeLoanAlreadyExists,
                            state: .downloadNeeded),
                       [Self.show])
    }

    func testFailureEffects_AuthErrorForUnregisteredBook_IsNotSuppressed() {
        let basic = Self.basicWithCredentials
        XCTAssertEqual(plan(basic, authError: .networkUnauthorized, state: .unregistered), basic.onAuthError)
        XCTAssertEqual(plan(basic, authError: .networkUnauthorized, state: .unsupported), basic.onAuthError)
    }

    // MARK: - failureEffects: reauth breaker armed

    func testFailureEffects_BreakerArmedOnAuthError_ShowsTheErrorInsteadOfReauth() {
        for row in Self.rows {
            XCTAssertEqual(plan(row, authError: .networkUnauthorized, breakerArmed: true),
                           [.reauthBreakerTripped, Self.show], row.name)
        }
    }

    func testFailureEffects_BreakerArmedOnNonAuthFailure_ShowsOnlyTheError() {
        XCTAssertEqual(plan(Self.basicWithCredentials, authError: nil, breakerArmed: true), [Self.show])
    }

    func testFailureEffects_BreakerArmedButOnLoan_StillSuppresses() {
        XCTAssertEqual(plan(Self.basicWithCredentials, authError: .networkUnauthorized, state: .downloadNeeded, breakerArmed: true),
                       [.suppressAndReclearProcessing])
    }

    // MARK: - failureEffects: original error passthrough

    func testFailureEffects_PalaceErrorThrow_ShowsTheErrorWithoutTheOriginal() {
        let hidden = Effect.showBorrowError(includesOriginalError: false)
        XCTAssertEqual(plan(Self.basicWithCredentials, authError: nil, includesOriginalError: false), [hidden])
        XCTAssertEqual(plan(Self.basicWithCredentials, authError: .networkUnauthorized, breakerArmed: true, includesOriginalError: false),
                       [.reauthBreakerTripped, hidden])
        XCTAssertEqual(plan(Self.tokenWithCredentials, authError: .networkUnauthorized, includesOriginalError: false),
                       [.markReauthAttempted, .markCredentialsStale, .noAutomaticRecovery, hidden])
    }

    // MARK: - Helpers

    private func reason(
        _ errorCase: Core.FailureErrorCase,
        doc: Core.FailureProblemDocument? = nil,
        browser: Bool = false,
        credentials: Bool = true,
        code: Int = 0
    ) -> Core.AuthErrorReason? {
        Core.authErrorReason(errorCase: errorCase, problemDocument: doc, isBrowserBased: browser,
                             hasCredentials: credentials, nsErrorCode: code)
    }

    private func plan(
        _ row: Row,
        authError: Core.AuthErrorReason?,
        docType: String? = nil,
        state: TPPBookState = .unregistered,
        breakerArmed: Bool = false,
        includesOriginalError: Bool = true
    ) -> [Effect] {
        Core.failureEffects(
            authError: authError,
            problemDocumentType: docType,
            registeredState: state,
            hasCredentials: row.credentials,
            reauthAlreadyAttempted: breakerArmed,
            authKind: row.kind,
            hasAuthCoordinator: row.coordinator,
            includesOriginalError: includesOriginalError
        )
    }

    private static let loanLimitDoc = Core.FailureProblemDocument(type: TPPProblemDocument.TypePatronLoanLimit,
                                                                 isRecoverableAuthError: false)
    private static let noActiveLoanDoc = Core.FailureProblemDocument(type: TPPProblemDocument.TypeNoActiveLoan,
                                                                    isRecoverableAuthError: false)

    private static func authentication(type: String) throws -> AccountDetails.Authentication {
        let json = """
        {"type": "\(type)", "description": "auth",
         "links": [{"rel": "authenticate", "href": "https://idp.example.com/auth"}]}
        """
        let docAuth = try JSONDecoder().decode(OPDS2AuthenticationDocument.Authentication.self, from: Data(json.utf8))
        return AccountDetails.Authentication(auth: docAuth)
    }
}
