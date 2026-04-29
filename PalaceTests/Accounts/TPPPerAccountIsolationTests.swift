import XCTest
@testable import Palace

/// Tests that per-account TPPUserAccount instances are fully isolated.
/// These validate the systemic fix for F-034 (credential cross-contamination).
final class TPPPerAccountIsolationTests: XCTestCase {

    private let uuidA = "urn:uuid:isolation-test-library-a"
    private let uuidB = "urn:uuid:isolation-test-library-b"

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Every test in this class writes via TPPUserAccount → TPPKeychain.
        // On CI simulator runners the keychain returns -34018
        // errSecMissingEntitlement; without a real keychain the writes silently
        // drop and every read returns nil. Skip rather than report false
        // failures — the same env-gate pattern used by TPPKeychainTests +
        // TPPKeychainSwiftTests via KeychainAvailability.
        try KeychainAvailability.skipIfUnavailable()
    }

    override func tearDown() {
        // Clean up any keychain data written during tests
        AppContainer.production().accountsManager.userAccount(for: uuidA).removeAll()
        AppContainer.production().accountsManager.userAccount(for: uuidB).removeAll()
        super.tearDown()
    }

    // MARK: - Instance Identity

    /// userAccount(for:) returns the same instance on repeated calls.
    func testInstanceCache_returnsSameInstance() {
        let first = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let second = AppContainer.production().accountsManager.userAccount(for: uuidA)
        XCTAssertTrue(first === second, "Same UUID should return same instance")
    }

    /// Different UUIDs return different instances.
    func testInstanceCache_returnsDifferentInstancesForDifferentUUIDs() {
        let accountA = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let accountB = AppContainer.production().accountsManager.userAccount(for: uuidB)
        XCTAssertFalse(accountA === accountB, "Different UUIDs should return different instances")
    }

    /// Per-account instances have immutable boundLibraryUUID.
    func testBoundLibraryUUID_isImmutable() {
        let account = AppContainer.production().accountsManager.userAccount(for: uuidA)
        XCTAssertEqual(account.boundLibraryUUID, uuidA)
    }

    // MARK: - Credential Isolation

    /// Writing credentials to Account A does not affect Account B.
    func testCredentialIsolation_writeToA_doesNotAffectB() {
        let accountA = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let accountB = AppContainer.production().accountsManager.userAccount(for: uuidB)

        accountA.setBarcode("barcodeA", PIN: "pinA")
        accountA.markLoggedIn()

        XCTAssertEqual(accountA.barcode, "barcodeA")
        XCTAssertEqual(accountA.PIN, "pinA")
        XCTAssertTrue(accountA.hasCredentials())

        // Account B should have no credentials
        XCTAssertNil(accountB.barcode)
        XCTAssertNil(accountB.PIN)
        XCTAssertFalse(accountB.hasCredentials())
    }

    /// Both accounts can hold independent credentials simultaneously.
    func testCredentialIsolation_bothAccountsHoldIndependentCredentials() {
        let accountA = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let accountB = AppContainer.production().accountsManager.userAccount(for: uuidB)

        accountA.setBarcode("barcodeA", PIN: "pinA")
        accountB.setBarcode("barcodeB", PIN: "pinB")

        XCTAssertEqual(accountA.barcode, "barcodeA")
        XCTAssertEqual(accountA.PIN, "pinA")
        XCTAssertEqual(accountB.barcode, "barcodeB")
        XCTAssertEqual(accountB.PIN, "pinB")
    }

    /// Token credentials are isolated between accounts.
    func testCredentialIsolation_tokenCredentials() {
        let accountA = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let accountB = AppContainer.production().accountsManager.userAccount(for: uuidB)

        accountA.setAuthToken("tokenA", barcode: "userA", pin: "passA", expirationDate: nil)
        accountB.setAuthToken("tokenB", barcode: "userB", pin: "passB", expirationDate: nil)

        XCTAssertEqual(accountA.authToken, "tokenA")
        XCTAssertEqual(accountA.barcode, "userA")
        XCTAssertEqual(accountB.authToken, "tokenB")
        XCTAssertEqual(accountB.barcode, "userB")
    }

    /// credentialSnapshot() returns correct data for each account.
    func testCredentialSnapshot_perAccountIsolation() {
        let accountA = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let accountB = AppContainer.production().accountsManager.userAccount(for: uuidB)

        accountA.setBarcode("snapA", PIN: "pinSnapA")
        accountA.markLoggedIn()
        accountB.setBarcode("snapB", PIN: "pinSnapB")
        accountB.markLoggedIn()

        let snapA = accountA.credentialSnapshot()
        let snapB = accountB.credentialSnapshot()

        XCTAssertEqual(snapA.barcode, "snapA")
        XCTAssertEqual(snapA.pin, "pinSnapA")
        XCTAssertEqual(snapB.barcode, "snapB")
        XCTAssertEqual(snapB.pin, "pinSnapB")
    }

    /// removeAll() on one account does not affect the other.
    func testRemoveAll_doesNotAffectOtherAccount() {
        let accountA = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let accountB = AppContainer.production().accountsManager.userAccount(for: uuidB)

        accountA.setBarcode("keepMe", PIN: "keepPin")
        accountB.setBarcode("removeMe", PIN: "removePin")

        accountB.removeAll()

        XCTAssertEqual(accountA.barcode, "keepMe")
        XCTAssertTrue(accountA.hasCredentials())
        XCTAssertFalse(accountB.hasCredentials())
    }

    // MARK: - Concurrent Access

    /// Concurrent reads/writes to different accounts do not cross-contaminate.
    func testConcurrentAccess_noContamination() {
        let accountA = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let accountB = AppContainer.production().accountsManager.userAccount(for: uuidB)
        let iterations = 100
        let expectation = expectation(description: "concurrent access")
        expectation.expectedFulfillmentCount = iterations * 2

        // Write to A and B concurrently
        for i in 0..<iterations {
            DispatchQueue.global().async {
                accountA.setBarcode("barcodeA_\(i)", PIN: "pinA_\(i)")
                expectation.fulfill()
            }
            DispatchQueue.global().async {
                accountB.setBarcode("barcodeB_\(i)", PIN: "pinB_\(i)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10)

        // After all writes, A's barcode should start with "barcodeA_"
        // and B's should start with "barcodeB_" — never crossed
        let finalA = accountA.barcode ?? ""
        let finalB = accountB.barcode ?? ""
        XCTAssertTrue(finalA.hasPrefix("barcodeA_"), "Account A barcode contaminated: \(finalA)")
        XCTAssertTrue(finalB.hasPrefix("barcodeB_"), "Account B barcode contaminated: \(finalB)")
    }

    /// Concurrent credentialSnapshot() calls on different accounts return correct data.
    func testConcurrentSnapshots_returnCorrectData() {
        let accountA = AppContainer.production().accountsManager.userAccount(for: uuidA)
        let accountB = AppContainer.production().accountsManager.userAccount(for: uuidB)

        accountA.setBarcode("concurrentA", PIN: "pinA")
        accountA.markLoggedIn()
        accountB.setBarcode("concurrentB", PIN: "pinB")
        accountB.markLoggedIn()

        // Reduced from 200 to 20 — keychain operations are slow on simulator
        // and 400 concurrent SecItem calls can deadlock the keychain daemon.
        let iterations = 20
        let expectation = expectation(description: "concurrent snapshots")
        expectation.expectedFulfillmentCount = iterations * 2
        var failures = [String]()
        let failureLock = NSLock()

        for _ in 0..<iterations {
            DispatchQueue.global().async {
                let snap = accountA.credentialSnapshot()
                if snap.barcode != "concurrentA" {
                    failureLock.lock()
                    failures.append("A got barcode: \(snap.barcode ?? "nil")")
                    failureLock.unlock()
                }
                expectation.fulfill()
            }
            DispatchQueue.global().async {
                let snap = accountB.credentialSnapshot()
                if snap.barcode != "concurrentB" {
                    failureLock.lock()
                    failures.append("B got barcode: \(snap.barcode ?? "nil")")
                    failureLock.unlock()
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10)
        XCTAssertTrue(failures.isEmpty, "Credential contamination detected: \(failures)")
    }
}
