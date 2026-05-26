import XCTest
@testable import Palace

/// Behavior tests for `BorrowReducer` — the pure-function core of the
/// borrow / download / return state machine that backs `BookDetailViewModel`.
/// These tests exercise the reducer directly, without a Store, a real
/// `MyBooksDownloadCenter`, registry observers, or the Combine plumbing
/// inside `bindRegistryState`. That's the whole point of the Store
/// pattern: every transition rule lives in a function you can call from
/// a test with a literal state value.
@MainActor
final class BorrowReducerTests: XCTestCase {

    private var env: BorrowEnvironment { BorrowEnvironment() }

    private func makeState(
        bookState: TPPBookState = .unregistered,
        override: TPPBookState? = nil,
        progress: Double = 0.0,
        processing: Set<BookButtonType> = [],
        managingHold: Bool = false,
        halfSheet: Bool = false
    ) -> BorrowState {
        BorrowState(
            bookState: bookState,
            localBookStateOverride: override,
            downloadProgress: progress,
            processingButtons: processing,
            isManagingHold: managingHold,
            showHalfSheet: halfSheet
        )
    }

    // MARK: - Registry-driven state transitions
    //
    // These match the legacy `bindRegistryState` switch in
    // BookDetailViewModel: registry says "this book is now in state X",
    // the VM purges the spinners that no longer make sense and (in some
    // cases) closes the half-sheet. The override carve-out keeps a
    // user-visible "Returning…" UI from being clobbered before the
    // server confirms.

    func testRegistryStateChanged_toUnregistered_closesHalfSheetAndClearsReturnSpinners() {
        var state = makeState(
            bookState: .holding,
            processing: [.returning, .cancelHold, .return, .remove, .download],
            managingHold: true,
            halfSheet: true
        )
        _ = BorrowReducer.reduce(&state, .registryStateChanged(.unregistered))

        XCTAssertEqual(state.bookState, .unregistered)
        XCTAssertFalse(state.isManagingHold,
                       "Returning to unregistered must drop the manage-hold UI")
        XCTAssertFalse(state.showHalfSheet,
                       "Returning to unregistered must dismiss the borrow half-sheet")
        // Return-flow spinners must clear; .download is unrelated and stays.
        XCTAssertEqual(state.processingButtons, [.download],
                       "Only return/cancelHold/remove flags should clear; download is unrelated")
    }

    func testRegistryStateChanged_toDownloading_clearsDownloadSpinnersOnly() {
        var state = makeState(
            bookState: .unregistered,
            processing: [.download, .get, .retry, .returning, .reserve],
            halfSheet: true
        )
        _ = BorrowReducer.reduce(&state, .registryStateChanged(.downloading))

        XCTAssertEqual(state.bookState, .downloading)
        XCTAssertEqual(state.processingButtons, [.returning, .reserve],
                       ".downloading must purge {.download, .get, .retry} but leave unrelated flags")
        XCTAssertTrue(state.showHalfSheet,
                      "Half-sheet must stay open during a download — Cancel must remain reachable")
    }

    /// Systemic guard: any registry state that means "borrow is finished and
    /// the book is on the user's shelf" must clear the acquire-side spinners
    /// (.get / .download / .retry). The F-011 class of bug is "a new terminal
    /// state was added but the reducer's case didn't clear acquire flags" —
    /// the BookButtonMapper.map short-circuits to .downloadInProgress while
    /// `isProcessingDownload` is true, freezing the half-sheet on Cancel.
    ///
    /// Parameterized over every TPPBookState that represents a borrow-completed
    /// outcome. Adding a new such state without clearing flags here would fail
    /// this test instead of escaping to the user as a stuck-button regression.
    func testRegistryStateChanged_clearsAcquireFlags_forAllBorrowCompletedStates() {
        let borrowCompletedStates: [TPPBookState] = [
            .downloadNeeded,
            .downloading,
            .downloadFailed,
            .downloadSuccessful,
            .used,
        ]
        for completedState in borrowCompletedStates {
            var state = makeState(
                bookState: .unregistered,
                processing: [.get, .download, .retry, .returning, .reserve],
                halfSheet: true
            )

            _ = BorrowReducer.reduce(&state, .registryStateChanged(completedState))

            XCTAssertTrue(
                state.processingButtons.intersection([.get, .download, .retry]).isEmpty,
                "Registry transition to \(completedState) must clear acquire-side processing flags. Otherwise BookButtonMapper short-circuits to .downloadInProgress and the half-sheet stays on Cancel (the F-011 regression). Remaining acquire flags: \(state.processingButtons.intersection([.get, .download, .retry]))"
            )
            XCTAssertEqual(
                state.bookState,
                completedState,
                "Registry state assignment must always run before the per-case cleanup."
            )
        }
    }

    /// F-011 regression: borrow completes successfully and the registry
    /// transitions unregistered/holding -> .downloadNeeded. The reducer must
    /// clear `.get` (and sibling borrow-init buttons) from processingButtons
    /// so the half-sheet's button mapper switches from the in-progress
    /// Cancel-only state to the Download + Return state. Before the fix,
    /// processingButtons retained `.get`, BookButtonMapper short-circuited
    /// to .downloadInProgress (because isProcessingDownload stayed true),
    /// and the user had to dismiss + re-open the half-sheet to break the
    /// stuck Cancel state.
    func testRegistryStateChanged_toDownloadNeeded_clearsBorrowProcessingFlags() {
        var state = makeState(
            bookState: .unregistered,
            processing: [.download, .get, .retry, .returning, .reserve],
            halfSheet: true
        )
        _ = BorrowReducer.reduce(&state, .registryStateChanged(.downloadNeeded))

        XCTAssertEqual(state.bookState, .downloadNeeded)
        XCTAssertEqual(state.processingButtons, [.returning, .reserve],
                       ".downloadNeeded must purge {.download, .get, .retry} so the half-sheet swaps Cancel for Download + Return")
        XCTAssertTrue(state.showHalfSheet,
                      "Half-sheet stays open after borrow so the user can tap Download immediately")
    }

    func testRegistryStateChanged_toDownloadFailed_keepsHalfSheetOpenForRetryAlert() {
        var state = makeState(
            bookState: .downloading,
            processing: [.download, .get, .retry],
            halfSheet: true
        )
        _ = BorrowReducer.reduce(&state, .registryStateChanged(.downloadFailed))

        XCTAssertEqual(state.bookState, .downloadFailed)
        XCTAssertTrue(state.processingButtons.intersection([.download, .get, .retry]).isEmpty)
        XCTAssertTrue(state.showHalfSheet,
                      "Auto-closing the half-sheet on failure races the SwiftUI alert presentation")
    }

    func testRegistryStateChanged_toDownloadSuccessful_keepsHalfSheetOpenSoUserCanReadOrListen() {
        var state = makeState(
            bookState: .downloading,
            processing: [.download, .get, .retry],
            halfSheet: true
        )
        _ = BorrowReducer.reduce(&state, .registryStateChanged(.downloadSuccessful))

        XCTAssertEqual(state.bookState, .downloadSuccessful)
        XCTAssertTrue(state.processingButtons.isEmpty)
        XCTAssertTrue(state.showHalfSheet,
                      "Half-sheet stays open on success so the user can tap Read/Listen without re-opening")
    }

    func testRegistryStateChanged_toHolding_clearsReserveAndDismissesHalfSheet() {
        var state = makeState(
            bookState: .unregistered,
            processing: [.reserve, .get, .download],
            halfSheet: true
        )
        _ = BorrowReducer.reduce(&state, .registryStateChanged(.holding))

        XCTAssertEqual(state.bookState, .holding)
        XCTAssertEqual(state.processingButtons, [.download],
                       "Holding clears the reserve/get spinners only; .download is unrelated and stays")
        XCTAssertFalse(state.showHalfSheet,
                       "Hold placed — user is no longer mid-borrow, half-sheet must close")
    }

    // MARK: - Returning override

    func testRegistryStateChanged_whenReturningOverrideArmed_suppressesNonTerminalState() {
        var state = makeState(
            bookState: .returning,
            override: .returning,
            processing: [.returning],
            halfSheet: true
        )
        _ = BorrowReducer.reduce(&state, .registryStateChanged(.downloadSuccessful))

        XCTAssertEqual(state.bookState, .returning,
                       "While returning override is armed, registry must not flip back to downloadSuccessful")
        XCTAssertTrue(state.processingButtons.contains(.returning),
                      "Spinner must remain so the user sees we're still returning")
    }

    func testRegistryStateChanged_whenReturningOverrideArmed_acceptsUnregisteredAsTerminal() {
        var state = makeState(
            bookState: .returning,
            override: .returning,
            processing: [.returning],
            halfSheet: true
        )
        _ = BorrowReducer.reduce(&state, .registryStateChanged(.unregistered))

        XCTAssertEqual(state.bookState, .unregistered,
                       "Unregistered is the only state that may break out of the returning override")
        XCTAssertFalse(state.processingButtons.contains(.returning))
        XCTAssertFalse(state.showHalfSheet)
    }

    // MARK: - Direct bookState assignment (legacy didSet semantics)

    func testBookStateAssigned_toReturning_armsTheOverride() {
        var state = makeState(bookState: .downloadSuccessful)
        _ = BorrowReducer.reduce(&state, .bookStateAssigned(.returning))

        XCTAssertEqual(state.bookState, .returning)
        XCTAssertEqual(state.localBookStateOverride, .returning,
                       "Setting bookState=.returning must arm the override so registry emissions don't unstick the UI")
    }

    func testBookStateAssigned_toUnregistered_clearsTheOverride() {
        var state = makeState(bookState: .returning, override: .returning)
        _ = BorrowReducer.reduce(&state, .bookStateAssigned(.unregistered))

        XCTAssertEqual(state.bookState, .unregistered)
        XCTAssertNil(state.localBookStateOverride,
                     "Setting bookState=.unregistered must clear the override (return completed)")
    }

    func testBookStateAssigned_toOtherState_doesNotChangeOverride() {
        var state = makeState(bookState: .unregistered, override: .returning)
        _ = BorrowReducer.reduce(&state, .bookStateAssigned(.downloading))

        XCTAssertEqual(state.bookState, .downloading)
        XCTAssertEqual(state.localBookStateOverride, .returning,
                       "Override must only be touched by .returning or .unregistered assignments")
    }

    // MARK: - Download progress

    func testDownloadProgressUpdated_clampsToMaxSeen_neverSlidesBackward() {
        var state = makeState(progress: 0.6)
        _ = BorrowReducer.reduce(&state, .downloadProgressUpdated(0.3))
        XCTAssertEqual(state.downloadProgress, 0.6, accuracy: 0.0001,
                       "Progress must never slide backward — 0.3 < 0.6 is ignored")

        _ = BorrowReducer.reduce(&state, .downloadProgressUpdated(0.9))
        XCTAssertEqual(state.downloadProgress, 0.9, accuracy: 0.0001)
    }

    // MARK: - Download error recovery

    func testDownloadErrorOccurred_resyncsBookStateAndPurgesAllAcquireSpinners() {
        var state = makeState(
            bookState: .downloading,           // VM was optimistically downloading
            progress: 0.42,
            processing: [.download, .get, .retry, .reserve, .returning],
            halfSheet: true
        )
        _ = BorrowReducer.reduce(&state, .downloadErrorOccurred(registryState: .unregistered))

        XCTAssertEqual(state.bookState, .unregistered,
                       "Error must re-sync to the registry's truth so the half-sheet exits its optimistic state")
        XCTAssertEqual(state.processingButtons, [.returning],
                       "All four download/borrow spinners must clear; .returning is from a different flow and stays")
        XCTAssertEqual(state.downloadProgress, 0.0, accuracy: 0.0001)
        // showHalfSheet stays as-is — the alert is what dismisses it, not the reducer.
        XCTAssertTrue(state.showHalfSheet)
    }

    // MARK: - User-initiated transitions

    func testDownloadStartConfirmed_setsDownloadingAndOpensHalfSheet() {
        var state = makeState(bookState: .unregistered, halfSheet: false)
        _ = BorrowReducer.reduce(&state, .downloadStartConfirmed)

        XCTAssertEqual(state.bookState, .downloading)
        XCTAssertTrue(state.showHalfSheet,
                      "downloadStartConfirmed must surface the Cancel button before the network task even runs")
    }

    /// `returnStartConfirmed` inserts only the `.returning` spinner — must
    /// not flip `bookState` (the registry hasn't confirmed yet) and must
    /// not insert any other spinner. Catches a mutant that bumps
    /// bookState prematurely OR adds extra processing flags.
    func testReturnStartConfirmed_insertsReturningSpinnerOnlyAndPreservesBookState() {
        var state = makeState(
            bookState: .downloadSuccessful,
            processing: [.download]
        )
        _ = BorrowReducer.reduce(&state, .returnStartConfirmed)
        XCTAssertTrue(state.processingButtons.contains(.returning),
                      "Returning spinner must be inserted")
        XCTAssertEqual(state.processingButtons, [.download, .returning],
                       "No other spinner is added — only .returning, alongside any pre-existing flags")
        XCTAssertEqual(state.bookState, .downloadSuccessful,
                       "Book state must NOT change yet — registry confirmation drives the transition")
    }

    func testCancelTapped_resetsDownloadProgressAndIsIdempotent() {
        var state = makeState(progress: 0.7)
        _ = BorrowReducer.reduce(&state, .cancelTapped)
        XCTAssertEqual(state.downloadProgress, 0.0, accuracy: 0.0001)
        // Calling again from zero must remain at zero — guards against
        // the legacy `didSelectCancel` callsite being invoked twice.
        _ = BorrowReducer.reduce(&state, .cancelTapped)
        XCTAssertEqual(state.downloadProgress, 0.0, accuracy: 0.0001)
    }

    func testManageHoldTapped_setsHoldingStateAndManagingFlag() {
        var state = makeState(bookState: .holding, managingHold: false)
        _ = BorrowReducer.reduce(&state, .manageHoldTapped)
        XCTAssertTrue(state.isManagingHold)
        XCTAssertEqual(state.bookState, .holding,
                       "manageHoldTapped must keep us in .holding so the manage-hold UI renders")
    }

    /// `signInCancelled` mirrors the legacy `ensureAuthAndExecute`
    /// cancellation block: it must release the four acquire-related
    /// spinners (`.download`, `.get`, `.retry`, `.reserve`) but leave
    /// unrelated flags like `.returning` alone. Lock both branches plus
    /// the empty-state idempotence so a mutant that always-clears or
    /// over-clears fails on a distinct row.
    func testSignInCancelled_releasesAcquireSpinnersAndPreservesUnrelatedFlags() {
        var state = makeState(processing: [.download, .get, .retry, .reserve, .returning])
        _ = BorrowReducer.reduce(&state, .signInCancelled)
        XCTAssertEqual(state.processingButtons, [.returning],
                       "Sign-in cancelled must release {download, get, retry, reserve} but leave .returning")

        // Idempotence: re-running on already-cleared state is a no-op.
        _ = BorrowReducer.reduce(&state, .signInCancelled)
        XCTAssertEqual(state.processingButtons, [.returning],
                       "Re-running signInCancelled on cleared state must NOT remove .returning")

        // Empty-state safety: must not crash and must remain empty.
        var emptyState = makeState()
        _ = BorrowReducer.reduce(&emptyState, .signInCancelled)
        XCTAssertEqual(emptyState.processingButtons, [],
                       "signInCancelled on empty processingButtons must remain empty — no phantom inserts")
    }

    // MARK: - Processing button bookkeeping

    func testProcessingButtonInserted_addsTheButton() {
        var state = makeState()
        _ = BorrowReducer.reduce(&state, .processingButtonInserted(.download))
        XCTAssertTrue(state.processingButtons.contains(.download))

        // Inserting an already-present button is idempotent (Set semantics).
        _ = BorrowReducer.reduce(&state, .processingButtonInserted(.download))
        XCTAssertEqual(state.processingButtons, [.download])
    }

    /// `processingButtonRemoved` removes only the named button — never
    /// touches the other flags AND must be safe when the named flag is
    /// already absent. Lock both shapes so a mutant that clears the whole
    /// set OR fails to remove the target fails on a distinct assertion.
    func testProcessingButtonRemoved_removesOnlyThatButton_andIsIdempotent() {
        var state = makeState(processing: [.download, .retry])

        _ = BorrowReducer.reduce(&state, .processingButtonRemoved(.retry))
        XCTAssertEqual(state.processingButtons, [.download],
                       ".retry must be the only flag cleared — others remain untouched")

        // Removing an already-absent flag must be a no-op.
        _ = BorrowReducer.reduce(&state, .processingButtonRemoved(.retry))
        XCTAssertEqual(state.processingButtons, [.download],
                       "Removing already-absent .retry must NOT clear unrelated flags")

        // Removing a different flag clears it independently.
        _ = BorrowReducer.reduce(&state, .processingButtonRemoved(.download))
        XCTAssertEqual(state.processingButtons, [],
                       "Removing the only remaining flag must yield an empty set")
    }
}
