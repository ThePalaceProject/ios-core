import XCTest
import PalaceAuth
import PalaceCatalog
@testable import Palace

/// `dispatch(_:)` runs the effect `AuthReducer` returns. These pin that a
/// bearer token starts one credential validation and that the other actions
/// start no sign-in work at all.
@MainActor
final class TPPSignInAuthEffectsTests: XCTestCase {
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var businessLogic: ValidationCountingBusinessLogic!

    override func setUp() async throws {
        try await super.setUp()
        TPPUserAccountMock.resetShared()
        libraryAccountMock = TPPLibraryAccountMock()
        businessLogic = ValidationCountingBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock(),
            drmAuthorizer: TPPDRMAuthorizingMock(),
            appNetwork: SignInAppNetworkSpy())
    }

    override func tearDown() async throws {
        await businessLogic?._awaitSignInWorkForTesting()
        businessLogic?.userAccount.removeAll()
        businessLogic = nil
        libraryAccountMock = nil
        try await super.tearDown()
    }

    func testDispatch_BearerTokenReceived_ValidatesCredentialsOnce() async {
        businessLogic.dispatch(.bearerTokenReceived(token: "tok", expiration: nil))

        XCTAssertEqual(businessLogic._pendingSignInTaskCountForTesting, 1,
                       "The validation must run on one sign-in task, not inline")
        XCTAssertEqual(businessLogic.validationCount, 0,
                       "Validation runs after the synchronous caller returns")
        await businessLogic._awaitSignInWorkForTesting()

        XCTAssertEqual(businessLogic.validationCount, 1)
        XCTAssertEqual(businessLogic.authToken, "tok")
    }

    func testDispatch_ActionWithoutEffect_StartsNoSignInTask() async {
        businessLogic.dispatch(.credentialCaptureStarted(barcode: "b", pin: "p"))
        businessLogic.dispatch(.errorCleared)

        XCTAssertEqual(businessLogic._pendingSignInTaskCountForTesting, 0,
                       "A .none effect must not schedule a task")
        await businessLogic._awaitSignInWorkForTesting()
        XCTAssertEqual(businessLogic.validationCount, 0)
        XCTAssertEqual(businessLogic.capturedBarcode, "b")
    }
}

/// Replaces the network validation with a counter so the test observes only
/// whether `dispatch(_:)` started it.
private final class ValidationCountingBusinessLogic: TPPSignInBusinessLogic {
    private(set) var validationCount = 0

    override func validateCredentials() async {
        validationCount += 1
    }
}

extension TPPSignInBusinessLogic {
    /// Applies `action` to the in-flight auth state without starting the
    /// effect the reducer returns. For tests that need a bearer token only as
    /// a precondition; a real `dispatch` would also start credential validation.
    func reduceAuthStateForTesting(_ action: AuthAction) {
        _ = AuthReducer.reduce(&authState, action)
    }
}
