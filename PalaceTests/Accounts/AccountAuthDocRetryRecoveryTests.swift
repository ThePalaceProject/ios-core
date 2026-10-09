//
//  AccountAuthDocRetryRecoveryTests.swift
//
//  A successful `Account.loadAuthenticationDocument` must leave `loadState` at
//  `.detailsLoaded` with the new details, including after an earlier failure.
//  The sign-in UI reads details only through that state, so a retry that set
//  `details` but left `.detailsFailed` showed no sign-in form.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class AccountAuthDocRetryRecoveryTests: XCTestCase {

    private var libraryAccountMock: TPPLibraryAccountMock!
    private var account: Account!
    private var authDocData: Data!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TPPUserAccountMock.resetShared()
        libraryAccountMock = TPPLibraryAccountMock()
        account = libraryAccountMock.tppAccount
        authDocData = try Data(contentsOf: libraryAccountMock.nyplAuthDocURL)
        // The state a failed first load leaves: no details, `.detailsFailed`.
        account.details = nil
        account._setState(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "timed out")))
    }

    override func tearDownWithError() throws {
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        account = nil
        libraryAccountMock = nil
        try super.tearDownWithError()
    }

    // MARK: - Account.loadAuthenticationDocument

    /// A retry that succeeds after a failed load moves the state to `.detailsLoaded`
    /// with the new details, before the caller's completion runs.
    func testLoad_AfterFailedLoad_WhenRetrySucceeds_StateIsDetailsLoadedBeforeCompletion() throws {
        account.authDocumentGetter = StubAuthDocGetter(result: .success(authDocData, nil))

        var stateAtCompletion: Account.LoadState?
        var result: Bool?
        account.loadAuthenticationDocument { ok in
            result = ok
            stateAtCompletion = self.account.loadState
        }

        XCTAssertEqual(result, true)
        let details = try XCTUnwrap(account.details, "a successful load sets details")
        guard case .detailsLoaded(let loaded)? = stateAtCompletion else {
            return XCTFail("state at completion was \(String(describing: stateAtCompletion)), expected .detailsLoaded")
        }
        XCTAssertTrue(loaded === details, "the state carries the details the load just produced")
    }

    /// A retry that fails again leaves the earlier failure in place; this path
    /// writes no state on failure.
    func testLoad_AfterFailedLoad_WhenRetryFails_StateStaysDetailsFailed() {
        account.authDocumentGetter = StubAuthDocGetter(result: .failure(Self.networkError, nil))

        var result: Bool?
        account.loadAuthenticationDocument { result = $0 }

        XCTAssertEqual(result, false)
        guard case .detailsFailed = account.loadState else {
            return XCTFail("state was \(account.loadState), expected .detailsFailed")
        }
        XCTAssertNil(account.details)
    }

    /// A load for an account that was deselected must not overwrite the eviction
    /// marker: awaiters rely on it to fail fast and redrive on return.
    func testLoad_WhenAccountWasEvicted_SuccessKeepsEvictionMarker() {
        account._setState(.detailsEvicted(.libraryDeselected(uuid: account.uuid)))
        account.authDocumentGetter = StubAuthDocGetter(result: .success(authDocData, nil))

        account.loadAuthenticationDocument { _ in }

        guard case .detailsEvicted = account.loadState else {
            return XCTFail("state was \(account.loadState), expected .detailsEvicted")
        }
    }

    /// While the state machine's own fetch is in flight (`.detailsLoading`), its
    /// completion writes the terminal; this path leaves the state alone.
    func testLoad_WhenStateMachineFetchInFlight_LeavesDetailsLoadingToItsOwner() {
        account._setState(.detailsLoading)
        account.authDocumentGetter = StubAuthDocGetter(result: .success(authDocData, nil))

        account.loadAuthenticationDocument { _ in }

        guard case .detailsLoading = account.loadState else {
            return XCTFail("state was \(account.loadState), expected .detailsLoading")
        }
    }

    /// A first load that never went through the state machine (`.basicInfoLoaded`)
    /// also ends at `.detailsLoaded`.
    func testLoad_FromBasicInfoLoaded_WhenSucceeds_StateIsDetailsLoaded() {
        account._setState(.basicInfoLoaded)
        account.authDocumentGetter = StubAuthDocGetter(result: .success(authDocData, nil))

        account.loadAuthenticationDocument { _ in }

        guard case .detailsLoaded(let loaded) = account.loadState else {
            return XCTFail("state was \(account.loadState), expected .detailsLoaded")
        }
        XCTAssertTrue(loaded === account.details)
    }

    /// A load before the registry has marked the account (`.notLoaded`) ends at
    /// `.detailsLoaded` too.
    func testLoad_FromNotLoaded_WhenSucceeds_StateIsDetailsLoaded() {
        account._setState(.notLoaded)
        account.authDocumentGetter = StubAuthDocGetter(result: .success(authDocData, nil))

        account.loadAuthenticationDocument { _ in }

        guard case .detailsLoaded(let loaded) = account.loadState else {
            return XCTFail("state was \(account.loadState), expected .detailsLoaded")
        }
        XCTAssertTrue(loaded === account.details)
    }

    /// A reload over loaded details replaces the details in the state too, so
    /// `loadedAccountDetails` and `details` stay the same object.
    func testLoad_WhenAlreadyLoaded_StateCarriesTheNewDetails() throws {
        account.authDocumentGetter = StubAuthDocGetter(result: .success(authDocData, nil))
        account.loadAuthenticationDocument { _ in }
        let first = try XCTUnwrap(account.details)

        account.loadAuthenticationDocument { _ in }

        let second = try XCTUnwrap(account.details)
        XCTAssertFalse(first === second, "precondition: the reload built new details")
        guard case .detailsLoaded(let loaded) = account.loadState else {
            return XCTFail("state was \(account.loadState), expected .detailsLoaded")
        }
        XCTAssertTrue(loaded === second)
    }

    // MARK: - Sign-in screen path

    /// The Account screen's path: after a failed first load,
    /// `ensureAuthenticationDocumentIsLoaded` succeeds and the sign-in UI can read
    /// the library's details, including the card-and-PIN authentication.
    @MainActor
    func testEnsureAuthDocLoaded_AfterFailedFirstLoad_SignInSeesDetailsAndAuthentication() async {
        account.authDocumentGetter = StubAuthDocGetter(result: .success(authDocData, nil))
        let businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: TPPDRMAuthorizingMock()
        )
        XCTAssertNil(businessLogic.loadedAccountDetails, "precondition: the failed load left no readable details")

        let success = await withCheckedContinuation { continuation in
            businessLogic.ensureAuthenticationDocumentIsLoaded { continuation.resume(returning: $0) }
        }

        XCTAssertTrue(success)
        XCTAssertTrue(businessLogic.loadedAccountDetails === account.details,
                      "the sign-in UI reads the details the retry loaded")
        XCTAssertEqual(businessLogic.loadedAccountDetails?.auths.contains { $0.authType == .basic }, true,
                       "the card-and-PIN authentication that drives the barcode field is readable")
        businessLogic.userAccount.removeAll()
    }

    // MARK: - Helpers

    private static let networkError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
}

/// Completes synchronously with a fixed result.
private struct StubAuthDocGetter: AuthDocumentGetting, @unchecked Sendable {
    let result: NYPLResult<Data>
    func get(_ url: URL, completion: @escaping (NYPLResult<Data>) -> Void) {
        completion(result)
    }
}
