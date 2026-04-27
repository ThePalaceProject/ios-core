import Foundation

/// Pure state for the borrow / download / return lifecycle as observed by
/// `BookDetailViewModel`. Models the slice of VM state that mutates in
/// response to registry events, download progress, and user button taps —
/// i.e. the actual finite-state-machine slice, separate from the cosmetic
/// VM fields (related books, alerts, sample previews, etc.).
///
/// Not `Equatable` — `processingButtons` is a Set of an Obj-C-bridged enum
/// and not all helpers participate in equality. Tests assert on the slices
/// they care about (bookState, processingButtons membership, flag fields).
struct BorrowState {
    var bookState: TPPBookState
    /// Mirrors `BookDetailViewModel.localBookStateOverride`. While set to
    /// `.returning`, registry emissions for any state except `.unregistered`
    /// are suppressed so the "Returning…" UI sticks until the server confirms.
    var localBookStateOverride: TPPBookState? = nil
    var downloadProgress: Double = 0.0
    var processingButtons: Set<BookButtonType> = []
    var isManagingHold: Bool = false
    var showHalfSheet: Bool = false

    init(
        bookState: TPPBookState,
        localBookStateOverride: TPPBookState? = nil,
        downloadProgress: Double = 0.0,
        processingButtons: Set<BookButtonType> = [],
        isManagingHold: Bool = false,
        showHalfSheet: Bool = false
    ) {
        self.bookState = bookState
        self.localBookStateOverride = localBookStateOverride
        self.downloadProgress = downloadProgress
        self.processingButtons = processingButtons
        self.isManagingHold = isManagingHold
        self.showHalfSheet = showHalfSheet
    }
}

enum BorrowAction {
    /// Registry publisher reported a new state for this book.
    /// May be suppressed by the `.returning` override.
    case registryStateChanged(TPPBookState)

    /// Download center reported new progress (already filtered by book id).
    /// Clamped against the existing value so the bar never slides backwards.
    case downloadProgressUpdated(Double)

    /// Download or borrow error landed for this book.
    /// `registryState` is the registry's authoritative truth at the time of
    /// the error — used to recover the UI from a stuck "Cancel" sheet when
    /// `startDownloadAfterAuth` set `bookState=.downloading` optimistically.
    case downloadErrorOccurred(registryState: TPPBookState)

    /// User confirmed download (passed the auth gate). Optimistically flip to
    /// `.downloading` + open half-sheet so the Cancel button appears.
    case downloadStartConfirmed

    /// User confirmed return (passed the auth gate). Insert `.returning` into
    /// processing immediately for instant feedback; the network call follows.
    case returnStartConfirmed

    /// User chose Cancel — clear progress (the cancel side effect is fired
    /// by the VM since it holds the download center reference).
    case cancelTapped

    /// User chose Manage Hold — flip to managing-hold UI.
    case manageHoldTapped

    /// Sign-in modal closed without credentials (user cancelled).
    /// Strip the download/borrow processing flags so the button returns to
    /// its idle label instead of staying spinner-locked.
    case signInCancelled

    /// VM-level direct write to `bookState` (e.g. a test or a legacy code
    /// path) — applies the override didSet semantics: setting `.returning`
    /// arms the override; setting `.unregistered` clears it.
    case bookStateAssigned(TPPBookState)

    /// Add a button to the processing set (raised when handleAction taps a
    /// button — the spinner appears and duplicate taps are filtered).
    case processingButtonInserted(BookButtonType)

    /// Remove a button from the processing set (typically via a completion
    /// handler when the side effect finishes).
    case processingButtonRemoved(BookButtonType)
}

/// No async effects today — every transition is synchronous. The
/// environment is left as a placeholder so a future Phase can wire async
/// side effects (e.g. the borrow/return network calls themselves) without
/// changing the reducer's signature.
struct BorrowEnvironment {}

/// Namespace for the Borrow lifecycle reducer. Pure function: takes a
/// state-by-reference and an action, returns an `Effect`. Today every
/// effect is `.none` — the VM still owns side-effect dispatch (calling
/// `downloadCenter.startDownload`, etc.) — but using `Effect` keeps the
/// shape compatible with `Store<BorrowState, BorrowAction, BorrowEnvironment>`
/// for a future migration when test patterns no longer assume direct
/// `@Published` mutation on `BookDetailViewModel`.
enum BorrowReducer {

    /// Buttons that count as "the user is trying to acquire / download this
    /// book." Cleared together when sign-in is cancelled or a download error
    /// lands, so the user isn't left with a stuck spinner.
    static let downloadRelatedButtons: Set<BookButtonType> = [
        .download, .get, .retry, .reserve
    ]

    static func reduce(
        _ state: inout BorrowState,
        _ action: BorrowAction
    ) -> Effect<BorrowAction, BorrowEnvironment> {
        switch action {

        case .registryStateChanged(let registryState):
            // Override: while .returning is armed, ignore non-terminal
            // registry states so the "Returning…" UI sticks.
            if state.localBookStateOverride == .returning,
               registryState != .unregistered {
                return .none
            }
            state.bookState = registryState
            switch registryState {
            case .unregistered:
                state.isManagingHold = false
                state.showHalfSheet = false
                state.processingButtons.subtract([.returning, .cancelHold, .return, .remove])

            case .downloading, .downloadFailed:
                // Download started / failed — clear the spinners on the
                // download-initiating buttons. Half-sheet stays open on
                // failure so the retry/cancel options remain reachable.
                state.processingButtons.subtract([.download, .get, .retry])

            case .downloadSuccessful, .used:
                // Half-sheet stays open so the user can tap Read/Listen
                // without a second navigation.
                state.processingButtons.subtract([.download, .get, .retry])

            case .holding:
                // Hold placed — clear the reserve spinner and dismiss the
                // half-sheet (the user is no longer mid-borrow).
                state.processingButtons.remove(.reserve)
                state.processingButtons.remove(.get)
                state.showHalfSheet = false

            default:
                break
            }
            return .none

        case .downloadProgressUpdated(let value):
            // Clamp to max-seen so progress never slides backwards.
            state.downloadProgress = max(state.downloadProgress, value)
            return .none

        case .downloadErrorOccurred(let registryState):
            // Re-sync to the registry's truth and strip every download-side
            // processing flag so the half-sheet exits its optimistic state.
            state.bookState = registryState
            state.processingButtons.subtract(downloadRelatedButtons)
            state.downloadProgress = 0.0
            return .none

        case .downloadStartConfirmed:
            state.bookState = .downloading
            state.showHalfSheet = true
            return .none

        case .returnStartConfirmed:
            state.processingButtons.insert(.returning)
            return .none

        case .cancelTapped:
            state.downloadProgress = 0.0
            return .none

        case .manageHoldTapped:
            state.isManagingHold = true
            state.bookState = .holding
            return .none

        case .signInCancelled:
            state.processingButtons.subtract(downloadRelatedButtons)
            return .none

        case .bookStateAssigned(let newState):
            // Mirrors the legacy didSet on BookDetailViewModel.bookState:
            //   - .returning arms the override so registry emissions for
            //     downloadSuccessful/used/etc. don't stomp the UI.
            //   - .unregistered clears the override (return completed).
            if newState == .returning {
                state.localBookStateOverride = .returning
            } else if newState == .unregistered {
                state.localBookStateOverride = nil
            }
            state.bookState = newState
            return .none

        case .processingButtonInserted(let button):
            state.processingButtons.insert(button)
            return .none

        case .processingButtonRemoved(let button):
            state.processingButtons.remove(button)
            return .none
        }
    }
}
