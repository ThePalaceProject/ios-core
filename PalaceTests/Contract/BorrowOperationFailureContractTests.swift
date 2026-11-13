//  BorrowOperationFailureContractTests.swift
//
//  Characterization snapshots of BorrowOperation's failure tail: one per
//  (account kind x failure kind) cell, pinning spinner, registry, stale-mark,
//  breaker, reauth route and alert/publish calls before that logic moves (PP-5557).
//  Snapshots record today's behavior, including cells that may be defects.
//  `AuthCoordinator` takes no reason spy (it is an actor), so the reason passed to
//  `refreshCredentialsIfNeeded` is not observable here; its decision events are.

import XCTest
import PalaceCatalog
@testable import Palace
@testable import PalaceAuth
import PalaceBookModel
import PalaceDownloads

@MainActor
final class BorrowOperationFailureContractTests: XCTestCase {

    private enum AccountKind { case noAuthDefinition, basicNoCredentials, basicWithCredentials, saml, oidc }

    private static let bookId = "BORROW-FAIL"

    private var log: CallLog!
    private var registry: RecordingBookRegistry!
    private var account: RecordingUserAccount!
    private var operation: BorrowOperation!
    private var book: TPPBook!
    private var pendingModalCompletions: [() -> Void] = []
    private let fetchScript = FetchScript()
    private let oidcResult = LockedFlag()

    override func setUpWithError() throws {
        try super.setUpWithError()
        BorrowOperation.clearAllBorrowReauthState()
        log = CallLog()
        registry = RecordingBookRegistry()
        account = RecordingUserAccount()
        book = TPPBookMocker.mockBook(identifier: Self.bookId, title: "Title-\(Self.bookId)", distributorType: .EpubZip)
        pendingModalCompletions = []
        fetchScript.reset()
        oidcResult.value = false
    }

    override func tearDownWithError() throws {
        BorrowOperation.clearAllBorrowReauthState()
        operation = nil
        registry = nil
        account = nil
        book = nil
        log = nil
        pendingModalCompletions = []
        try super.tearDownWithError()
    }

    // MARK: - R1: no authentication definition

    func testBorrowFailure_NoAuthDefinition_OnCredentialsProblemDoc_ShowsAlertAndLeavesBreakerArmed() async {
        await assertBorrowFailure(.noAuthDefinition, failing: Self.credentialsDocError, named: "R1_E1")
    }

    func testBorrowFailure_NoAuthDefinition_On401_ShowsAlertAndLeavesBreakerArmed() async {
        await assertBorrowFailure(.noAuthDefinition, failing: PalaceError.network(.unauthorized), named: "R1_E2")
    }

    func testBorrowFailure_NoAuthDefinition_OnLoanLimit_ShowsAlert() async {
        await assertBorrowFailure(.noAuthDefinition, failing: Self.loanLimitError, named: "R1_E3")
    }

    func testBorrowFailure_NoAuthDefinition_OnLoanAlreadyExists_ShowsAlert() async {
        await assertBorrowFailure(.noAuthDefinition, failing: Self.loanAlreadyExistsError, named: "R1_E4")
    }

    func testBorrowFailure_NoAuthDefinition_OnTimeout_ShowsRetryableAlert() async {
        await assertBorrowFailure(.noAuthDefinition, failing: PalaceError.network(.timeout), named: "R1_E5")
    }

    func testBorrowFailure_NoAuthDefinition_OnNoActiveLoan_ShowsAlert() async {
        await assertBorrowFailure(.noAuthDefinition, failing: Self.noActiveLoanError, named: "R1_E6")
    }

    func testBorrowFailure_NoAuthDefinition_OnCancellation_ShowsAlert() async {
        await assertCancelledBorrow(.noAuthDefinition, named: "R1_E7")
    }

    // MARK: - R2: needs auth, no credentials
    // E7 skipped: cancellation is not an auth error and R2 is not on loan, so it
    // takes the same generic-alert path R1_E7 pins.

    func testBorrowFailure_NeedsAuthNoCredentials_OnCredentialsProblemDoc_PresentsSignInModal_DismissDoesNotRetry() async {
        await assertBorrowFailure(.basicNoCredentials, failing: Self.credentialsDocError, dismissModal: true, named: "R2_E1")
    }

    func testBorrowFailure_NeedsAuthNoCredentials_On401_PresentsSignInModal_DismissDoesNotRetry() async {
        await assertBorrowFailure(.basicNoCredentials, failing: PalaceError.network(.unauthorized), dismissModal: true, named: "R2_E2")
    }

    func testBorrowFailure_NeedsAuthNoCredentials_OnLoanLimit_ShowsAlert() async {
        await assertBorrowFailure(.basicNoCredentials, failing: Self.loanLimitError, named: "R2_E3")
    }

    func testBorrowFailure_NeedsAuthNoCredentials_OnLoanAlreadyExists_ShowsAlert() async {
        await assertBorrowFailure(.basicNoCredentials, failing: Self.loanAlreadyExistsError, named: "R2_E4")
    }

    func testBorrowFailure_NeedsAuthNoCredentials_OnTimeout_ShowsRetryableAlert() async {
        await assertBorrowFailure(.basicNoCredentials, failing: PalaceError.network(.timeout), named: "R2_E5")
    }

    func testBorrowFailure_NeedsAuthNoCredentials_OnNoActiveLoan_ShowsAlert() async {
        await assertBorrowFailure(.basicNoCredentials, failing: Self.noActiveLoanError, named: "R2_E6")
    }

    // MARK: - R3: Basic with credentials

    func testBorrowFailure_BasicWithCredentials_OnCredentialsProblemDoc_MarksStaleAndPresentsSignInModalOnce() async {
        await assertBorrowFailure(.basicWithCredentials, failing: Self.credentialsDocError, dismissModal: true, named: "R3_E1")
    }

    func testBorrowFailure_BasicWithCredentials_On401_PresentsSignInModalOnce_DismissDoesNotRetry() async {
        await assertBorrowFailure(.basicWithCredentials, failing: PalaceError.network(.unauthorized), dismissModal: true, named: "R3_E2")
    }

    func testBorrowFailure_BasicWithCredentials_On403_PresentsSignInModalOnce_DismissDoesNotRetry() async {
        await assertBorrowFailure(.basicWithCredentials, failing: PalaceError.network(.forbidden), dismissModal: true, named: "R3_E2_403")
    }

    func testBorrowFailure_BasicWithCredentials_OnLoanLimit_ShowsAlertWithoutStaleMark() async {
        await assertBorrowFailure(.basicWithCredentials, failing: Self.loanLimitError, named: "R3_E3")
    }

    func testBorrowFailure_BasicWithCredentials_OnLoanAlreadyExists_ShowsAlert() async {
        await assertBorrowFailure(.basicWithCredentials, failing: Self.loanAlreadyExistsError, named: "R3_E4")
    }

    func testBorrowFailure_BasicWithCredentials_OnTimeout_ShowsRetryableAlert() async {
        await assertBorrowFailure(.basicWithCredentials, failing: PalaceError.network(.timeout), named: "R3_E5")
    }

    func testBorrowFailure_BasicWithCredentials_OnNoActiveLoan_ShowsAlert() async {
        await assertBorrowFailure(.basicWithCredentials, failing: Self.noActiveLoanError, named: "R3_E6")
    }

    func testBorrowFailure_BasicWithCredentials_OnCancellation_ShowsAlert() async {
        await assertCancelledBorrow(.basicWithCredentials, named: "R3_E7")
    }

    // MARK: - R4: SAML with an auth coordinator

    func testBorrowFailure_SAMLWithCoordinator_OnCredentialsProblemDoc_PatronCancels_ShowsNoAlertAndKeepsBreakerArmed() async {
        await assertBorrowFailure(.saml, failing: Self.credentialsDocError, coordinator: (.saml, false), named: "R4_E1_cancelled")
    }

    func testBorrowFailure_SAMLWithCoordinator_OnCredentialsProblemDoc_SignInThenRetryFails_ShowsOneAlert() async {
        await assertBorrowFailure(.saml, failing: Self.credentialsDocError, coordinator: (.saml, true), named: "R4_E1_signedIn")
    }

    func testBorrowFailure_SAMLWithCoordinator_On401_RoutesThroughCoordinator() async {
        await assertBorrowFailure(.saml, failing: PalaceError.network(.unauthorized), coordinator: (.saml, false), named: "R4_E2")
    }

    func testBorrowFailure_SAMLWithCoordinator_OnLoanLimit_ShowsAlertWithoutCoordinator() async {
        await assertBorrowFailure(.saml, failing: Self.loanLimitError, coordinator: (.saml, false), named: "R4_E3")
    }

    func testBorrowFailure_SAMLWithCoordinator_OnLoanAlreadyExists_ShowsAlert() async {
        await assertBorrowFailure(.saml, failing: Self.loanAlreadyExistsError, coordinator: (.saml, false), named: "R4_E4")
    }

    func testBorrowFailure_SAMLWithCoordinator_OnTimeout_ShowsRetryableAlert() async {
        await assertBorrowFailure(.saml, failing: PalaceError.network(.timeout), coordinator: (.saml, false), named: "R4_E5")
    }

    func testBorrowFailure_SAMLWithCoordinator_OnNoActiveLoan_RoutesThroughCoordinator() async {
        await assertBorrowFailure(.saml, failing: Self.noActiveLoanError, coordinator: (.saml, false), named: "R4_E6")
    }

    func testBorrowFailure_SAMLWithCoordinator_OnCancellation_ShowsAlert() async {
        await assertCancelledBorrow(.saml, coordinator: (.saml, false), named: "R4_E7")
    }

    // MARK: - R5: SAML without a coordinator
    // E7 skipped: cancellation never reaches the reauth route, so it matches R4_E7.

    func testBorrowFailure_SAMLNoCoordinator_OnCredentialsProblemDoc_PresentsSignInModal_DismissRetriesAndShowsAlert() async {
        await assertBorrowFailure(.saml, failing: Self.credentialsDocError, dismissModal: true, named: "R5_E1")
    }

    func testBorrowFailure_SAMLNoCoordinator_On401_PresentsSignInModal_DismissRetriesAndShowsAlert() async {
        await assertBorrowFailure(.saml, failing: PalaceError.network(.unauthorized), dismissModal: true, named: "R5_E2")
    }

    func testBorrowFailure_SAMLNoCoordinator_OnLoanLimit_ShowsAlert() async {
        await assertBorrowFailure(.saml, failing: Self.loanLimitError, named: "R5_E3")
    }

    func testBorrowFailure_SAMLNoCoordinator_OnLoanAlreadyExists_ShowsAlert() async {
        await assertBorrowFailure(.saml, failing: Self.loanAlreadyExistsError, named: "R5_E4")
    }

    func testBorrowFailure_SAMLNoCoordinator_OnTimeout_ShowsRetryableAlert() async {
        await assertBorrowFailure(.saml, failing: PalaceError.network(.timeout), named: "R5_E5")
    }

    func testBorrowFailure_SAMLNoCoordinator_OnNoActiveLoan_PresentsSignInModal_DismissRetriesAndShowsAlert() async {
        await assertBorrowFailure(.saml, failing: Self.noActiveLoanError, dismissModal: true, named: "R5_E6")
    }

    // MARK: - R6: OIDC, silent reauth succeeds or fails
    // E3-E5 run once each: they are not auth errors, so the silent result is never read.
    // E7 skipped: as R5, cancellation never reaches the reauth route.

    func testBorrowFailure_OIDC_OnCredentialsProblemDoc_SilentOkRetryFails_ShowsOneAlert() async {
        await assertBorrowFailure(.oidc, failing: Self.credentialsDocError, oidcSucceeds: true, named: "R6_E1_silentOk")
    }

    func testBorrowFailure_OIDC_OnCredentialsProblemDoc_SilentOkRetrySucceeds_ReturnsBook() async {
        fetchScript.succeedFromAttempt = 2
        await assertBorrowFailure(.oidc, failing: Self.credentialsDocError, oidcSucceeds: true, named: "R6_E1_silentOk_retryBorrows")
    }

    func testBorrowFailure_OIDC_OnCredentialsProblemDoc_SilentFails_PresentsSignInModal_DismissRetriesAndShowsAlert() async {
        await assertBorrowFailure(.oidc, failing: Self.credentialsDocError, dismissModal: true, named: "R6_E1_silentFails")
    }

    func testBorrowFailure_OIDCWithCoordinator_OnCredentialsProblemDoc_SilentFails_RoutesThroughCoordinator() async {
        await assertBorrowFailure(.oidc, failing: Self.credentialsDocError, coordinator: (.oidc, false), named: "R6_E1_silentFails_coordinator")
    }

    func testBorrowFailure_OIDC_On401_SilentOkRetryFails_ShowsOneAlert() async {
        await assertBorrowFailure(.oidc, failing: PalaceError.network(.unauthorized), oidcSucceeds: true, named: "R6_E2_silentOk")
    }

    func testBorrowFailure_OIDC_On401_SilentFails_PresentsSignInModal_DismissRetriesAndShowsAlert() async {
        await assertBorrowFailure(.oidc, failing: PalaceError.network(.unauthorized), dismissModal: true, named: "R6_E2_silentFails")
    }

    func testBorrowFailure_OIDC_OnLoanLimit_ShowsAlertWithoutSilentReauth() async {
        await assertBorrowFailure(.oidc, failing: Self.loanLimitError, oidcSucceeds: true, named: "R6_E3")
    }

    func testBorrowFailure_OIDC_OnLoanAlreadyExists_ShowsAlert() async {
        await assertBorrowFailure(.oidc, failing: Self.loanAlreadyExistsError, oidcSucceeds: true, named: "R6_E4")
    }

    func testBorrowFailure_OIDC_OnTimeout_ShowsRetryableAlert() async {
        await assertBorrowFailure(.oidc, failing: PalaceError.network(.timeout), oidcSucceeds: true, named: "R6_E5")
    }

    func testBorrowFailure_OIDC_OnNoActiveLoan_SilentOkRetryFails_ShowsOneAlert() async {
        await assertBorrowFailure(.oidc, failing: Self.noActiveLoanError, oidcSucceeds: true, named: "R6_E6_silentOk")
    }

    func testBorrowFailure_OIDC_OnNoActiveLoan_SilentFails_PresentsSignInModal_DismissRetriesAndShowsAlert() async {
        await assertBorrowFailure(.oidc, failing: Self.noActiveLoanError, dismissModal: true, named: "R6_E6_silentFails")
    }

    // MARK: - R7: already on loan, Basic with credentials

    func testBorrowFailure_AlreadyOnLoan_OnCredentialsProblemDoc_SuppressesAlertAndReauth() async {
        await assertBorrowFailure(.basicWithCredentials, failing: Self.credentialsDocError, alreadyOnLoan: true, named: "R7_E1")
    }

    func testBorrowFailure_AlreadyOnLoan_On401_SuppressesAlertAndReauth() async {
        await assertBorrowFailure(.basicWithCredentials, failing: PalaceError.network(.unauthorized), alreadyOnLoan: true, named: "R7_E2")
    }

    func testBorrowFailure_AlreadyOnLoan_OnLoanLimit_ShowsAlert() async {
        await assertBorrowFailure(.basicWithCredentials, failing: Self.loanLimitError, alreadyOnLoan: true, named: "R7_E3")
    }

    func testBorrowFailure_AlreadyOnLoan_OnLoanAlreadyExists_SuppressesAlertAndReauth() async {
        await assertBorrowFailure(.basicWithCredentials, failing: Self.loanAlreadyExistsError, alreadyOnLoan: true, named: "R7_E4")
    }

    func testBorrowFailure_AlreadyOnLoan_OnTimeout_ShowsRetryableAlert() async {
        await assertBorrowFailure(.basicWithCredentials, failing: PalaceError.network(.timeout), alreadyOnLoan: true, named: "R7_E5")
    }

    func testBorrowFailure_AlreadyOnLoan_OnNoActiveLoan_ShowsAlert() async {
        await assertBorrowFailure(.basicWithCredentials, failing: Self.noActiveLoanError, alreadyOnLoan: true, named: "R7_E6")
    }

    func testBorrowFailure_AlreadyOnLoan_OnCancellation_ShowsAlert() async {
        await assertCancelledBorrow(.basicWithCredentials, alreadyOnLoan: true, named: "R7_E7")
    }

    // MARK: - R8: reauth breaker already tripped (Basic with credentials)
    // The first borrow arms the breaker and leaves its sign-in sheet open.
    // E4-E7 skipped: the breaker is read only after the auth-error check, so
    // those columns match R3.

    func testBorrowFailure_BreakerTripped_OnCredentialsProblemDoc_ShowsAlertInsteadOfSignIn() async {
        await assertRepeatedBorrowFailure(failing: Self.credentialsDocError, named: "R8_E1")
    }

    func testBorrowFailure_BreakerTripped_On401_ShowsAlertInsteadOfSignIn() async {
        await assertRepeatedBorrowFailure(failing: PalaceError.network(.unauthorized), named: "R8_E2")
    }

    func testBorrowFailure_BreakerTripped_OnLoanLimit_ShowsAlertAndKeepsBreakerArmed() async {
        await assertRepeatedBorrowFailure(failing: Self.credentialsDocError, then: Self.loanLimitError, named: "R8_E3")
    }

    // MARK: - R8b: breaker after an account switch
    // E3-E7 skipped: as R8, the breaker does not affect non-auth failures.

    func testBorrowFailure_BreakerClearedByAccountSwitch_OnCredentialsProblemDoc_PresentsSignInAgain() async {
        await assertRepeatedBorrowFailure(failing: Self.credentialsDocError, accountSwitchBetween: true, named: "R8b_E1")
    }

    func testBorrowFailure_BreakerClearedByAccountSwitch_On401_PresentsSignInAgain() async {
        await assertRepeatedBorrowFailure(failing: PalaceError.network(.unauthorized), accountSwitchBetween: true, named: "R8b_E2")
    }

    // MARK: - Scenario drivers

    /// One borrow that fails with `error`, then optionally the patron dismisses
    /// the sign-in sheet without signing in (credentials stay as they were).
    private func assertBorrowFailure(
        _ kind: AccountKind,
        failing error: Error,
        coordinator: (mechanism: AuthMechanism, modalSignsIn: Bool)? = nil,
        oidcSucceeds: Bool = false,
        alreadyOnLoan: Bool = false,
        dismissModal: Bool = false,
        named name: String
    ) async {
        prepare(kind, coordinator: coordinator, oidcSucceeds: oidcSucceeds, alreadyOnLoan: alreadyOnLoan)
        fetchScript.error = error
        await borrow()
        if dismissModal { await dismissSignInModal() }
        finish(named: name)
    }

    /// Two Basic-with-credentials borrows of the same book, the sheet from the
    /// first left open; optionally an account switch clears the breaker between.
    private func assertRepeatedBorrowFailure(
        failing first: Error,
        then second: Error? = nil,
        accountSwitchBetween: Bool = false,
        named name: String
    ) async {
        prepare(.basicWithCredentials, coordinator: nil, oidcSucceeds: false, alreadyOnLoan: false)
        fetchScript.error = first
        await borrow()
        if accountSwitchBetween {
            BorrowOperation.clearAllBorrowReauthState()
            log.record("test.accountSwitch", args: ["breakerArmed": Self.breakerArmed])
        }
        if let second { fetchScript.error = second }
        await borrow()
        finish(named: name)
    }

    /// The borrow's task is cancelled while `fetchBook` is in flight.
    private func assertCancelledBorrow(
        _ kind: AccountKind,
        coordinator: (mechanism: AuthMechanism, modalSignsIn: Bool)? = nil,
        alreadyOnLoan: Bool = false,
        named name: String
    ) async {
        prepare(kind, coordinator: coordinator, oidcSucceeds: false, alreadyOnLoan: alreadyOnLoan)
        fetchScript.hangUntilCancelled = true
        let task = Task { await self.borrow() }
        let capturedLog = log
        await awaitConditionAsync(timeout: 10) { [capturedLog] in
            capturedLog?.snapshot().contains(where: { $0.method == "fetchBook" }) ?? false
        }
        log.record("test.cancelBorrowTask")
        task.cancel()
        await task.value
        // Known: PP-5565 a cancelled borrow shows the "Borrow failed" alert with Retry.
        finish(named: name)
    }

    private func prepare(
        _ kind: AccountKind,
        coordinator: (mechanism: AuthMechanism, modalSignsIn: Bool)?,
        oidcSucceeds: Bool,
        alreadyOnLoan: Bool
    ) {
        switch kind {
        case .noAuthDefinition:
            account._authDefinition = nil
            account._credentials = nil
        case .basicNoCredentials:
            account._authDefinition = Self.authentication(type: "http://opds-spec.org/auth/basic")
            account._credentials = nil
        case .basicWithCredentials:
            account._authDefinition = Self.authentication(type: "http://opds-spec.org/auth/basic")
            account._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        case .saml:
            account._authDefinition = Self.authentication(type: "http://librarysimplified.org/authtype/SAML-2.0")
            account._credentials = .barcodeAndPin(barcode: "saml-user", pin: "x")
        case .oidc:
            account._authDefinition = Self.authentication(type: "http://palaceproject.io/authtype/OpenIDConnect")
            account._credentials = .barcodeAndPin(barcode: "oidc-user", pin: "y")
        }
        if alreadyOnLoan {
            registry.addBook(book, location: nil, state: .downloadNeeded,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        }
        oidcResult.value = oidcSucceeds
        // Seeding above is setup, not behavior: recording starts here.
        registry.callLog = log
        account.callLog = log
        makeOperation(coordinator: coordinator.map { makeCoordinator(mechanism: $0.mechanism, modalSignsIn: $0.modalSignsIn) })
    }

    private func borrow() async {
        do {
            let borrowed = try await operation.borrowAsync(book, attemptDownload: false)
            log.record("borrowReturned", args: ["bookId": borrowed.identifier])
        } catch {
            log.record("borrowThrew", args: ["error": "\(error)"])
        }
    }

    /// The patron closes the sheet without signing in, so the account keeps
    /// whatever credentials and auth state the failure left it with.
    private func dismissSignInModal() async {
        log.record("test.dismissSignInModal", args: ["pending": pendingModalCompletions.count])
        let completions = pendingModalCompletions
        pendingModalCompletions = []
        completions.forEach { $0() }
        await operation._awaitPendingRetriesForTesting()
    }

    private func finish(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        log.record("end", args: ["breakerArmed": Self.breakerArmed,
                                 "authState": "\(account.authState)"])
        ContractSnapshot.assert(log, named: name, file: file, line: line)
    }

    private static var breakerArmed: Bool { BorrowOperation.isBorrowReauthGatedForTesting(bookId) }

    // MARK: - Operation and coordinator

    private func makeOperation(coordinator: AuthCoordinator?) {
        let callLog = log!
        let script = fetchScript
        let oidc = oidcResult
        let userAccount = account!
        operation = BorrowOperation(
            bookRegistry: registry,
            downloadAnnouncementService: RecordingAnnouncementService(log: callLog),
            errorActivityTracker: ErrorActivityTracker(),
            debugSettings: DebugSettings(),
            userRetryTracker: UserRetryTracker(),
            userAccountProvider: { userAccount },
            adobeDRMService: AdobeDRMService.shared,
            fetchBook: { _, _, _ in
                let attempt = script.nextAttempt()
                callLog.record("fetchBook", args: ["attempt": attempt, "breakerArmed": Self.breakerArmed])
                if script.hangUntilCancelled {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                }
                if let from = script.succeedFromAttempt, attempt >= from { return script.book! }
                throw script.error!
            },
            presentBorrowErrorAlert: { title, message, originalError, problemDoc, book, retryAction in
                callLog.record("presentBorrowErrorAlert",
                               args: ["title": title,
                                      "message": message,
                                      "bookId": book.identifier,
                                      "originalError": originalError.map { "\($0.domain)/\($0.code)" } ?? "nil",
                                      "problemDocType": problemDoc?.type ?? "nil",
                                      "hasRetryAction": retryAction != nil,
                                      "breakerArmed": Self.breakerArmed])
            },
            publishBorrowError: { info in
                callLog.record("publishBorrowError",
                               args: ["bookId": info.bookId,
                                      "presentsAlert": info.presentsAlert,
                                      "hasRetryAction": info.retryAction != nil])
            },
            presentSignInModal: { [weak self] completion in
                callLog.record("presentSignInModal", args: ["breakerArmed": Self.breakerArmed])
                self?.pendingModalCompletions.append(completion)
            },
            attemptOIDCReauth: {
                let result = oidc.value
                callLog.record("attemptOIDCReauth", args: ["result": result])
                return result
            },
            authCoordinator: coordinator,
            onBorrowSucceeded: { callLog.record("noteBorrowSucceeded") }
        )
        fetchScript.book = book
    }

    private func makeCoordinator(mechanism: AuthMechanism, modalSignsIn: Bool) -> AuthCoordinator {
        let provider = SpyCoordinatorAccountProvider()
        provider.stubbedMechanism = mechanism
        return AuthCoordinator(
            reauthenticator: SpyCoordinatorReauthenticator(),
            modalPresenter: RecordingCoordinatorModal(log: log, signsIn: modalSignsIn),
            userAccount: RecordingCoordinatorAccount(log: log),
            accountProvider: provider,
            recorder: RecordingAuthDecisions(log: log)
        )
    }

    // MARK: - Fixtures

    private static var credentialsDocError: Error {
        problemDocError(code: 401, ["type": TPPProblemDocument.TypeInvalidCredentials, "title": "Invalid credentials"])
    }

    private static var loanLimitError: Error {
        problemDocError(code: 403, ["type": TPPProblemDocument.TypePatronLoanLimit,
                                    "title": "Loan limit reached",
                                    "detail": "You have reached your loan limit."])
    }

    private static var loanAlreadyExistsError: Error {
        problemDocError(code: 400, ["type": TPPProblemDocument.TypeLoanAlreadyExists, "title": "Loan already exists"])
    }

    private static var noActiveLoanError: Error {
        problemDocError(code: 400, ["type": TPPProblemDocument.TypeNoActiveLoan, "title": "No active loan"])
    }

    private static func problemDocError(code: Int, _ dict: [String: Any]) -> Error {
        NSError(domain: "test", code: code,
                userInfo: ["problemDocument": TPPProblemDocument.fromDictionary(dict)])
    }

    private static func authentication(type: String) -> AccountDetails.Authentication {
        let json = """
        {"type": "\(type)", "description": "auth",
         "links": [{"rel": "authenticate", "href": "https://idp.example.com/auth"}]}
        """
        let docAuth = try! JSONDecoder().decode(OPDS2AuthenticationDocument.Authentication.self, from: Data(json.utf8))
        return AccountDetails.Authentication(auth: docAuth)
    }
}

// MARK: - Spies

/// What `fetchBook` does on each attempt. Read from a non-isolated closure, so
/// the closure captures this lock-guarded box rather than the test case.
private final class FetchScript: @unchecked Sendable {
    private let lock = NSLock()
    private var _attempts = 0
    private var _error: Error?
    private var _book: TPPBook?
    private var _succeedFromAttempt: Int?
    private var _hang = false

    var error: Error? { get { lock.withLock { _error } } set { lock.withLock { _error = newValue } } }
    var book: TPPBook? { get { lock.withLock { _book } } set { lock.withLock { _book = newValue } } }
    var succeedFromAttempt: Int? {
        get { lock.withLock { _succeedFromAttempt } } set { lock.withLock { _succeedFromAttempt = newValue } }
    }
    var hangUntilCancelled: Bool { get { lock.withLock { _hang } } set { lock.withLock { _hang = newValue } } }

    func nextAttempt() -> Int { lock.withLock { _attempts += 1; return _attempts } }

    func reset() {
        lock.withLock { _attempts = 0; _error = nil; _book = nil; _succeedFromAttempt = nil; _hang = false }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { get { lock.withLock { _value } } set { lock.withLock { _value = newValue } } }
}

private final class RecordingBookRegistry: TPPBookRegistryMock, @unchecked Sendable {
    var callLog: CallLog?

    override func setProcessing(_ processing: Bool, for bookIdentifier: String) {
        callLog?.record("registry.setProcessing", args: ["processing": processing, "bookId": bookIdentifier])
        super.setProcessing(processing, for: bookIdentifier)
    }

    override func addBook(_ book: TPPBook, location: TPPBookLocation? = nil, state: TPPBookState,
                          fulfillmentId: String? = nil, readiumBookmarks: [TPPReadiumBookmark]? = nil,
                          genericBookmarks: [TPPBookLocation]? = nil) {
        callLog?.record("registry.addBook", args: ["bookId": book.identifier, "state": "\(state)"])
        super.addBook(book, location: location, state: state, fulfillmentId: fulfillmentId,
                      readiumBookmarks: readiumBookmarks, genericBookmarks: genericBookmarks)
    }

    override func setState(_ state: TPPBookState, for bookIdentifier: String) {
        callLog?.record("registry.setState", args: ["bookId": bookIdentifier, "state": "\(state)"])
        super.setState(state, for: bookIdentifier)
    }
}

private final class RecordingUserAccount: TPPUserAccountMock, @unchecked Sendable {
    var callLog: CallLog?

    override func markCredentialsStale() {
        callLog?.record("account.markCredentialsStale")
        super.markCredentialsStale()
    }
}

private final class RecordingCoordinatorModal: SignInModalPresenting, @unchecked Sendable {
    private let log: CallLog
    private let signsIn: Bool
    init(log: CallLog, signsIn: Bool) { self.log = log; self.signsIn = signsIn }

    func presentSignInModalForCurrentAccount() async -> Bool {
        log.record("coordinator.presentSignInModal", args: ["signsIn": signsIn])
        return signsIn
    }
}

private final class RecordingCoordinatorAccount: TPPUserAccountReading, TPPUserAccountWriting, @unchecked Sendable {
    private let log: CallLog
    init(log: CallLog) { self.log = log }
    var hasCredentials: Bool { true }
    var authTokenHasExpired: Bool { false }
    func markCredentialsStale() { log.record("coordinator.markCredentialsStale") }
}

private final class RecordingAuthDecisions: AuthDecisionRecording, @unchecked Sendable {
    private let log: CallLog
    init(log: CallLog) { self.log = log }
    func record(_ payload: AuthDecisionPayload) {
        log.record("coordinator.decision", args: ["step": payload.step.rawValue, "decision": payload.decision])
    }
}

/// Records borrow announcements and suppresses the VoiceOver side effect.
private final class RecordingAnnouncementService: DownloadAnnouncementService {
    private let log: CallLog
    init(log: CallLog) { self.log = log; super.init() }
    override func announceBorrowStarted(for book: TPPBook) { log.record("announceBorrowStarted") }
    override func announceBorrowSucceeded(for book: TPPBook) { log.record("announceBorrowSucceeded") }
    override func announceBorrowFailed(for book: TPPBook) { log.record("announceBorrowFailed") }
}
