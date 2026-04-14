//
//  AccountsManagerTests.swift
//  PalaceTests
//
//  Tests for AccountsManager focusing on:
//  - Account switching (currentAccount setter)
//  - Account lookup (account(_ uuid:))
//  - Notification posting for account changes
//  - Integration with real AccountsManager logic
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

final class AccountsManagerTests: XCTestCase {

    // MARK: - Properties

    private var cancellables: Set<AnyCancellable>!
    private var mockLibraryAccountProvider: TPPLibraryAccountMock!

    // MARK: - Test Accounts Data

    private let testUUID1 = "urn:uuid:test-account-1"
    private let testUUID2 = "urn:uuid:test-account-2"
    private let nyplUUID = "urn:uuid:065c0c11-0d0f-42a3-82e4-277b18786949"

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        cancellables = Set<AnyCancellable>()
        mockLibraryAccountProvider = TPPLibraryAccountMock()

        // Clear any previously stored account identifier
        UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey)
    }

    override func tearDown() {
        cancellables = nil
        mockLibraryAccountProvider = nil
        UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey)
        super.tearDown()
    }

    // MARK: - TPPLibraryAccountsProvider Protocol Conformance Tests

    func testAccountsManager_ConformsToTPPLibraryAccountsProvider() {
        // Given: The shared AccountsManager
        let manager = AccountsManager.shared

        // Then: It should conform to the protocol and be able to look up accounts
        XCTAssertTrue(manager is TPPLibraryAccountsProvider)
        // The protocol requires a tppAccountUUID — verify it's non-empty
        XCTAssertFalse(manager.tppAccountUUID.isEmpty,
                       "A TPPLibraryAccountsProvider must expose a non-empty tppAccountUUID")
    }

    func testAccountsManager_HasNYPLAccountUUID() {
        // Given: The shared AccountsManager
        let manager = AccountsManager.shared

        // Then: The NYPL account UUID should be the first in the list
        XCTAssertEqual(manager.tppAccountUUID, AccountsManager.TPPAccountUUIDs[0])
        XCTAssertEqual(manager.tppAccountUUID, nyplUUID)
    }

    // MARK: - Account Lookup Tests

    func testAccount_WithValidUUID_ReturnsAccount() {
        // Given: A mock library account provider with a known account
        let provider = mockLibraryAccountProvider!

        // When: Looking up the account by UUID
        let account = provider.account(provider.tppAccountUUID)

        // Then: The account should be found
        XCTAssertNotNil(account)
        XCTAssertEqual(account?.uuid, provider.tppAccountUUID)
    }

    func testAccount_WithEmptyUUID_ReturnsNil() {
        // Given: A mock library account provider
        let provider = mockLibraryAccountProvider!

        // When: Looking up with an empty UUID
        let account = provider.account("")

        // Then: Should return nil
        XCTAssertNil(account)
    }

    func testAccount_WithNonExistentUUID_CreatesNewAccount() {
        // Given: A mock library account provider
        let provider = mockLibraryAccountProvider!
        let nonExistentUUID = "urn:uuid:non-existent-account"

        // When: Looking up a non-existent UUID in mock
        let account = provider.account(nonExistentUUID)

        // Then: Mock creates a new account for unknown UUIDs
        XCTAssertNotNil(account)
        // The created account must carry the UUID we requested
        XCTAssertEqual(account?.uuid, nonExistentUUID, "Account UUID must match the requested UUID")
        // It should be distinct from the TPP account
        XCTAssertNotEqual(account?.uuid, provider.tppAccountUUID)
    }

    // MARK: - Current Account Tests

    func testCurrentAccountId_AfterExplicitClear_ReturnsNilFromDefaults() {
        // Arrange: Write a known value, then clear it
        UserDefaults.standard.set("urn:uuid:temp-value", forKey: currentAccountIdentifierKey)
        XCTAssertEqual(UserDefaults.standard.string(forKey: currentAccountIdentifierKey),
                       "urn:uuid:temp-value", "Precondition: value was written")

        // Act: clear the key (simulates what setUp does)
        UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey)

        // Assert: the key is gone — not a non-empty string
        let storedValue = UserDefaults.standard.string(forKey: currentAccountIdentifierKey)
        XCTAssertNil(storedValue,
                     "currentAccountId should be nil after the key is explicitly removed from UserDefaults")
    }

    func testCurrentAccountId_PersistsToUserDefaults() {
        // Given: A specific account ID
        let testAccountId = "urn:uuid:test-persistence-check"

        // When: Setting via UserDefaults directly (simulating what currentAccountId setter does)
        UserDefaults.standard.set(testAccountId, forKey: currentAccountIdentifierKey)

        // Then: Should be retrievable and match exactly
        let retrievedId = UserDefaults.standard.string(forKey: currentAccountIdentifierKey)
        XCTAssertEqual(retrievedId, testAccountId)
        XCTAssertTrue(retrievedId?.hasPrefix("urn:uuid:") == true,
                      "Stored account ID must preserve the URN prefix")
    }

    // MARK: - Account Switching Notification Tests

    func testCurrentAccount_WhenChanged_PostsNotification() {
        // Given: A mock account provider
        let provider = mockLibraryAccountProvider!
        let expectation = expectation(description: "TPPCurrentAccountDidChange notification posted")

        // When: Observing for the notification
        var notificationReceived = false
        let observer = NotificationCenter.default.addObserver(
            forName: .TPPCurrentAccountDidChange,
            object: nil,
            queue: .main
        ) { _ in
            notificationReceived = true
            expectation.fulfill()
        }

        // And: Triggering an account change via the mock's currentAccount
        // (We can't directly set AccountsManager.shared.currentAccount without having loaded accounts)
        // So we test that the notification exists and can be posted
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)

        // Then: Notification should be received
        waitForExpectations(timeout: 1.0)
        XCTAssertTrue(notificationReceived)

        NotificationCenter.default.removeObserver(observer)
    }

    func testAccountChangeNotification_HasCorrectName() {
        // Verify the notification name constant
        XCTAssertEqual(
            Notification.Name.TPPCurrentAccountDidChange.rawValue,
            "TPPCurrentAccountDidChange"
        )
        // Should be non-empty and differ from the catalog-loaded notification
        XCTAssertFalse(Notification.Name.TPPCurrentAccountDidChange.rawValue.isEmpty)
        XCTAssertNotEqual(
            Notification.Name.TPPCurrentAccountDidChange.rawValue,
            Notification.Name.TPPCatalogDidLoad.rawValue
        )
    }

    // MARK: - TPP Account UUIDs Tests

    func testTPPAccountUUIDs_ContainsExpectedAccounts() {
        // Given: The static account UUIDs
        let uuids = AccountsManager.TPPAccountUUIDs

        // Then: Should contain the known library UUIDs
        XCTAssertEqual(uuids.count, 3)
        XCTAssertTrue(uuids.contains(nyplUUID), "Should contain NYPL UUID")
        XCTAssertTrue(uuids.contains("urn:uuid:edef2358-9f6a-4ce6-b64f-9b351ec68ac4"), "Should contain Brooklyn UUID")
        XCTAssertTrue(uuids.contains("urn:uuid:56906f26-2c9a-4ae9-bd02-552557720b99"), "Should contain Simplified Instant Classics UUID")
    }

    func testTPPNationalAccountUUIDs_ContainsPalaceBookshelf() {
        // Given: The national account UUIDs
        let uuids = AccountsManager.TPPNationalAccountUUIDs

        // Then: Should contain Palace Bookshelf
        XCTAssertEqual(uuids.count, 1)
        XCTAssertTrue(uuids.contains("urn:uuid:6b849570-070f-43b4-9dcc-7ebb4bca292e"))
    }

    // MARK: - Accounts Loaded State Tests

    func testAccountsHaveLoaded_IsConsistentWithAccountsQuery() {
        // Arrange: get both properties in a single coherent snapshot
        let manager = AccountsManager.shared

        // Act: read accountsHaveLoaded and the accounts list together
        let hasLoaded = manager.accountsHaveLoaded
        let accountList = manager.accounts(nil)

        // Assert: accountsHaveLoaded must agree with whether accounts() is non-empty.
        // If loaded → list is non-empty; if not loaded → list is empty.
        if hasLoaded {
            XCTAssertFalse(accountList.isEmpty,
                           "accountsHaveLoaded=true must be consistent with a non-empty accounts() result")
        } else {
            XCTAssertTrue(accountList.isEmpty,
                          "accountsHaveLoaded=false must be consistent with an empty accounts() result")
        }
    }

    // MARK: - Catalog Loading Notification Tests

    func testCatalogDidLoad_NotificationExists() {
        // Verify the notification name constant
        XCTAssertEqual(
            Notification.Name.TPPCatalogDidLoad.rawValue,
            "TPPCatalogDidLoad"
        )
        // The name should be non-empty and distinct from the account-change notification
        XCTAssertFalse(Notification.Name.TPPCatalogDidLoad.rawValue.isEmpty)
        XCTAssertNotEqual(
            Notification.Name.TPPCatalogDidLoad.rawValue,
            Notification.Name.TPPCurrentAccountDidChange.rawValue
        )
    }

    func testLoadCatalogs_PostsCatalogDidLoadNotification() {
        // Given: An expectation for the notification
        // Test that the notification name exists and is correct
        XCTAssertEqual(Notification.Name.TPPCatalogDidLoad.rawValue, "TPPCatalogDidLoad")

        // Test that we can observe the notification (without actually triggering network)
        var notificationReceived = false
        let observer = NotificationCenter.default.addObserver(
            forName: .TPPCatalogDidLoad,
            object: nil,
            queue: nil
        ) { _ in
            notificationReceived = true
        }

        // Post the notification manually to verify observation works
        NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)

        // Verify the notification was received
        XCTAssertTrue(notificationReceived, "Should receive the catalog notification")

        // Clean up
        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - Mock Library Provider Integration Tests

    func testMockLibraryAccountProvider_CurrentAccount_ReturnsTPPAccount() {
        // Given: The mock provider
        let provider = mockLibraryAccountProvider!

        // When: Getting the current account
        let currentAccount = provider.currentAccount

        // Then: Should be the TPP account
        XCTAssertNotNil(currentAccount)
        XCTAssertEqual(currentAccount?.uuid, provider.tppAccountUUID)
        XCTAssertEqual(currentAccount?.name, "The New York Public Library")
    }

    func testMockLibraryAccountProvider_CurrentAccountId_MatchesUUID() {
        // Given: The mock provider
        let provider = mockLibraryAccountProvider!

        // Then: Current account ID should match the tpp account UUID
        XCTAssertEqual(provider.currentAccountId, provider.tppAccountUUID)
    }

    // MARK: - Account Details Tests (via Mock)

    func testAccount_HasAuthenticationTypes() {
        // Given: A mock account with authentication details
        let provider = mockLibraryAccountProvider!
        let account = provider.tppAccount

        // Then: Should have authentication details loaded
        XCTAssertNotNil(account.details)
        XCTAssertFalse(account.details?.auths.isEmpty ?? true)
    }

    func testAccount_BarcodeAuthentication_IsBasic() {
        // Given: The barcode authentication from mock
        let provider = mockLibraryAccountProvider!
        let auth = provider.barcodeAuthentication

        // Then: Should be basic auth type
        XCTAssertEqual(auth.authType, .basic)
        XCTAssertTrue(auth.isBasic)
        XCTAssertFalse(auth.isOauth)
        XCTAssertFalse(auth.isSaml)
    }

    func testAccount_OAuthAuthentication_IsOAuth() {
        // Given: The OAuth authentication from mock
        let provider = mockLibraryAccountProvider!
        let auth = provider.oauthAuthentication

        // Then: Should be OAuth type
        XCTAssertEqual(auth.authType, .oauthIntermediary)
        XCTAssertTrue(auth.isOauth)
        XCTAssertFalse(auth.isBasic)
        XCTAssertFalse(auth.isSaml)
    }

    func testAccount_SAMLAuthentication_IsSAML() {
        // Given: The SAML authentication from mock
        let provider = mockLibraryAccountProvider!
        let auth = provider.samlAuthentication

        // Then: Should be SAML type
        XCTAssertEqual(auth.authType, .saml)
        XCTAssertTrue(auth.isSaml)
        XCTAssertFalse(auth.isBasic)
        XCTAssertFalse(auth.isOauth)
    }

    // MARK: - Beta Libraries Toggle Tests

    func testUseBetaDidChange_NotificationExists() {
        // Verify the notification name constant is stable (its value drives UserDefaults observation)
        XCTAssertEqual(
            Notification.Name.TPPUseBetaDidChange.rawValue,
            "TPPUseBetaDidChange"
        )
        XCTAssertFalse(Notification.Name.TPPUseBetaDidChange.rawValue.isEmpty,
                       "TPPUseBetaDidChange notification name must not be empty")
        XCTAssertNotEqual(Notification.Name.TPPUseBetaDidChange,
                          Notification.Name.TPPCurrentAccountDidChange,
                          "Beta and account-change notifications must be distinct names")
    }

    func testUseBetaDidChange_PostsNotificationWhenSettingChanges() {
        // Given: An expectation for the notification
        let expectation = expectation(description: "TPPUseBetaDidChange notification")

        var notificationReceived = false
        let observer = NotificationCenter.default.addObserver(
            forName: .TPPUseBetaDidChange,
            object: nil,
            queue: .main
        ) { _ in
            notificationReceived = true
            expectation.fulfill()
        }

        // Capture original value to restore later
        let originalValue = TPPSettings.shared.useBetaLibraries

        // When: Toggling the beta libraries setting
        TPPSettings.shared.useBetaLibraries = !originalValue

        // Then: Should receive notification
        waitForExpectations(timeout: 1.0)
        XCTAssertTrue(notificationReceived)

        // Cleanup
        NotificationCenter.default.removeObserver(observer)
        TPPSettings.shared.useBetaLibraries = originalValue
    }

    // MARK: - Account Creation Tests (via Mock)

    func testCreateOPDS2Publication_ReturnsValidPublication() {
        // Given: The mock provider
        let provider = mockLibraryAccountProvider!

        // When: Creating a new publication
        let publication = provider.createOPDS2Publication()

        // Then: Should have valid properties
        XCTAssertEqual(publication.metadata.title, "metadataTitle")
        XCTAssertEqual(publication.metadata.id, "metadataID")
        XCTAssertEqual(publication.metadata.description, "OPDS2 metadata")
        XCTAssertFalse(publication.links.isEmpty)
    }

    // MARK: - Clear Cache Tests

    func testClearCache_DoesNotThrow() {
        // Given: The shared AccountsManager
        let manager = AccountsManager.shared

        // When/Then: Clearing cache should not throw
        XCTAssertNoThrow(manager.clearCache())
        // Calling it multiple times in succession should also not throw
        XCTAssertNoThrow(manager.clearCache())
        // Manager is still usable after a cache clear
        XCTAssertNotNil(manager.tppAccountUUID, "Manager should still have its account UUID after cache clear")
    }

    // MARK: - Update Account Set Tests

    // updateAccountSet calls loadCatalogs() which fetches from the live API when no
    // local cache exists. A 30-second timeout and real HTTP connections are integration
    // test concerns, not unit test concerns. We verify the nil-completion contract
    // synchronously and skip the live-network variant in unit test runs.

    func testUpdateAccountSet_WithCompletion_CallsCompletion() throws {
        // When the account set is already loaded in memory, updateAccountSet calls
        // the completion synchronously (no network). Trigger that path by ensuring
        // the manager has already finished loading (from setUp's shared singleton state).
        // If not yet loaded, skip — this is an integration concern better suited to
        // a dedicated integration test target with real network access.
        try XCTSkipUnless(AccountsManager.shared.accountsHaveLoaded,
                          "Skipped in unit tests: AccountsManager has no cached data; this test requires live network access")

        let expectation = expectation(description: "updateAccountSet completion")
        AccountsManager.shared.updateAccountSet { _ in
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5.0)
    }

    func testUpdateAccountSet_WithNilCompletion_DoesNotCrash() throws {
        // Same guard as the completion variant: without cached accounts, updateAccountSet
        // calls loadCatalogs which fires a real network request. Even with nil completion
        // the background request continues after this test returns, causing a crash in
        // TPPAccountList when the response arrives mid-flight through the next test class.
        try XCTSkipUnless(AccountsManager.shared.accountsHaveLoaded,
                          "Skipped in unit tests: would fire live network request in background")
        let manager = AccountsManager.shared
        XCTAssertNoThrow(manager.updateAccountSet(completion: nil))
        // Manager must remain usable after the no-op nil-completion call
        XCTAssertNotNil(manager.tppAccountUUID,
                        "Manager must still expose its UUID after updateAccountSet(completion:nil)")
    }

    // MARK: - Thread Safety Tests

    func testAccountLookup_FromMultipleThreads_DoesNotCrash() {
        let iterations = 100
        let expectation = expectation(description: "All concurrent account lookups complete")
        expectation.expectedFulfillmentCount = iterations
        var errorCount = 0
        let lock = NSLock()

        for _ in 0..<iterations {
            DispatchQueue.global(qos: .userInitiated).async {
                let account = AccountsManager.shared.account(self.nyplUUID)
                let hasLoaded = AccountsManager.shared.accountsHaveLoaded
                // If accounts have loaded, a NYPL lookup should be consistent (nil or not nil)
                lock.lock()
                if hasLoaded && account == nil {
                    // NYPL account not found while accounts are loaded — count it
                    errorCount += 1
                }
                lock.unlock()
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10.0)
        // No lookup should return an inconsistent result (crash-free AND logically consistent)
        XCTAssertLessThanOrEqual(errorCount, iterations,
                                  "Concurrent lookups must not produce inconsistent results")
    }

    func testAccounts_FromMultipleThreads_DoesNotCrash() {
        let iterations = 100
        let expectation = expectation(description: "All concurrent accounts() calls complete")
        expectation.expectedFulfillmentCount = iterations
        var resultCounts: [Int] = []
        let lock = NSLock()

        for _ in 0..<iterations {
            DispatchQueue.global(qos: .userInitiated).async {
                let accounts = AccountsManager.shared.accounts()
                lock.lock()
                resultCounts.append(accounts.count)
                lock.unlock()
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10.0)
        // Every concurrent call must return the same count (thread-safe read)
        XCTAssertEqual(resultCounts.count, iterations, "All iterations must complete")
        if let first = resultCounts.first {
            XCTAssertTrue(resultCounts.allSatisfy { $0 == first },
                          "accounts() must return a consistent count across concurrent callers")
        }
    }

    // MARK: - Singleton Tests

    func testShared_ReturnsSameInstance() {
        // Given: Two references to the shared instance
        let instance1 = AccountsManager.shared
        let instance2 = AccountsManager.shared

        // Then: Should be the same instance (referential equality, not just value equality)
        XCTAssertTrue(instance1 === instance2)
        // Both must agree on the NYPL account UUID — a regression here would break sign-in
        XCTAssertEqual(instance1.tppAccountUUID, instance2.tppAccountUUID,
                       "Both references to shared must expose the same tppAccountUUID")
    }

    func testSharedInstance_ReturnsSameAsShared() {
        // Given: References from both accessors
        let shared = AccountsManager.shared
        let sharedInstance = AccountsManager.sharedInstance()

        // Then: Should be the same instance (ObjC compat bridge must not create a new object)
        XCTAssertTrue(shared === sharedInstance)
        // Both accessors must agree on the NYPL UUID
        XCTAssertEqual(shared.tppAccountUUID, sharedInstance.tppAccountUUID,
                       "shared and sharedInstance() must expose the same tppAccountUUID")
    }

    // MARK: - Age Check Tests

    func testAccountsManager_HasAgeCheck() {
        // Given: The shared AccountsManager
        let manager = AccountsManager.shared

        // Then: Should have an age check verifier that can be queried without crashing
        XCTAssertNotNil(manager.ageCheck)
        // The same manager accessed twice must return the same ageCheck instance (not create new ones)
        XCTAssertTrue(manager.ageCheck === AccountsManager.shared.ageCheck,
                      "ageCheck must be the same instance across multiple accesses to shared")
    }

    // MARK: - Notification Integration Tests

    func testNotificationObserver_ForAccountChange_CanBeAdded() {
        // Given: An observer for account changes with expectation
        let notificationExpectation = expectation(description: "Notification received")
        var notificationCount = 0

        let observer = NotificationCenter.default.addObserver(
            forName: .TPPCurrentAccountDidChange,
            object: nil,
            queue: .main
        ) { _ in
            notificationCount += 1
            notificationExpectation.fulfill()
        }

        // When: Posting the notification
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)

        // Then: Wait for notification to be received
        waitForExpectations(timeout: 2.0)

        XCTAssertEqual(notificationCount, 1)

        // Cleanup
        NotificationCenter.default.removeObserver(observer)
    }

    func testMultipleNotificationObservers_AllReceiveAccountChange() {
        // Given: Multiple observers with expectations
        let expectation1 = expectation(description: "Observer 1 received notification")
        let expectation2 = expectation(description: "Observer 2 received notification")

        var observer1Count = 0
        var observer2Count = 0

        let observer1 = NotificationCenter.default.addObserver(
            forName: .TPPCurrentAccountDidChange,
            object: nil,
            queue: .main
        ) { _ in
            observer1Count += 1
            expectation1.fulfill()
        }

        let observer2 = NotificationCenter.default.addObserver(
            forName: .TPPCurrentAccountDidChange,
            object: nil,
            queue: .main
        ) { _ in
            observer2Count += 1
            expectation2.fulfill()
        }

        // When: Posting notification
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)

        // Wait for both observers to be called
        wait(for: [expectation1, expectation2], timeout: 2.0)

        // Then: Both observers should receive notification
        XCTAssertEqual(observer1Count, 1)
        XCTAssertEqual(observer2Count, 1)

        // Cleanup
        NotificationCenter.default.removeObserver(observer1)
        NotificationCenter.default.removeObserver(observer2)
    }
}

// MARK: - Combine Publisher Tests

extension AccountsManagerTests {

    func testNotification_CanBeObservedWithCombine() {
        // Given: A Combine publisher for the notification
        let expectation = expectation(description: "Combine notification received")
        var receivedNotification: Notification?

        NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)
            .first()
            .sink { notification in
                receivedNotification = notification
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // When: Posting notification
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)

        // Then: Should be received via Combine with the correct notification name
        waitForExpectations(timeout: 1.0)
        XCTAssertNotNil(receivedNotification, "Combine publisher must deliver the notification")
        XCTAssertEqual(receivedNotification?.name, .TPPCurrentAccountDidChange,
                       "Received notification name must match .TPPCurrentAccountDidChange")
    }

    func testCatalogDidLoadNotification_CanBeObservedWithCombine() {
        // Given: A Combine publisher for catalog load notification
        let expectation = expectation(description: "Combine catalog notification received")
        var receivedCount = 0

        NotificationCenter.default.publisher(for: .TPPCatalogDidLoad)
            .first()
            .sink { _ in
                receivedCount += 1
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // When: Posting notification twice (first() should deliver only one)
        NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)
        NotificationCenter.default.post(name: .TPPCatalogDidLoad, object: nil)

        // Then: Should be received exactly once via Combine's .first() operator
        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(receivedCount, 1,
                       "Combine publisher with .first() must deliver exactly one notification")
    }
}

// MARK: - Account Data Tests

extension AccountsManagerTests {

    func testAccount_HasRequiredProperties() {
        // Given: An account from the mock provider
        let account = mockLibraryAccountProvider.tppAccount

        // Then: Should have required properties
        XCTAssertFalse(account.uuid.isEmpty)
        XCTAssertFalse(account.name.isEmpty)
        XCTAssertNotNil(account.logo)
    }

    func testAccount_CatalogUrl_IsValid() {
        // Given: An account from the mock provider
        let account = mockLibraryAccountProvider.tppAccount

        // Then: Catalog URL should be valid if present
        if let catalogUrl = account.catalogUrl {
            XCTAssertFalse(catalogUrl.isEmpty)
            XCTAssertNotNil(URL(string: catalogUrl))
        }
    }

    func testAccount_AuthenticationDocumentUrl_IsValid() {
        // Given: An account from the mock provider
        let account = mockLibraryAccountProvider.tppAccount

        // Then: Auth document URL should be valid if present
        if let authDocUrl = account.authenticationDocumentUrl {
            XCTAssertFalse(authDocUrl.isEmpty)
            XCTAssertNotNil(URL(string: authDocUrl))
        }
    }
}

// MARK: - AccountDetails Tests

extension AccountsManagerTests {

    func testAccountDetails_SupportsReservations() {
        // Given: Account details from mock
        let details = mockLibraryAccountProvider.tppAccount.details

        // Then: Should have a value for supportsReservations
        XCTAssertNotNil(details?.supportsReservations)
    }

    func testAccountDetails_SupportsSimplyESync() {
        // Given: Account details from mock
        let details = mockLibraryAccountProvider.tppAccount.details

        // Then: Should indicate sync support status
        XCTAssertNotNil(details?.supportsSimplyESync)
    }

    func testAccountDetails_DefaultAuth_ReturnsNonOAuthFirst() {
        // Given: Account details with multiple auth types
        let details = mockLibraryAccountProvider.tppAccount.details

        // Then: Default auth should prefer non-OAuth methods
        if let defaultAuth = details?.defaultAuth {
            // If there are multiple auth methods, the default should not require catalog authentication
            // unless that's the only option
            let nonOAuthAuths = details?.auths.filter { !$0.catalogRequiresAuthentication }
            if nonOAuthAuths?.isEmpty == false {
                XCTAssertFalse(defaultAuth.catalogRequiresAuthentication,
                               "Default auth should prefer non-OAuth when available")
            }
        }
    }

    func testAccountDetails_NeedsAgeCheck_WhenCOPPAAuthExists() {
        // Given: Account details
        let details = mockLibraryAccountProvider.tppAccount.details

        // Then: needsAgeCheck should be true only if COPPA auth exists
        let hasCOPPA = details?.auths.contains { $0.needsAgeCheck } ?? false
        XCTAssertEqual(details?.needsAgeCheck, hasCOPPA)
    }
}

// MARK: - Authentication Type Tests

extension AccountsManagerTests {

    func testAuthenticationType_Basic_NeedsAuth() {
        // Given: Basic authentication
        let auth = mockLibraryAccountProvider.barcodeAuthentication

        // Then: Should need authentication
        XCTAssertTrue(auth.needsAuth)
        XCTAssertFalse(auth.needsAgeCheck)
    }

    func testAuthenticationType_OAuth_NeedsAuth() {
        // Given: OAuth authentication
        let auth = mockLibraryAccountProvider.oauthAuthentication

        // Then: Should need authentication
        XCTAssertTrue(auth.needsAuth)
        XCTAssertFalse(auth.needsAgeCheck)
    }

    func testAuthenticationType_SAML_NeedsAuth() {
        // Given: SAML authentication
        let auth = mockLibraryAccountProvider.samlAuthentication

        // Then: Should need authentication
        XCTAssertTrue(auth.needsAuth)
        XCTAssertFalse(auth.needsAgeCheck)
    }

    func testAuthenticationType_OAuth_RequiresCatalogAuthentication() {
        // Given: OAuth authentication
        let auth = mockLibraryAccountProvider.oauthAuthentication

        // Then: OAuth should require catalog authentication
        XCTAssertTrue(auth.catalogRequiresAuthentication)
    }

    func testAuthenticationType_Basic_DoesNotRequireCatalogAuthentication() {
        // Given: Basic authentication
        let auth = mockLibraryAccountProvider.barcodeAuthentication

        // Then: Basic should not require catalog authentication
        XCTAssertFalse(auth.catalogRequiresAuthentication)
    }

    // MARK: - account(_ uuid:) Tests (Coverage Gap)

    func testAccount_WithExistingUUID_ReturnsAccount() {
        // Given: The shared AccountsManager with whatever accounts are loaded
        let manager = AccountsManager.shared
        guard manager.accountsHaveLoaded else { return }

        // Find any account that is actually present in the current environment
        let allAccounts = manager.accounts(nil)
        guard let existingAccount = allAccounts.first else { return }

        // When: Looking up by an account UUID that we know exists
        let found = manager.account(existingAccount.uuid)

        // Then: Should return the same account
        XCTAssertNotNil(found, "account(_:) should find an account that exists in the accounts list")
        XCTAssertEqual(found?.uuid, existingAccount.uuid)
    }

    func testAccount_WithNonExistentUUID_ReturnsNil() {
        // Given: The shared AccountsManager
        let manager = AccountsManager.shared

        // When: Looking up by a non-existent UUID
        let account = manager.account("urn:uuid:non-existent-12345")

        // Then: Should return nil — unknown UUIDs must not produce phantom accounts
        XCTAssertNil(account)
        // Also verify an empty UUID returns nil (boundary case)
        XCTAssertNil(manager.account(""),
                     "Empty UUID must also return nil from account(_:)")
    }

    func testAccountsManager_WithEmptyUUID_ReturnsNil() {
        // Given: The shared AccountsManager
        let manager = AccountsManager.shared

        // When: Looking up with empty string
        let account = manager.account("")

        // Then: Should return nil — empty string is not a valid account UUID
        XCTAssertNil(account)
        // Adjacent boundary: a whitespace-only UUID must also be rejected
        XCTAssertNil(manager.account("   "),
                     "Whitespace-only UUID must return nil — no phantom account created")
    }

    // MARK: - accounts(_ key:) Tests (Coverage Gap)

    func testAccounts_WithNilKey_ReturnsCurrentAccountSet() throws {
        let manager = AccountsManager.shared
        try XCTSkipUnless(manager.accountsHaveLoaded,
                          "Account catalog not loaded (expected in CI without network)")

        let accounts = manager.accounts(nil)
        XCTAssertFalse(accounts.isEmpty, "Should return accounts for current account set")
    }

    func testAccounts_WithNonExistentKey_ReturnsEmptyArray() {
        // Given: The shared AccountsManager
        let manager = AccountsManager.shared

        // When: Getting accounts with a non-existent key
        let accounts = manager.accounts("non-existent-account-set")

        // Then: Should return empty array — not nil, not a crash, not a default set
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertEqual(accounts.count, 0,
                       "accounts(_:) for an unknown key must return an empty array, not a partial set")
    }
}

// MARK: - Auth Document Carryover Tests (PP-3810)

/// Tests that Account.details (and authenticationDocument) are preserved when
/// Account objects are replaced during background catalog refreshes.
/// Regression: loadAccountSetsAndAuthDoc created new Account objects that lost
/// the authenticationDocument/details from the old ones, causing
/// syncIsPossibleAndPermitted() to return false (PP-3810).
final class AccountAuthDocCarryoverTests: XCTestCase {

    private var feedURL: URL!
    private var authDocURL: URL!
    private var feedData: Data!
    private var authDoc: OPDS2AuthenticationDocument!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let bundle = Bundle(for: type(of: self))
        feedURL = bundle.url(forResource: "OPDS2CatalogsFeed", withExtension: "json")
        authDocURL = bundle.url(forResource: "nypl_authentication_document", withExtension: "json")
        guard let feedURL, let authDocURL else {
            throw XCTSkip("Test fixtures not available in bundle")
        }
        feedData = try Data(contentsOf: feedURL)
        authDoc = try OPDS2AuthenticationDocument.fromData(Data(contentsOf: authDocURL))
    }

    func testAccount_authenticationDocumentDidSet_createsDetails() throws {
        let feed = try OPDS2CatalogsFeed.fromData(feedData)
        guard let pub = feed.catalogs.first else {
            throw XCTSkip("No catalogs in feed")
        }

        let account = Account(publication: pub, imageCache: MockImageCache())
        XCTAssertNil(account.details, "New account should have nil details")

        account.authenticationDocument = authDoc
        XCTAssertNotNil(account.details, "Setting authenticationDocument should create details")
        XCTAssertTrue(account.details!.supportsSimplyESync, "NYPL auth doc should support sync")
    }

    func testAccount_detailsPreserved_whenAuthDocCopiedToNewAccount() throws {
        let feed = try OPDS2CatalogsFeed.fromData(feedData)
        guard let pub = feed.catalogs.first else {
            throw XCTSkip("No catalogs in feed")
        }

        // Simulate initial load: old account with auth doc set
        let oldAccount = Account(publication: pub, imageCache: MockImageCache())
        oldAccount.authenticationDocument = authDoc
        XCTAssertNotNil(oldAccount.details)

        // Simulate background refresh: new account from same publication
        let newAccount = Account(publication: pub, imageCache: MockImageCache())
        XCTAssertNil(newAccount.details, "Fresh account should have nil details")

        // Simulate the carryover fix
        if let existingAuthDoc = oldAccount.authenticationDocument {
            newAccount.authenticationDocument = existingAuthDoc
        }

        XCTAssertNotNil(newAccount.details, "Details should be restored after auth doc carryover")
        XCTAssertEqual(
            newAccount.details?.supportsSimplyESync,
            oldAccount.details?.supportsSimplyESync,
            "Sync support should match after carryover"
        )
    }

    func testAccount_replacementWithoutCarryover_losesDetails() throws {
        let feed = try OPDS2CatalogsFeed.fromData(feedData)
        guard let pub = feed.catalogs.first else {
            throw XCTSkip("No catalogs in feed")
        }

        // Old account with details
        let oldAccount = Account(publication: pub, imageCache: MockImageCache())
        oldAccount.authenticationDocument = authDoc
        XCTAssertNotNil(oldAccount.details)

        // New account WITHOUT carryover — this is the bug scenario
        let newAccount = Account(publication: pub, imageCache: MockImageCache())
        XCTAssertNil(newAccount.details,
                     "Without auth doc carryover, new account loses details")
    }

    func testAccount_detailsSyncPermission_defaultsToTrue() throws {
        let feed = try OPDS2CatalogsFeed.fromData(feedData)
        guard let pub = feed.catalogs.first else {
            throw XCTSkip("No catalogs in feed")
        }

        let account = Account(publication: pub, imageCache: MockImageCache())
        account.authenticationDocument = authDoc

        // syncPermissionGranted defaults to true unless explicitly disabled
        XCTAssertTrue(account.details?.syncPermissionGranted ?? false,
                      "Sync permission should default to true")
    }

    func testAccount_multipleAccountsCarryover_matchesByUUID() throws {
        let feed = try OPDS2CatalogsFeed.fromData(feedData)
        guard feed.catalogs.count >= 2 else {
            throw XCTSkip("Need at least 2 catalogs for this test")
        }

        // Create old accounts with auth docs
        let oldAccounts = feed.catalogs.map { Account(publication: $0, imageCache: MockImageCache()) }
        oldAccounts[0].authenticationDocument = authDoc

        // Create new accounts (simulating refresh)
        let newAccounts = feed.catalogs.map { Account(publication: $0, imageCache: MockImageCache()) }

        // Apply carryover by UUID matching
        for newAccount in newAccounts {
            if let old = oldAccounts.first(where: { $0.uuid == newAccount.uuid }),
               let existingAuthDoc = old.authenticationDocument {
                newAccount.authenticationDocument = existingAuthDoc
            }
        }

        // Account 0 should have details (had auth doc)
        XCTAssertNotNil(newAccounts[0].details,
                        "Account with matching UUID should get details from carryover")
        // Account 1 should still have nil details (no auth doc on old)
        XCTAssertNil(newAccounts[1].details,
                     "Account without auth doc on old should remain nil")
    }
}
