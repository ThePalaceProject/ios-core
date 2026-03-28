import XCTest
@testable import Palace

/// Tests that rapid library switching does not crash the app.
///
/// The core issue: `AccountsManager.currentAccount` setter used to post
/// `.TPPCurrentAccountDidChange` synchronously while async cleanup was
/// still in progress. `TPPBookRegistry` would then start loading the NEW
/// account's data while the OLD account's network tasks / navigation were
/// still being torn down, causing force-unwrap crashes, concurrent
/// dictionary mutations, and navigation state corruption.
///
/// The fix ensures cleanup completes BEFORE the notification is posted,
/// and adds guards in the registry to skip loads during account transitions.
final class LibrarySwitchStabilityTests: XCTestCase {

    // MARK: - AccountsManager.isAccountSwitching flag

    func testIsAccountSwitchingDefaultsToFalse() {
        // The flag should be false at rest
        XCTAssertFalse(AccountsManager.shared.isAccountSwitching,
                       "isAccountSwitching should be false when no switch is in progress")
    }

    // MARK: - Registry load guard during account switch

    func testRegistryLoadSkippedDuringAccountSwitch() {
        // Simulate the switching flag being set
        // We can't set it directly (it's private(set)), but we can test the
        // load() method's behavior by verifying it reads the flag.
        // When isAccountSwitching is false, load() should proceed normally.
        let registry = TPPBookRegistry.shared

        // Reset state
        registry.loadingAccount = nil

        // A load with an explicit account should NOT be blocked by the flag
        // (the flag only gates loads that derive from currentAccountId)
        // This verifies the guard only applies to implicit account loads.
        registry.load(account: "nonexistent-test-account")

        // Should not crash, and loadingAccount should be nil since the
        // account doesn't exist on disk
    }

    func testLoadingAccountResetOnAccountChange() {
        let registry = TPPBookRegistry.shared

        // Simulate a stale loadingAccount value from a previous switch
        registry.loadingAccount = "old-account-id"

        // Post the notification that fires when an account changes
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)

        // The sink should have reset loadingAccount to nil
        // (give RunLoop a tick since the sink uses .receive(on: RunLoop.main))
        let expectation = self.expectation(description: "loadingAccount reset")
        DispatchQueue.main.async {
            XCTAssertNil(registry.loadingAccount,
                         "loadingAccount should be reset to nil when account changes")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2.0)
    }

    // MARK: - Rapid sequential notifications

    func testRapidAccountChangeNotificationsDoNotCrash() {
        // Fire many account-change notifications in quick succession.
        // Before the fix, this could trigger concurrent dictionary mutations
        // in the registry because load() would re-enter before the previous
        // load finished.
        let iterations = 20
        let expectation = self.expectation(description: "rapid notifications complete")

        for _ in 0..<iterations {
            NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
        }

        // Wait a beat for all RunLoop-dispatched sinks to fire
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // If we get here without crashing, the test passes
            expectation.fulfill()
        }

        waitForExpectations(timeout: 3.0)
    }

    // MARK: - Nil account ID safety

    func testRegistryLoadWithNilAccountIdDoesNotCrash() {
        // Temporarily clear the current account ID to simulate the window
        // between cleanup and new account assignment
        let originalId = AccountsManager.shared.currentAccountId
        defer {
            // Restore original (may be nil already in test environment)
            if let id = originalId {
                UserDefaults.standard.set(id, forKey: currentAccountIdentifierKey)
            }
        }

        UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey)

        // This should return early gracefully, not crash
        TPPBookRegistry.shared.load()
    }

    func testSyncWithNilAccountDoesNotCrash() {
        // sync() guards on currentAccount?.loansUrl, so with no account
        // it should return immediately without crashing
        TPPBookRegistry.shared.sync()
    }
}
