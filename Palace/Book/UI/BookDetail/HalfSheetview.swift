import SwiftUI
import PalaceBookModel
import PalaceBookRegistry
import PalaceUtilities

/// Which progress cue the half-sheet shows. Extracted from the view so the
/// decision is unit-testable; showing nothing while a multi-gigabyte `.lcpa`
/// transfers makes patrons think the app failed.
enum HalfSheetProgressCue: Equatable {
    /// Borrow request in flight, download not started — indeterminate spinner
    /// plus "Borrowing…" (slow distributors such as Overdrive).
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
    ///     is running. A separate input because that path leaves the book at
    ///     `.downloadSuccessful`, which `bookState` cannot distinguish.
    ///   - contentRequiredBeforePlayback: the archive must land before the book
    ///     can be opened (LCP streaming off, the default). Distinguishes a
    ///     transfer the patron is waiting on from a background prefetch.
    static func resolve(
        isBorrowProcessing: Bool,
        downloadProgress: Double,
        bookState: TPPBookState,
        buttonState: BookButtonState,
        isDownloadingLCPContent: Bool,
        contentRequiredBeforePlayback: Bool
    ) -> HalfSheetProgressCue {
        // Invariant: a progress cue fires only while the patron is waiting to be
        // able to open this book — transfers can outlive that wait. The button
        // states that allow a cue are an allowlist (`mayShowProgressCue`), so a
        // state shows a cue only if it is named there. For example, a bar beside
        // a working Listen button (PP-4957 streaming with PP-5135 fetching the
        // `.lcpa` behind it) would tell the patron to wait for nothing.
        //
        // A book being returned is answered first and unconditionally, before
        // the wait clause below could put a bar onto the Return confirmation.
        if buttonState == .returning { return .idle }

        // A transfer the patron must wait for outranks the allowlist. With LCP
        // streaming off (`lcp_audiobook_streaming_enabled` defaults off),
        // `shouldTriggerContentDownloadBeforeOpen` blocks the open until the
        // archive lands while the book still reads `.downloadSuccessful`.
        if isDownloadingLCPContent && contentRequiredBeforePlayback {
            return .downloading
        }
        guard mayShowProgressCue(buttonState, isBorrowProcessing: isBorrowProcessing) else {
            return .idle
        }
        // Checked before the borrow spinner: borrow stays marked processing
        // across the whole `.lcpa` fetch, which reports zero until its first
        // byte, so the spinner would otherwise show for the entire download.
        if isDownloadingLCPContent {
            return .downloading
        }
        if isBorrowProcessing && downloadProgress == 0 {
            return .borrowing
        }
        if bookState == .downloading {
            return .downloading
        }
        return .idle
    }

    /// Whether a progress cue may fire at all for this button state — i.e.
    /// whether the patron is still waiting to be able to open the book.
    ///
    /// Exhaustive with no `default:`, so a new `BookButtonState` will not
    /// compile until it is classified here.
    private static func mayShowProgressCue(
        _ buttonState: BookButtonState,
        isBorrowProcessing: Bool
    ) -> Bool {
        switch buttonState {
        // Waiting to acquire — a cue is the only signal the patron has, and
        // withholding it is what made the sheet look inert and hung.
        case .downloadInProgress, .downloadNeeded:
            return true
        // A borrow in flight is a wait to acquire. `BorrowOperation` sets the
        // processing flag before `fetchBook` (up to 30s on a slow distributor)
        // and only moves the registry afterwards, so the button still reads
        // `.canBorrow` for the whole round trip.
        case .canBorrow:
            return isBorrowProcessing
        // Already openable: renders Listen / Read.
        case .downloadSuccessful, .used:
            return false
        // Unreachable in practice (`resolve` answers `.returning` first); kept so
        // the switch stays exhaustive without a `default:`.
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
    /// emitting progress.
    var isBorrowProcessing: Bool { get }

    /// `true` while the background `.lcpa` content re-download is running for
    /// this book. A book that is already `.downloadSuccessful` with only its
    /// content missing has no `.downloading` state to drive the usual bar.
    /// Both current providers implement it; `BookCellModel` must, because the
    /// content self-heal fires for books on the My Books shelf.
    var isDownloadingLCPContent: Bool { get }
    /// True when the `.lcpa` must land before the book can be opened — LCP
    /// streaming OFF. See `HalfSheetProgressCue.resolve`.
    ///
    /// Deliberately has no default: `BookCellModel` also presents this sheet,
    /// and a `false` default would show a blank sheet during a required
    /// multi-gigabyte wait. Every conformer must decide.
    var contentRequiredBeforePlayback: Bool { get }

    /// Error alert to present via SwiftUI `.alert` on the half sheet.
    var downloadErrorAlert: AlertModel? { get set }

    /// Confirmation alert (return, cancel-hold) that must render on the
    /// half-sheet so it is visible and interactive (SQ-008).
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
                .accessibilityAddTraits(.isHeader)

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
                        // Async hop lets the half-sheet finish dismissing before
                        // the reader is presented (PP-4161 adds .readStreaming).
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
                        // Async hop lets the half-sheet finish dismissing before
                        // the reader is presented (PP-4161 adds .readStreaming).
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
        // Single .alert(item:): stacking two .alert modifiers on one view
        // suppresses the first one (SwiftUI quirk). downloadErrorAlert takes
        // precedence so a late download error isn't hidden behind a stale
        // confirmation.
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

    /// The borrow/download progress cue; see `HalfSheetProgressCue.resolve`.
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
            // Exhaustive (no `default:`) so a new TPPBookState case fails to
            // compile until it is handled here.
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
                    DisplayStrings.holdStatus(
                        position: details.holdPosition.ordinal(),
                        copiesInUse: details.copiesAvailable
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
