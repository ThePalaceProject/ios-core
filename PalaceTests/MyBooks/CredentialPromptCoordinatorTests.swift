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

    /// Deterministic join for the coordinator's flow. Every step of
    /// `requestCredentialsAndStartDownload` (the gate check, the Adobe-expired
    /// branch, the `presentSignInModal` call, and the post-sign-in retry /
    /// cleanup) runs inside `Task { @MainActor }` bodies enqueued on THIS
    /// actor. Awaiting barrier `Task { @MainActor }` values services those
    /// earlier-submitted tasks in order — the spy increments (all synchronous
    /// inside those tasks) are then observable. Completes the moment the actor
    /// is free; never starves on a wall clock like the old `awaitConditionAsync`
    /// poll did under CI oversubscription. Three hops cover the deepest chain
    /// (entry Task → presentSignInModal completion Task → cleanup).
    ///
    /// Note: the 2s cooldown Task (which clears the gate later) is NOT joined
    /// by this — it's a genuine fire-and-forget timer the tests don't wait on.
    @MainActor
    private func flushMainActorTasks() async {
        await Task { @MainActor in }.value
        await Task { @MainActor in }.value
        await Task { @MainActor in }.value
    }

    // MARK: - Re-entrancy guard

    func testRequestCredentials_alreadyInFlight_skipsDuplicateModal() async {
        credentialState.isRequestingCredentials = true

        coordinator.requestCredentialsAndStartDownload(for: book)
        // Absence assertion: the entry Task returns immediately (gate already
        // set). Flush the main-actor executor so it runs, then assert nothing
        // presented — deterministic, no fixed sleep.
        await flushMainActorTasks()

        XCTAssertEqual(presentedSignInModal, 0,
                       "Re-entrant request must NOT present another sign-in modal")
        XCTAssertEqual(presentedAdobeAlert, 0)
        XCTAssertTrue(spyDelegate.startDownloadCalls.isEmpty)
    }

    // MARK: - Adobe-expired short-circuit

    func testRequestCredentials_adobeExpired_presentsAdobeAlertInsteadOfSignIn() async {
        isAdobeExpired = true

        coordinator.requestCredentialsAndStartDownload(for: book)
        await flushMainActorTasks()

        XCTAssertEqual(presentedAdobeAlert, 1)
        XCTAssertEqual(presentedSignInModal, 0,
                       "Adobe-expired path must NOT present the regular sign-in modal")
        XCTAssertFalse(credentialState.isRequestingCredentials,
                       "Adobe-expired path resets the gate so a future request can proceed")
    }

    // MARK: - Sign-in success retries via delegate

    func testRequestCredentials_signInSuccess_retriesDownloadViaDelegate() async {
        coordinator.requestCredentialsAndStartDownload(for: book)
        await flushMainActorTasks()

        // Simulate the user signing in successfully — set credentials
        // BEFORE invoking the completion so the hasCredentials check
        // inside the closure succeeds.
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        signInCompletions.first?()

        // The completion enqueues a `Task { @MainActor }` retry; flush services
        // it, then startDownload is observable — no wall-clock poll.
        await flushMainActorTasks()

        XCTAssertEqual(spyDelegate.startDownloadCalls.map { $0.identifier }, [book.identifier])
        XCTAssertFalse(credentialState.isRequestingCredentials,
                       "Sign-in success path resets the gate")
    }

    // MARK: - Sign-in cancel registers completion (no retry)

    func testRequestCredentials_signInCancelled_registersCompletionAndDoesNotRetry() async {
        coordinator.requestCredentialsAndStartDownload(for: book)
        await flushMainActorTasks()

        // User cancels — no credentials at completion time.
        XCTAssertFalse(userAccount.hasCredentials())
        signInCompletions.first?()

        // The completion enqueues a `Task { @MainActor }` cleanup that clears
        // the gate then awaits registerCompletion; flush services its
        // main-actor portion deterministically — no fixed sleep loop.
        await flushMainActorTasks()

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
