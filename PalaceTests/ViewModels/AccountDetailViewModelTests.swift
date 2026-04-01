//
//  AccountDetailViewModelTests.swift
//  PalaceTests
//
//  Tests for AccountDetailViewModel (SignIn) functionality.
//  Tests real business logic for authentication flows.
//
//  Uses mock dependencies injected via the test initializer so tests
//  do not depend on AccountsManager.shared having loaded a catalog.
//

import XCTest
import Combine
@testable import Palace

// MARK: - Shared Test Helpers

/// Builds an `AccountDetailViewModel` backed entirely by mocks.
/// The returned tuple gives tests access to the mock objects for
/// credential manipulation.
@MainActor
private func makeViewModel(
    userAccountMock: TPPUserAccountMock = .init()
) -> (viewModel: AccountDetailViewModel,
      libraryMock: TPPLibraryAccountMock,
      userAccountMock: TPPUserAccountMock) {

    // Reset the shared mock so previous test state does not leak.
    TPPUserAccountMock.resetShared()

    let libraryMock = TPPLibraryAccountMock()
    let libraryID = libraryMock.tppAccountUUID

    let businessLogic = TPPSignInBusinessLogic(
        libraryAccountID: libraryID,
        libraryAccountsProvider: libraryMock,
        urlSettingsProvider: TPPURLSettingsProviderMock(),
        bookRegistry: TPPBookRegistryMock(),
        bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
        userAccountProvider: TPPUserAccountMock.self,
        networkExecutor: TPPRequestExecutorMock(),
        uiDelegate: nil,
        drmAuthorizer: nil
    )

    let viewModel = AccountDetailViewModel(
        libraryAccountID: libraryID,
        businessLogic: businessLogic,
        credentialSnapshotProvider: { _ in
            TPPUserAccountMock.credentialSnapshot(for: libraryID)
        }
    )

    return (viewModel, libraryMock, userAccountMock)
}

// MARK: - AccountDetailViewModelTests

@MainActor
final class AccountDetailViewModelTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        cancellables = []
        TPPUserAccountMock.resetShared()
    }

    override func tearDown() {
        cancellables.removeAll()
        TPPUserAccountMock.resetShared()
        super.tearDown()
    }

    // MARK: - Published Property Tests

    func testInitialPublishedPropertiesState() {
        let (viewModel, _, _) = makeViewModel()

        XCTAssertEqual(viewModel.usernameText, "")
        XCTAssertEqual(viewModel.pinText, "")
        XCTAssertFalse(viewModel.showingAlert)
        XCTAssertEqual(viewModel.alertTitle, "")
        XCTAssertEqual(viewModel.alertMessage, "")
        XCTAssertFalse(viewModel.showBarcode)
    }

    func testUsernameTextUpdate() {
        let (viewModel, _, _) = makeViewModel()

        viewModel.usernameText = "testuser123"
        XCTAssertEqual(viewModel.usernameText, "testuser123")
    }

    func testPinTextUpdate() {
        let (viewModel, _, _) = makeViewModel()

        viewModel.pinText = "1234"
        XCTAssertEqual(viewModel.pinText, "1234")
    }

    func testIsPINHiddenDefaultsToTrue() {
        let (viewModel, _, _) = makeViewModel()

        XCTAssertTrue(viewModel.isPINHidden)
    }

    func testTogglePINVisibility() {
        let (viewModel, _, _) = makeViewModel()

        // pinText is empty so togglePINVisibility takes the synchronous path.
        XCTAssertTrue(viewModel.isPINHidden)
        viewModel.togglePINVisibility()
        XCTAssertFalse(viewModel.isPINHidden)
        viewModel.togglePINVisibility()
        XCTAssertTrue(viewModel.isPINHidden)
    }

    func testShowBarcodeToggle() {
        let (viewModel, _, _) = makeViewModel()

        XCTAssertFalse(viewModel.showBarcode)
        viewModel.showBarcode = true
        XCTAssertTrue(viewModel.showBarcode)
    }

    // MARK: - canSignIn Tests

    func testCanSignInWithEmptyCredentials() {
        let (viewModel, _, _) = makeViewModel()
        viewModel.usernameText = ""
        viewModel.pinText = ""

        XCTAssertFalse(viewModel.canSignIn)
    }

    func testCanSignInWithOnlyUsername() {
        let (viewModel, libraryMock, _) = makeViewModel()

        // Set basic auth so we know pinKeyboard is .standard (not .none)
        viewModel.businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication

        viewModel.usernameText = "testuser"
        viewModel.pinText = ""

        if viewModel.businessLogic.selectedAuthentication?.pinKeyboard == .none {
            XCTAssertTrue(viewModel.canSignIn)
        } else {
            XCTAssertFalse(viewModel.canSignIn,
                           "canSignIn should be false when PIN is required but empty")
        }
    }

    func testCanSignInWithBothCredentials() {
        let (viewModel, libraryMock, _) = makeViewModel()

        // Use basic auth (barcode + PIN, not OAuth/SAML)
        viewModel.businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication

        viewModel.usernameText = "testuser"
        viewModel.pinText = "1234"

        XCTAssertTrue(viewModel.canSignIn,
                      "canSignIn should be true when both username and PIN are provided for basic auth")
    }

    // MARK: - Library Properties Tests

    func testLibraryNameReturnsAccountName() {
        let (viewModel, libraryMock, _) = makeViewModel()

        XCTAssertEqual(viewModel.libraryName, libraryMock.tppAccount.name)
    }

    func testSelectedAccountMatchesInitialized() {
        let (viewModel, libraryMock, _) = makeViewModel()

        XCTAssertNotNil(viewModel.selectedAccount)
        XCTAssertEqual(viewModel.selectedAccount?.uuid, libraryMock.tppAccountUUID)
    }

    // MARK: - Alert Tests

    func testAlertPropertiesUpdate() {
        let (viewModel, _, _) = makeViewModel()

        viewModel.alertTitle = "Test Title"
        viewModel.alertMessage = "Test Message"
        viewModel.showingAlert = true

        XCTAssertEqual(viewModel.alertTitle, "Test Title")
        XCTAssertEqual(viewModel.alertMessage, "Test Message")
        XCTAssertTrue(viewModel.showingAlert)
    }

    // MARK: - Sync Tests

    func testIsSyncEnabledToggle() {
        let (viewModel, _, _) = makeViewModel()
        let initialValue = viewModel.isSyncEnabled

        viewModel.isSyncEnabled = !initialValue
        XCTAssertNotEqual(viewModel.isSyncEnabled, initialValue)
    }

    // MARK: - Business Logic Integration Tests

    func testBusinessLogic_IsInitialized() {
        let (viewModel, _, _) = makeViewModel()

        XCTAssertNotNil(viewModel.businessLogic)
    }

    func testCredentialFields_AreIndependent() {
        let (viewModel, _, _) = makeViewModel()

        viewModel.usernameText = "user123"
        viewModel.pinText = "4567"

        XCTAssertEqual(viewModel.usernameText, "user123")
        XCTAssertEqual(viewModel.pinText, "4567")
        XCTAssertNotEqual(viewModel.usernameText, viewModel.pinText)
    }

    func testClearCredentials_WorksIndependently() {
        let (viewModel, _, _) = makeViewModel()

        viewModel.usernameText = "user123"
        viewModel.pinText = "4567"

        viewModel.usernameText = ""

        XCTAssertEqual(viewModel.usernameText, "")
        XCTAssertEqual(viewModel.pinText, "4567")
    }

    // MARK: - UI State Management Tests

    func testMultipleAlerts_CanBeShown() {
        let (viewModel, _, _) = makeViewModel()

        // Set first alert
        viewModel.alertTitle = "First Alert"
        viewModel.alertMessage = "First Message"
        viewModel.showingAlert = true

        XCTAssertTrue(viewModel.showingAlert)

        // Dismiss and show second alert
        viewModel.showingAlert = false
        viewModel.alertTitle = "Second Alert"
        viewModel.alertMessage = "Second Message"
        viewModel.showingAlert = true

        XCTAssertEqual(viewModel.alertTitle, "Second Alert")
        XCTAssertEqual(viewModel.alertMessage, "Second Message")
        XCTAssertTrue(viewModel.showingAlert)
    }

    // MARK: - Validation Tests

    func testCanSignIn_WithWhitespaceOnlyUsername() {
        let (viewModel, libraryMock, _) = makeViewModel()
        viewModel.businessLogic.selectedAuthentication = libraryMock.barcodeAuthentication

        viewModel.usernameText = "   "
        viewModel.pinText = "1234"

        // Whitespace-only username should not count as valid for basic auth
        XCTAssertFalse(viewModel.canSignIn,
                       "canSignIn should be false when username is whitespace-only")
    }

    func testCanSignIn_WithSpecialCharacters() {
        let (viewModel, _, _) = makeViewModel()
        viewModel.usernameText = "user@example.com"
        viewModel.pinText = "pass!@#$%"

        // Special characters should be allowed in credentials
        XCTAssertEqual(viewModel.usernameText, "user@example.com")
        XCTAssertEqual(viewModel.pinText, "pass!@#$%")
    }
}

// MARK: - Credential State UI Tests
//
// Tests for isSignedIn behavior based on credential state.
//
// Current production logic (AccountDetailViewModel.refreshSignInState):
//   isSignedIn = snapshot.hasCredentials && snapshot.authState != .loggedOut
//
// This means:
// - Any auth type with credentials and state != .loggedOut -> isSignedIn = true
// - .credentialsStale with credentials -> isSignedIn = true (credentials still exist)
// - .loggedOut or no credentials -> isSignedIn = false

@MainActor
final class AccountDetailCredentialStateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
    }

    override func tearDown() {
        TPPUserAccountMock.resetShared()
        super.tearDown()
    }

    // MARK: - Helper

    /// Returns the shared TPPUserAccountMock that the mock provider vends.
    /// This is the same instance that TPPUserAccountMock.credentialSnapshot(for:) reads.
    private var mockAccount: TPPUserAccountMock {
        TPPUserAccountMock.sharedAccount(libraryUUID: nil) as! TPPUserAccountMock
    }

    // MARK: - Stale credentials isSignedIn Tests

    /// When OAuth credentials are stale, isSignedIn should remain TRUE because the
    /// user still has credentials on file (token refreshes in background).
    func testIsSignedIn_trueWhenOAuthCredentialsStale() {
        let (viewModel, _, _) = makeViewModel()

        // Given: User has OAuth credentials (token-based) that are stale
        mockAccount.setAuthToken("expired_token", barcode: nil, pin: nil,
                                 expirationDate: Date().addingTimeInterval(-3600))
        mockAccount.setAuthState(.credentialsStale)

        // When: View model refreshes state
        viewModel.refreshSignInState()

        // Then: isSignedIn should be TRUE (has credentials, state != loggedOut)
        XCTAssertTrue(viewModel.isSignedIn,
                      "OAuth: isSignedIn should be true when credentials are stale (token refreshes in background)")
    }

    /// When SAML/Basic credentials are stale, isSignedIn should still be TRUE
    /// because the user has credentials on file and is not logged out.
    /// The ViewModel treats all stale-credential states the same: isSignedIn = true.
    func testIsSignedIn_trueWhenBasicCredentialsStale() {
        let (viewModel, _, _) = makeViewModel()

        // Given: User has basic credentials (barcode/PIN) that are stale
        mockAccount.setBarcode("test_user", PIN: "1234")
        mockAccount.setAuthState(.credentialsStale)

        // When: View model refreshes state
        viewModel.refreshSignInState()

        // Then: isSignedIn should be TRUE (hasCredentials && authState != .loggedOut)
        XCTAssertTrue(viewModel.isSignedIn,
                      "Basic auth: isSignedIn should be true when credentials are stale (credentials still on file)")
    }

    // MARK: - General isSignedIn Tests (auth-type independent)

    /// When user is fully logged in (not stale), isSignedIn should be TRUE regardless of auth type.
    func testIsSignedIn_trueWhenLoggedIn() {
        let (viewModel, _, _) = makeViewModel()

        // Given: User has credentials and is fully logged in
        mockAccount.setBarcode("test_user", PIN: "1234")
        mockAccount.setAuthState(.loggedIn)

        // When: View model refreshes state
        viewModel.refreshSignInState()

        // Then: isSignedIn should be TRUE
        XCTAssertTrue(viewModel.isSignedIn,
                      "isSignedIn should be true when user is fully logged in")
    }

    /// When user is logged out, isSignedIn should be FALSE regardless of auth type.
    func testIsSignedIn_falseWhenLoggedOut() {
        let (viewModel, _, _) = makeViewModel()

        // Given: User is logged out (no credentials)
        mockAccount.removeAll()

        // When: View model refreshes state
        viewModel.refreshSignInState()

        // Then: isSignedIn should be FALSE
        XCTAssertFalse(viewModel.isSignedIn,
                       "isSignedIn should be false when user is logged out")
    }

    /// Transition from loggedIn to credentialsStale: isSignedIn should remain TRUE
    /// because the user still has stored credentials.
    func testIsSignedIn_remainsTrueWhenStateBecomesStale() {
        let (viewModel, _, _) = makeViewModel()

        // Given: User starts logged in with barcode/PIN credentials
        mockAccount.setBarcode("test_user", PIN: "1234")
        mockAccount.setAuthState(.loggedIn)
        viewModel.refreshSignInState()
        XCTAssertTrue(viewModel.isSignedIn, "Should start signed in")

        // When: Session expires (credentials become stale)
        mockAccount.markCredentialsStale()
        viewModel.refreshSignInState()

        // Then: isSignedIn should remain TRUE (credentials still exist)
        XCTAssertTrue(viewModel.isSignedIn,
                      "isSignedIn should remain true when credentials become stale (not loggedOut)")
    }

    /// For OAuth: Transition from loggedIn to credentialsStale should keep isSignedIn true.
    func testIsSignedIn_OAuthRemainsSignedInWhenStateBecomesStale() {
        let (viewModel, _, _) = makeViewModel()

        // Given: User starts logged in with OAuth (token credentials)
        mockAccount.setAuthToken("valid_token", barcode: nil, pin: nil,
                                 expirationDate: Date().addingTimeInterval(3600))
        mockAccount.setAuthState(.loggedIn)
        viewModel.refreshSignInState()
        XCTAssertTrue(viewModel.isSignedIn, "Should start signed in")

        // When: Token expires (credentials become stale)
        mockAccount.markCredentialsStale()
        viewModel.refreshSignInState()

        // Then: isSignedIn should remain TRUE for OAuth (token refreshes in background)
        XCTAssertTrue(viewModel.isSignedIn,
                      "OAuth: isSignedIn should remain true when credentials become stale (token refreshes)")
    }

    /// Re-authentication from stale should keep isSignedIn as TRUE (it was already true).
    /// This tests the transition: credentialsStale -> loggedIn.
    func testIsSignedIn_remainsTrueAfterReauthentication() {
        let (viewModel, _, _) = makeViewModel()

        // Given: User has stale credentials (barcode/PIN)
        mockAccount.setBarcode("test_user", PIN: "1234")
        mockAccount.setAuthState(.credentialsStale)
        viewModel.refreshSignInState()
        XCTAssertTrue(viewModel.isSignedIn, "Stale credentials: should still appear signed in")

        // When: User re-authenticates successfully
        mockAccount.markLoggedIn()
        viewModel.refreshSignInState()

        // Then: isSignedIn should still be TRUE
        XCTAssertTrue(viewModel.isSignedIn,
                      "isSignedIn should be true after successful re-authentication")
    }

    /// Explicit logout should transition isSignedIn from true to false.
    func testIsSignedIn_becomesFalseAfterExplicitLogout() {
        let (viewModel, _, _) = makeViewModel()

        // Given: User starts logged in
        mockAccount.setBarcode("test_user", PIN: "1234")
        mockAccount.setAuthState(.loggedIn)
        viewModel.refreshSignInState()
        XCTAssertTrue(viewModel.isSignedIn, "Should start signed in")

        // When: User explicitly logs out
        mockAccount.removeAll()
        viewModel.refreshSignInState()

        // Then: isSignedIn should become FALSE
        XCTAssertFalse(viewModel.isSignedIn,
                       "isSignedIn should become false after explicit logout")
    }

    // MARK: - needsReauthentication Tests

    /// Account should indicate it needs re-authentication when credentials are stale.
    func testNeedsReauthentication_trueWhenCredentialsStale() {
        // Given: User has stale credentials
        mockAccount.setBarcode("test_user", PIN: "1234")
        mockAccount.setAuthState(.credentialsStale)

        // Then: Account should indicate it needs re-authentication
        XCTAssertTrue(mockAccount.authState.needsReauthentication,
                      "Account should need re-authentication when credentials are stale")

        // And: hasCredentials should still be true (credentials exist, just expired)
        XCTAssertTrue(mockAccount.hasCredentials(),
                      "hasCredentials should be true even when credentials are stale")
    }
}

// MARK: - PIN Visibility Business Logic Tests

@MainActor
final class AccountDetailPINVisibilityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
    }

    override func tearDown() {
        TPPUserAccountMock.resetShared()
        super.tearDown()
    }

    func testPINVisibility_DefaultsToHidden() {
        let (viewModel, _, _) = makeViewModel()

        // The test initializer does not call accountDidChange() asynchronously,
        // so isPINHidden remains at its default value without any race.
        XCTAssertTrue(viewModel.isPINHidden, "PIN should be hidden by default for security")
    }

    func testPINVisibility_ToggleMultipleTimes() {
        let (viewModel, _, _) = makeViewModel()

        // pinText is empty (no stored credentials in mock) so togglePINVisibility
        // takes the synchronous direct-toggle path (no async biometric challenge).
        viewModel.togglePINVisibility()                 // direct: pinText empty -> reveal
        XCTAssertFalse(viewModel.isPINHidden)

        viewModel.togglePINVisibility()                 // direct: isPINHidden false -> hide
        XCTAssertTrue(viewModel.isPINHidden)

        viewModel.pinText = ""                          // ensure direct path for next reveal
        viewModel.togglePINVisibility()
        XCTAssertFalse(viewModel.isPINHidden)

        viewModel.togglePINVisibility()                 // direct: isPINHidden false -> hide
        XCTAssertTrue(viewModel.isPINHidden)
    }

    func testPINVisibility_IndependentOfCredentialChanges() {
        let (viewModel, _, _) = makeViewModel()

        viewModel.togglePINVisibility()
        XCTAssertFalse(viewModel.isPINHidden)

        // Changing credentials shouldn't affect visibility
        viewModel.pinText = "newpin"

        XCTAssertFalse(viewModel.isPINHidden)
    }
}
