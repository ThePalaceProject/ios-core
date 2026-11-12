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
        businessLogic = makeBusinessLogic(probe: nil)
    }

    private func makeBusinessLogic(probe: ValidationProbe?) -> ValidationCountingBusinessLogic {
        let logic = ValidationCountingBusinessLogic(
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
        logic.probe = probe
        return logic
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

    /// The patron can close the sign-in screen while the account check runs;
    /// the check must still finish, so the effect must keep the object alive.
    func testDispatch_BearerTokenReceived_ValidatesAfterTheCallerReleasesTheSignInObject() async {
        let probe = ValidationProbe()
        var released: ValidationCountingBusinessLogic? = makeBusinessLogic(probe: probe)
        weak var weakLogic = released

        released?.dispatch(.bearerTokenReceived(token: "tok", expiration: nil))
        released = nil
        XCTAssertEqual(probe.count, 0, "Validation runs after the synchronous caller returns")

        // Each wait fails the test if its condition never holds.
        await awaitConditionAsync { probe.count == 1 }
        await awaitConditionAsync { weakLogic == nil }
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

/// Counts validations outside the business logic, so a test can read the
/// count after the business logic is gone.
@MainActor
private final class ValidationProbe {
    var count = 0
}

/// Replaces the network validation with a counter so the test observes only
/// whether `dispatch(_:)` started it.
private final class ValidationCountingBusinessLogic: TPPSignInBusinessLogic {
    var probe: ValidationProbe?
    private(set) var validationCount = 0

    override func validateCredentials() async {
        validationCount += 1
        probe?.count += 1
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
