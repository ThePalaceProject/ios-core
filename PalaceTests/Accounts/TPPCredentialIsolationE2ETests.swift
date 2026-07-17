import XCTest
@testable import Palace

/// End-to-end credential isolation tests simulating the full user journey:
/// sign in to Library A → switch to Library B → sign in to B → verify A intact.
/// Extends the unit-level isolation tests in TPPPerAccountIsolationTests.
@MainActor
final class TPPCredentialIsolationE2ETests: XCTestCase {

    private let uuidA = "urn:uuid:e2e-isolation-library-a"
    private let uuidB = "urn:uuid:e2e-isolation-library-b"
    private let uuidC = "urn:uuid:e2e-isolation-library-c"

    override func setUpWithError() throws {
        try super.setUpWithError()
        // E2E sign-in scenarios round-trip credentials through the keychain.
        // Skip on CI hosts where SecItem returns -34018.
        try KeychainAvailability.skipIfUnavailable()
    }

    override func tearDown() {
        AppContainer.production().accountsManager.userAccount(for: uuidA).removeAll()
        AppContainer.production().accountsManager.userAccount(for: uuidB).removeAll()
        AppContainer.production().accountsManager.userAccount(for: uuidC).removeAll()
        super.tearDown()
    }

    // MARK: - Full Journey: Sign In A → Switch B → Sign In B → Verify A

    func testSignInA_switchToB_signInB_verifyAIntact() {
        let accountA = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let accountB = AppContainer.production().accountsManager.userAccount(for: uuidB)

        // Step 1: Sign in to Library A
        accountA.setBarcode("patron-a-barcode", PIN: "patron-a-pin")
        accountA.markLoggedIn()
        XCTAssertTrue(accountA.hasCredentials())
        XCTAssertEqual(accountA.authState, .loggedIn)

        // Step 2: "Switch" to Library B (in the real app this changes currentAccountId)
        // Step 3: Sign in to Library B with different credentials
        accountB.setBarcode("patron-b-barcode", PIN: "patron-b-pin")
        accountB.markLoggedIn()
        XCTAssertTrue(accountB.hasCredentials())
        XCTAssertEqual(accountB.authState, .loggedIn)

        // Step 4: Verify Library A credentials are completely untouched
        XCTAssertEqual(accountA.barcode, "patron-a-barcode")
        XCTAssertEqual(accountA.PIN, "patron-a-pin")
        XCTAssertEqual(accountA.authState, .loggedIn)
        XCTAssertTrue(accountA.hasCredentials())

        // Verify snapshots are independent
        let snapA = accountA.credentialSnapshot()
        let snapB = accountB.credentialSnapshot()
        XCTAssertEqual(snapA.barcode, "patron-a-barcode")
        XCTAssertEqual(snapB.barcode, "patron-b-barcode")
        XCTAssertNotEqual(snapA.barcode, snapB.barcode)
    }

    // MARK: - Sign In A → Switch B → Sign In B → Sign Out B → Verify A

    func testSignInA_switchB_signInB_signOutB_verifyAIntact() {
        let accountA = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let accountB = AppContainer.production().accountsManager.userAccount(for: uuidB)

        // Sign in to A
        accountA.setBarcode("keep-me", PIN: "keep-pin")
        accountA.markLoggedIn()

        // Sign in to B
        accountB.setBarcode("remove-me", PIN: "remove-pin")
        accountB.markLoggedIn()

        // Sign out of B (simulates tapping Sign Out)
        accountB.removeAll()

        // B should be clean
        XCTAssertFalse(accountB.hasCredentials())
        XCTAssertNil(accountB.barcode)

        // A should be completely untouched
        XCTAssertEqual(accountA.barcode, "keep-me")
        XCTAssertEqual(accountA.PIN, "keep-pin")
        XCTAssertTrue(accountA.hasCredentials())
        XCTAssertEqual(accountA.authState, .loggedIn)
    }

    // MARK: - Three Libraries Simultaneously

    func testThreeLibraries_allIsolated() {
        let accountA = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let accountB = AppContainer.production().accountsManager.userAccount(for: uuidB)
        let accountC = AppContainer.production().accountsManager.userAccount(for: uuidC)

        accountA.setBarcode("barcode-a", PIN: "pin-a")
        accountA.markLoggedIn()

        accountB.setAuthToken("token-b", barcode: "barcode-b", pin: "pin-b", expirationDate: nil)
        accountB.markLoggedIn()

        accountC.setBarcode("barcode-c", PIN: "pin-c")
        accountC.markLoggedIn()

        // All three have independent credentials
        XCTAssertEqual(accountA.barcode, "barcode-a")
        XCTAssertNil(accountA.authToken)

        XCTAssertEqual(accountB.barcode, "barcode-b")
        XCTAssertEqual(accountB.authToken, "token-b")

        XCTAssertEqual(accountC.barcode, "barcode-c")
        XCTAssertNil(accountC.authToken)

        // Sign out of B — A and C unaffected
        accountB.removeAll()

        XCTAssertTrue(accountA.hasCredentials())
        XCTAssertFalse(accountB.hasCredentials())
        XCTAssertTrue(accountC.hasCredentials())
    }

    // MARK: - Credential State Transitions Don't Leak

    func testMarkCredentialsStale_doesNotAffectOtherAccount() {
        let accountA = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let accountB = AppContainer.production().accountsManager.userAccount(for: uuidB)

        accountA.setBarcode("a", PIN: "a")
        accountA.markLoggedIn()
        accountB.setBarcode("b", PIN: "b")
        accountB.markLoggedIn()

        // Mark A as stale (simulates 401 from server)
        accountA.markCredentialsStale()

        XCTAssertEqual(accountA.authState, .credentialsStale)
        XCTAssertEqual(accountB.authState, .loggedIn, "B's auth state should not change when A is marked stale")
    }

    // MARK: - Rapid Account Switching Under Concurrency

    func testRapidSwitching_500Iterations_noContamination() {
        let accountA = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let accountB = AppContainer.production().accountsManager.userAccount(for: uuidB)
        let iterations = 500
        let expectation = expectation(description: "rapid switching")
        expectation.expectedFulfillmentCount = iterations * 2

        for i in 0..<iterations {
            DispatchQueue.global().async {
                accountA.setBarcode("a-\(i)", PIN: "pa-\(i)")
                expectation.fulfill()
            }
            DispatchQueue.global().async {
                accountB.setBarcode("b-\(i)", PIN: "pb-\(i)")
                expectation.fulfill()
            }
        }

        // 500 concurrent writes per account × 2 accounts = 1000 fulfillments. The
        // writes are synchronous Keychain ops on a global queue; 5s is generous
        // even on a heavily loaded CI runner. The legacy 30s was timeout-as-padding.
        wait(for: [expectation], timeout: 5)

        let finalA = accountA.barcode ?? ""
        let finalB = accountB.barcode ?? ""
        XCTAssertTrue(finalA.hasPrefix("a-"), "Account A contaminated: \(finalA)")
        XCTAssertTrue(finalB.hasPrefix("b-"), "Account B contaminated: \(finalB)")
    }
}
