import SwiftUI
import PalaceBookModel
import PalaceBookRegistry

/// Which progress cue the half-sheet shows. Extracted from the view so the
/// decision is unit-testable and mutation-verifiable — a SwiftUI `@ViewBuilder`
/// body is not, and this decision has real consequences: picking `.none` while
/// a multi-gigabyte `.lcpa` transfers is what made patrons think the app had
/// failed and back out mid-download.
enum HalfSheetProgressCue: Equatable {
    /// Borrow request in flight, download not started — indeterminate spinner
    /// plus "Borrowing…". The slow-distributor case (e.g. Overdrive) that
    /// previously showed an inert 0% linear bar.
    case borrowing
    /// A transfer is running — determinate linear bar.
    case downloading
    /// Nothing in flight — invisible spacer that preserves layout height.
    case idle

    /// - Parameters:
    ///   - isBorrowProcessing: registry processing flag, set by `BorrowOperation`.
    ///   - downloadProgress: 0…1 from the download centre.
    ///   - bookState: registry state.
    ///   - buttonState: resolved button state.
    ///   - isDownloadingLCPContent: the background `.lcpa` content re-download
    ///     is running. Required as its own input because that path leaves the
    ///     book at `.downloadSuccessful` (only its content went missing), so the
    ///     `bookState` clause below cannot see it.
    ///   - contentRequiredBeforePlayback: the archive must land before the book
    ///     can be opened — i.e. LCP streaming is OFF. Distinguishes a transfer
    ///     the patron is WAITING on from one running behind a book that already
    ///     plays. Without it this decision is only correct while the streaming
    ///     flag is on, and that flag defaults OFF.
    static func resolve(
        isBorrowProcessing: Bool,
        downloadProgress: Double,
        bookState: TPPBookState,
        buttonState: BookButtonState,
        isDownloadingLCPContent: Bool,
        contentRequiredBeforePlayback: Bool
    ) -> HalfSheetProgressCue {
        // THE INVARIANT, checked first so it governs every cue below: a progress
        // cue may fire ONLY while the patron is waiting to be able to OPEN this
        // book. Not "is something transferring" — transfers outlive the wait.
        //
        // Stated as an allowlist rather than a series of exclusions because the
        // exclusions kept missing cells. Two were found by hand and a third on
        // device only after both were fixed:
        //   - `.downloadSuccessful` / `.used` render Listen, and a bar beside a
        //     working Listen button tells the patron to wait for nothing. With
        //     PP-4957 streaming on and PP-5135 fetching the `.lcpa` behind it,
        //     this is now the COMMON case, not an edge one.
        //   - `.returning` was the device reproduction (build 505): borrow, tap
        //     Listen, enter the player, come back, tap Return — and the still
        //     in-flight archive fetch drew a bar onto a book being given back.
        //     No open-affordance guard catches that, because `.returning` is
        //     not one.
        // An allowlist cannot accumulate that class of miss: a state shows a cue
        // only if it is named here.
        // A book being GIVEN BACK is answered first and unconditionally. This
        // is the reported repro (borrow, Listen, enter player, back, tap
        // Return), and it must not be re-opened by the wait clause below: with
        // streaming off that clause would put the bar straight back onto the
        // Return confirmation sheet. Whatever is still transferring, a patron
        // handing a book back is not waiting to open it.
        if buttonState == .returning { return .idle }

        // A transfer the patron must WAIT for outranks the allowlist, because
        // then the wait is real whatever the button says. With LCP streaming
        // OFF — and `lcp_audiobook_streaming_enabled` DEFAULTS OFF, it is the
        // kill switch — `shouldTriggerContentDownloadBeforeOpen` blocks the open
        // until the archive lands, while the book still reads
        // `.downloadSuccessful`. Suppressing here would restore the silent
        // multi-gigabyte wait this cue was written for.
        if isDownloadingLCPContent && contentRequiredBeforePlayback {
            return .downloading
        }
        guard mayShowProgressCue(buttonState, isBorrowProcessing: isBorrowProcessing) else {
            return .idle
        }
        // Ordered before the borrow spinner deliberately. A known content transfer
        // is a strictly better answer than "borrow is processing": borrow stays
        // marked processing across the whole `.lcpa` fetch, and that fetch reports
        // zero until its first byte lands, so checking the spinner first pinned
        // the half-sheet on "borrowing" for the entire multi-minute download.
        // Patrons read the motionless spinner as a hang and backed out.
        if isDownloadingLCPContent {
            return .downloading
        }
        if isBorrowProcessing && downloadProgress == 0 {
            return .borrowing
        }
        // The `buttonState != .downloadSuccessful` exclusion this clause used to
        // carry is gone: the guard above already answered it, for every
        // non-waiting state rather than that one.
        if bookState == .downloading {
            return .downloading
        }
        return .idle
    }

    /// Whether a progress cue may fire at all for this button state — i.e.
    /// whether the patron is still waiting to be able to open the book.
    ///
    /// Exhaustive with no `default:` — the F-011 class-of-bug guard used
    /// elsewhere in this file. A new `BookButtonState` will not compile until
    /// someone classifies it, which is the point: the failures this replaces
    /// were all states that fell through into "show a bar" because nobody had
    /// thought about them.
    private static func mayShowProgressCue(
        _ buttonState: BookButtonState,
        isBorrowProcessing: Bool
    ) -> Bool {
        switch buttonState {
        // Waiting to acquire — a cue is the only signal the patron has, and
        // withholding it is what made the sheet look inert and hung.
        case .downloadInProgress, .downloadNeeded:
            return true
        // A BORROW IN FLIGHT IS A WAIT TO ACQUIRE, and this is the cell an
        // earlier revision of this allowlist got wrong. `BorrowOperation` sets
        // the processing flag BEFORE `fetchBook` (a 30s ceiling on a slow
        // distributor) and only moves the registry afterwards, so for the whole
        // round trip the state is still `.unregistered` and the button still
        // reads `.canBorrow`. Answering `.idle` there removed the ONLY
        // "Borrowing…" signal and re-opened the "borrow stuck with Cancel-only
        // UI" defect that `BookDetailViewModel`'s `isBorrowProcessing` seed
        // exists to prevent. Without a borrow in flight there is nothing to
        // report and this stays idle.
        case .canBorrow:
            return isBorrowProcessing
        // Already openable: renders Listen / Read.
        case .downloadSuccessful, .used:
            return false
        // `.returning` is answered unconditionally at the top of `resolve`, so
        // this arm is unreachable in practice. It is kept — and named as
        // unreachable rather than deleted — because the switch is exhaustive
        // with no `default:`, and removing the case would make the compiler
        // demand one, which is precisely the escape hatch this shape exists to
        // deny. Mutation reports it `uncovered`; that is correct and expected.
        case .returning:
            return false
        // Not acquired, or not acquirable: nothing is being waited on here.
        case .canHold, .holding, .holdingFrontOfQueue,
             .managingHold, .downloadFailed, .unsupported:
            return false
        }
    }
}

@MainActor
protocol HalfSheetProvider: ObservableObject, BookButtonProvider {
    var isFullSize: Bool { get }
    var bookState: TPPBookState { get set }
    var buttonState: BookButtonState { get }
    var isReturning: Bool { get }
    var isManagingHold: Bool { get }
    var downloadProgress: Double { get }
    var book: TPPBook { get }

    /// `true` while a borrow request is in flight at the network layer
    /// (set by `BorrowOperation` via `bookRegistry.setProcessing`). The
    /// half-sheet uses this to show an indeterminate spinner + "Borrowing…"
    /// label during the borrow phase, before the download itself begins
    /// emitting progress. Default `false` so legacy providers (e.g.
    /// `BookCellModel`) don't have to opt in mechanically.
    var isBorrowProcessing: Bool { get }

    /// `true` while the background `.lcpa` content re-download is running for
    /// this book. With LCP streaming broken upstream, the whole archive must be
    /// on disk before playback, and for a book that is already
    /// `.downloadSuccessful` with only its content missing there is no
    /// `.downloading` state to drive the usual progress bar.
    ///
    /// Defaulted `false` for providers that genuinely never reach this path — but
    /// note that BOTH current providers do implement it. `BookCellModel`
    /// deliberately overrides: the content self-heal fires for books on the My
    /// Books shelf, which that model backs, so taking the default there showed no
    /// progress for the entire transfer. Treat the default as a compatibility
    /// affordance for a future provider, not as evidence that a given provider is
    /// off this path — check the provider.
    var isDownloadingLCPContent: Bool { get }
    /// True when the `.lcpa` must land before the book can be opened — LCP
    /// streaming OFF. See `HalfSheetProgressCue.resolve`.
    ///
    /// DELIBERATELY HAS NO DEFAULT. An earlier revision defaulted it to `false`
    /// with a comment claiming that "preserves their existing behaviour
    /// exactly" — which was untrue, because there was no allowlist to preserve.
    /// `BookCellModel` also presents this sheet (`NormalBookCell` →
    /// `HalfSheetView(viewModel: model)`), so the default silently turned a
    /// required multi-gigabyte wait into a blank sheet on the My Books route.
    /// Both reviewers caught it independently. Requiring every conformer to
    /// answer is the same principle as the allowlist below: a new participant
    /// must decide rather than inherit.
    var contentRequiredBeforePlayback: Bool { get }

    /// Error alert to present via SwiftUI `.alert` on the half sheet.
    var downloadErrorAlert: AlertModel? { get set }

    /// Confirmation alert (return, cancel-hold) that must render ON the
    /// half-sheet so it is visible and interactive. Previously this was
    /// only bound to the BookCell behind the sheet, making Cancel Hold
    /// non-functional (SQ-008).
    var showAlert: AlertModel? { get set }
}

extension HalfSheetProvider {
    var isDownloadingLCPContent: Bool { false }

    var isReturning: Bool {
        bookState == .returning
    }

    var isManagingHold: Bool {
        // Exhaustive (no `default:`) — F-011 class-of-bug guard. Compiler
        // flags this site if BookButtonState gains a new case so a hold-like
        // state can't silently be classified as "not managing a hold".
        switch buttonState {
        case .managingHold, .holding, .holdingFrontOfQueue:
            true
        case .canBorrow, .canHold, .downloadNeeded, .downloadSuccessful,
             .used, .downloadInProgress, .returning, .downloadFailed,
             .unsupported:
            false
        }
    }

    /// Default for legacy providers (BookCellModel) that don't track a
    /// distinct borrow phase. They render the previous behavior.
    var isBorrowProcessing: Bool { false }
}

struct HalfSheetView<ViewModel: HalfSheetProvider>: View {
    typealias DisplayStrings = Strings.BookDetailView
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var viewModel: ViewModel
    var backgroundColor: Color
    @Binding var coverImage: UIImage?
    @AccessibilityFocusState private var isBookTitleFocused: Bool
    @State private var originalState: TPPBookState = .unregistered
    @State private var didChangeState: Bool = false
    let accountsManager: AccountsManager
    let bookRegistry: TPPBookRegistryProvider

    init(viewModel: ViewModel, backgroundColor: Color, coverImage: Binding<UIImage?>, accountsManager: AccountsManager = AppContainer.production().accountsManager, bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry) {
        self.viewModel = viewModel
        self.backgroundColor = backgroundColor
        self._coverImage = coverImage
        self.accountsManager = accountsManager
        self.bookRegistry = bookRegistry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: viewModel.isFullSize ? 20 : 10) {

            headerView

            Text(accountsManager.currentAccount?.name ?? "")
                .font(.headline)

            bookInfoView
            statusInfoView

            progressIndicator

            if viewModel.isFullSize {
                BookButtonsView(provider: viewModel, previewEnabled: false, onButtonTapped: { type in
                    // Exhaustive (no `default:`) — F-011 class-of-bug guard.
                    // Compiler now flags this if BookButtonType gains a case.
                    switch type {
                    case .close:
                        viewModel.bookState = originalState
                        dismiss()
                    case .read, .listen, .readStreaming:
                        // PP-4161: .readStreaming joins .read / .listen as a
                        // terminal "open the content" affordance from the
                        // half-sheet. The DispatchQueue.main.async hop is the
                        // same — let the half-sheet finish its dismissal
                        // animation before the reader presentation steals the
                        // screen.
                        didChangeState = true
                        DispatchQueue.main.async {
                            viewModel.handleAction(for: type)
                        }
                    case .return:
                        if viewModel.isReturning {
                            didChangeState = true
                            viewModel.handleAction(for: .return)
                        } else {
                            viewModel.bookState = .returning
                        }
                    case .remove,
                         .get, .reserve, .download, .retry, .cancel,
                         .sample, .audiobookSample, .cancelHold,
                         .manageHold, .returning:
                        didChangeState = true
                        viewModel.handleAction(for: type)
                    }
                })
                .horizontallyCentered()
            } else {
                BookButtonsView(provider: viewModel, previewEnabled: false, onButtonTapped: { type in
                    // Exhaustive (no `default:`) — F-011 class-of-bug guard.
                    // Compiler now flags this if BookButtonType gains a case.
                    switch type {
                    case .close:
                        viewModel.bookState = originalState
                        dismiss()
                    case .read, .listen, .readStreaming:
                        // PP-4161: .readStreaming joins .read / .listen as a
                        // terminal "open the content" affordance from the
                        // half-sheet. The DispatchQueue.main.async hop is the
                        // same — let the half-sheet finish its dismissal
                        // animation before the reader presentation steals the
                        // screen.
                        didChangeState = true
                        DispatchQueue.main.async {
                            viewModel.handleAction(for: type)
                        }
                    case .return:
                        if viewModel.isReturning {
                            didChangeState = true
                            viewModel.handleAction(for: .return)
                        } else {
                            viewModel.bookState = .returning
                        }
                    case .remove,
                         .get, .reserve, .download, .retry, .cancel,
                         .sample, .audiobookSample, .cancelHold,
                         .manageHold, .returning:
                        didChangeState = true
                        viewModel.handleAction(for: type)
                    }
                })
            }
        }
        .padding([.horizontal, .top])
        .padding(.bottom, 40) // SQ-008: ensure Cancel Hold button clears the home indicator safe area
        .accessibleAnimation(.easeInOut(duration: 0.2), value: viewModel.bookState)
        .accessibleAnimation(.easeInOut(duration: 0.2), value: viewModel.buttonState)
        .accessibleAnimation(.easeInOut(duration: 0.15), value: viewModel.downloadProgress)
        .presentationDetents(viewModel.isManagingHold
            ? [.medium, .large]  // SQ-008: Cancel Hold button needs more room than .medium provides
            : [UIDevice.current.isIpad ? .height(540) : .medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(viewModel.isProcessing(for: .returning))
        // Single .alert(item:) — stacking two .alert modifiers on the same
        // view silently suppresses whichever was added first (SwiftUI bug /
        // quirk), which is why the Wi-Fi-required downloadErrorAlert was
        // never rendering on the half-sheet. Priority: downloadErrorAlert
        // takes precedence over showAlert so a late-arriving download error
        // can't be hidden behind a stale confirmation alert.
        .alert(
            item: Binding(
                get: { viewModel.downloadErrorAlert ?? viewModel.showAlert },
                set: { _ in
                    viewModel.downloadErrorAlert = nil
                    viewModel.showAlert = nil
                }
            )
        ) { alertModel in
            if let secondary = alertModel.secondaryButtonTitle {
                Alert(
                    title: Text(alertModel.title),
                    message: Text(alertModel.message),
                    primaryButton: alertModel.isPrimaryDestructive
                        ? .destructive(
                            Text(alertModel.buttonTitle ?? Strings.Generic.ok),
                            action: alertModel.primaryAction
                        )
                        : .default(
                            Text(alertModel.buttonTitle ?? Strings.MyDownloadCenter.retry),
                            action: alertModel.primaryAction
                        ),
                    secondaryButton: .cancel(
                        Text(secondary),
                        action: alertModel.secondaryAction
                    )
                )
            } else {
                Alert(
                    title: Text(alertModel.title),
                    message: Text(alertModel.message),
                    dismissButton: .default(Text(alertModel.buttonTitle ?? Strings.Generic.ok))
                )
            }
        }
        .accessibilityIdentifier(AccessibilityID.BookDetail.halfSheet)
        .onAppear {
            originalState = bookRegistry.state(for: viewModel.book.identifier)
            NotificationCenter.default.post(name: .TPPAccessibilityScreenTransition, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                isBookTitleFocused = true
            }
        }
        .onDisappear {
            // Always sync to latest registry state to avoid reverting the UI after a successful download
            viewModel.bookState = bookRegistry.state(for: viewModel.book.identifier)
            if let cellModel = viewModel as? BookCellModel {
                cellModel.isManagingHold = false
            }
        }
        .onReceive(bookRegistry.bookStatePublisher.receive(on: RunLoop.main)) { identifier, newState in
            // Migrated off `.TPPBookRegistryStateDidChange` to the registry's
            // per-book `bookStatePublisher` (swarm_8ce6f5ae WS3).
            guard identifier == viewModel.book.identifier else { return }

            // Dismiss only when a return/remove fully completed to unregistered
            if viewModel.isReturning && newState == .unregistered {
                // Reset state and dismiss sheet - parent BookDetailView will handle navigation dismissal
                if let cellModel = viewModel as? BookCellModel {
                    cellModel.isManagingHold = false
                }
                dismiss()
            }
        }
    }

    @ViewBuilder private var headerView: some View {
        if viewModel.isReturning || viewModel.isManagingHold {
            VStack(alignment: .leading) {
                Text(
                    viewModel.isManagingHold
                        ? DisplayStrings.manageHold.uppercased()
                        : DisplayStrings.returning.uppercased()
                )
                .font(.subheadline)
                .padding(.top, 8)

                Divider()
                    .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Subviews
private extension HalfSheetView {

    /// Renders the borrow/download progress UI cue. Four states:
    /// 1. Borrow request in flight (registry's processing flag is set, and
    ///    the download itself hasn't started yet) → indeterminate spinner
    ///    + "Borrowing…" label. This is the slow-distributor case (e.g.
    ///    Overdrive) that previously showed an inert 0%-linear bar.
    /// 2. Download running → existing linear bar at the current %.
    /// 3. LCP content re-download running while the book is NOT yet playable
    ///    → same linear bar. The multi-gigabyte `.lcpa` has to land before
    ///    playback in that case, and without this the sheet showed nothing for
    ///    the whole wait, which patrons read as a failure and backed out of.
    /// 4. The same re-download once the book IS playable (Listen is showing,
    ///    because streaming plays it from the license) → idle. The archive is
    ///    then a background prefetch for offline use, and a bar beside a working
    ///    Listen button tells the patron to wait for nothing.
    /// 5. Idle → invisible spacer to preserve layout height.
    var progressCue: HalfSheetProgressCue {
        HalfSheetProgressCue.resolve(
            isBorrowProcessing: viewModel.isBorrowProcessing,
            downloadProgress: viewModel.downloadProgress,
            bookState: viewModel.bookState,
            buttonState: viewModel.buttonState,
            isDownloadingLCPContent: viewModel.isDownloadingLCPContent,
            contentRequiredBeforePlayback: viewModel.contentRequiredBeforePlayback
        )
    }

    @ViewBuilder
    var progressIndicator: some View {
        switch progressCue {
        case .borrowing:
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .controlSize(.small)
                Text(Strings.BookDetailView.borrowingInProgress)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(height: 6)
            .accessibilityIdentifier(AccessibilityID.BookDetail.borrowingProgress)
            .accessibilityLabel(Strings.BookDetailView.borrowingInProgress)
        case .downloading:
            ProgressView(value: viewModel.downloadProgress, total: 1.0)
                .progressViewStyle(LinearProgressViewStyle())
                .frame(height: 6)
                .accessibilityIdentifier(AccessibilityID.BookDetail.downloadProgress)
        case .idle:
            // Reserve consistent space so the layout doesn't jump when the
            // indicator appears/disappears.
            Color.clear
                .frame(height: 6)
        }
    }

    @ViewBuilder
    var bookInfoView: some View {
        VStack(alignment: .leading) {
            Divider()
                .padding(.vertical, 8)

            HStack(alignment: .top, spacing: 16) {
                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 60, height: 90)
                        .cornerRadius(4)
                        .adaptiveShadowLight(radius: 2)
                        .accessibilityHidden(true)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.25))
                        .frame(width: 60, height: 90)
                        .opacity(0.8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.book.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .accessibilityFocused($isBookTitleFocused)

                    if let authors = viewModel.book.authors, !authors.isEmpty {
                        Text(authors)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Divider()
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    var statusInfoView: some View {
        VStack(alignment: .leading) {
            // Exhaustive (no `default:`) so the Swift compiler emits an error
            // when a new TPPBookState case is added without explicit handling.
            // This is the load-bearing protection that would have caught
            // F-011's class of bug: the previous `default:` silently swallowed
            // any missed case. Keep `.unregistered/.holding/.unsupported/
            // .SAMLStarted/.downloadFailed` collapsed into the borrowed-or-
            // holding fallback to match the original behavior.
            switch viewModel.bookState {
            case .downloadSuccessful, .used:
                borrowedInfoView
            case .downloading, .downloadNeeded:
                borrowingInfoView
            case .returning:
                returningInfoView
            case .unregistered, .holding, .unsupported, .SAMLStarted, .downloadFailed:
                if viewModel.isManagingHold {
                    holdingInfoView
                } else {
                    borrowedInfoView
                }
            }
        }
        .frame(minHeight: 50) // Consistent minimum height to prevent layout shifts
    }

    @ViewBuilder
    var holdingInfoView: some View {
        let details = viewModel.book.getReservationDetails()
        if details.holdPosition > 0 {
            if details.copiesAvailable > 0 {
                Text(
                    String(
                        format: DisplayStrings.holdStatus,
                        details.holdPosition.ordinal(),
                        details.copiesAvailable,
                        details.copiesAvailable == 1 ? DisplayStrings.copy : DisplayStrings.copies
                    )
                )
                .font(.footnote)
            } else {
                Text(
                    String(
                        format: DisplayStrings.holdPositionOnly,
                        details.holdPosition.ordinal()
                    )
                )
                .font(.footnote)
            }
        } else {
            Text(
                String(
                    format: DisplayStrings.holdPositionOnly,
                    1.ordinal()
                )
            )
            .font(.footnote)
        }
    }

    @ViewBuilder
    var borrowingInfoView: some View {
        if let timeUntil = viewModel.book.getExpirationDate()?.timeUntil() {
            VStack(alignment: .leading) {
                HStack {
                    Text(DisplayStrings.borrowingFor)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(timeUntil.value) \(timeUntil.unit)")
                        .foregroundStyle(colorScheme == .dark ? Color.palaceSuccessLight : Color.palaceSuccessDark)
                }

                Divider()
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    var borrowedInfoView: some View {
        if let availableUntil = viewModel.book.getExpirationDate()?.monthDayYearString {
            VStack(alignment: .leading) {
                HStack {
                    Text(DisplayStrings.borrowedUntil)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(availableUntil)
                        .foregroundStyle(colorScheme == .dark ? Color.palaceSuccessLight : Color.palaceSuccessDark)
                }

                Divider()
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    var returningInfoView: some View {
        if let expirationDate = viewModel.book.getExpirationDate() {
            VStack(alignment: .leading) {
                HStack {
                    Text("\(DisplayStrings.due) \(expirationDate.monthDayYearString)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(expirationDate.timeUntil().value) \(expirationDate.timeUntil().unit)")
                        .foregroundStyle(colorScheme == .dark ? Color.palaceSuccessLight : Color.palaceSuccessDark)
                }

                Divider()
                    .padding(.vertical, 8)
            }
        }
    }
}
