//
//  CredentialPromptCoordinatorTests.swift
//  PalaceTests
//
//  Coverage for the start-download credential-prompt branches in
//  CredentialPromptCoordinator: re-entrancy guard via shared
//  CredentialRequestState, Adobe-expired short-circuit, sign-in
//  success retries via delegate, sign-in cancel cleans up the
//  download coordinator.
//

import XCTest
@testable import Palace

@MainActor
final class CredentialPromptCoordinatorTests: XCTestCase {

    private var stateManager: DownloadStateManager!
    private var userAccount: TPPUserAccountMock!
    private var credentialState: CredentialRequestState!
    private var spyDelegate: SpyDelegate!
    // Swift 6: `presentSignInModal` / `presentAdobeExpiredAlert` are `@MainActor`
    // closures stored on the `@unchecked Sendable` CredentialPromptCoordinator,
    // so a closure that captures `self` (a non-Sendable XCTestCase) to mutate
    // these recorders sends `self` across the boundary. Box the recorders the
    // flagged closures touch (lock-guarded, Sendable) and capture the boxes as
    // locals in `setUp`. Computed shims keep every read site unchanged.
    private let presentedSignInModalBox = LockIsolated<Int>(0)
    private var presentedSignInModal: Int { presentedSignInModalBox.value }
    private let presentedAdobeAlertBox = LockIsolated<Int>(0)
    private var presentedAdobeAlert: Int { presentedAdobeAlertBox.value }
    private var isAdobeExpired = false
    /// Stash of completion handlers from each presentSignInModal call
    /// so tests can drive the success/cancel branches explicitly.
    private let signInCompletionsBox = LockIsolated<[() -> Void]>([])
    private var signInCompletions: [() -> Void] { signInCompletionsBox.value }
    private var coordinator: CredentialPromptCoordinator!
    private var book: TPPBook!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateManager = DownloadStateManager()
        userAccount = TPPUserAccountMock()
        credentialState = CredentialRequestState()
        spyDelegate = SpyDelegate()
        presentedSignInModalBox.value = 0
        presentedAdobeAlertBox.value = 0
        isAdobeExpired = false
        signInCompletionsBox.value = []

        // Capture the Sendable boxes as locals so the @MainActor present-*
        // closures reference the boxes, not `self`.
        let presentedSignInModalBox = presentedSignInModalBox
        let presentedAdobeAlertBox = presentedAdobeAlertBox
        let signInCompletionsBox = signInCompletionsBox
        coordinator = CredentialPromptCoordinator(
            stateManager: stateManager,
            userAccountProvider: { [unowned self] in self.userAccount },
            credentialRequestState: credentialState,
            presentSignInModal: { completion in
                presentedSignInModalBox.withValue { $0 += 1 }
                signInCompletionsBox.withValue { $0.append(completion) }
            },
            isAdobeDRMExpired: { [unowned self] in self.isAdobeExpired },
            presentAdobeExpiredAlert: { presentedAdobeAlertBox.withValue { $0 += 1 } }
        )
        coordinator.delegate = spyDelegate

        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    }

    override func tearDownWithError() throws {
        stateManager = nil
        userAccount = nil
        credentialState = nil
        spyDelegate = nil
        signInCompletionsBox.value = []
        coordinator = nil
        book = nil
        try super.tearDownWithError()
    }

    /// Wraps the shared `awaitConditionAsync` helper. `file`/`line`
    /// forwarded so timeout XCTFail blames the call site.
    private func waitForAsync(
        timeout: TimeInterval = 10.0,
        file: StaticString = #file,
        line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) async {
        await awaitConditionAsync(timeout: timeout, file: file, line: line, predicate)
    }

    // MARK: - Re-entrancy guard

    func testRequestCredentials_alreadyInFlight_skipsDuplicateModal() async {
        credentialState.isRequestingCredentials = true

        coordinator.requestCredentialsAndStartDownload(for: book)
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }

        XCTAssertEqual(presentedSignInModal, 0,
                       "Re-entrant request must NOT present another sign-in modal")
        XCTAssertEqual(presentedAdobeAlert, 0)
        XCTAssertTrue(spyDelegate.startDownloadCalls.isEmpty)
    }

    // MARK: - Adobe-expired short-circuit

    func testRequestCredentials_adobeExpired_presentsAdobeAlertInsteadOfSignIn() async {
        isAdobeExpired = true

        coordinator.requestCredentialsAndStartDownload(for: book)
        await waitForAsync { [self] in self.presentedAdobeAlert > 0 }

        XCTAssertEqual(presentedAdobeAlert, 1)
        XCTAssertEqual(presentedSignInModal, 0,
                       "Adobe-expired path must NOT present the regular sign-in modal")
        XCTAssertFalse(credentialState.isRequestingCredentials,
                       "Adobe-expired path resets the gate so a future request can proceed")
    }

    // MARK: - Sign-in success retries via delegate

    func testRequestCredentials_signInSuccess_retriesDownloadViaDelegate() async {
        coordinator.requestCredentialsAndStartDownload(for: book)
        await waitForAsync { [self] in self.presentedSignInModal > 0 }

        // Simulate the user signing in successfully — set credentials
        // BEFORE invoking the completion so the hasCredentials check
        // inside the closure succeeds.
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        signInCompletions.first?()

        await waitForAsync { [self] in self.spyDelegate.startDownloadCalls.count > 0 }

        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier])
        XCTAssertFalse(credentialState.isRequestingCredentials,
                       "Sign-in success path resets the gate")
    }

    // MARK: - Sign-in cancel registers completion (no retry)

    func testRequestCredentials_signInCancelled_registersCompletionAndDoesNotRetry() async {
        coordinator.requestCredentialsAndStartDownload(for: book)
        await waitForAsync { [self] in self.presentedSignInModal > 0 }

        // User cancels — no credentials at completion time.
        XCTAssertFalse(userAccount.hasCredentials())
        signInCompletions.first?()

        // Allow the cleanup Task to register completion.
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
        }

        XCTAssertTrue(spyDelegate.startDownloadCalls.isEmpty,
                      "Cancellation must NOT retry the download")
        XCTAssertFalse(credentialState.isRequestingCredentials,
                       "Cancellation path resets the gate")
        // We can't directly assert downloadCoordinator.registerCompletion was
        // called from outside (the actor's state is opaque), but the test
        // exercises the path; the lack of a startDownload call combined with
        // the cleared gate confirms the closure body ran to completion.
    }
}

// MARK: - Spy

private final class SpyDelegate: CredentialPromptCoordinatorDelegate {
    private(set) var startDownloadCalls: [(book: TPPBook, identifier: String)] = []

    func startDownload(for book: TPPBook, withRequest request: URLRequest?) {
        startDownloadCalls.append((book, book.identifier))
    }
}
