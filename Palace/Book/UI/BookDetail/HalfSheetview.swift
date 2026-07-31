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
    static func resolve(
        isBorrowProcessing: Bool,
        downloadProgress: Double,
        bookState: TPPBookState,
        buttonState: BookButtonState,
        isDownloadingLCPContent: Bool
    ) -> HalfSheetProgressCue {
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
        if bookState == .downloading && buttonState != .downloadSuccessful {
            return .downloading
        }
        return .idle
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
    /// `.downloading` state to drive the usual progress bar. Default `false` so
    /// providers that never see this path (e.g. `BookCellModel`) don't have to
    /// opt in mechanically.
    var isDownloadingLCPContent: Bool { get }

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
    /// 3. LCP content re-download running while the book is already
    ///    `.downloadSuccessful` → same linear bar. A multi-gigabyte `.lcpa`
    ///    must land in full before playback (streaming is broken upstream), and
    ///    without this the sheet showed nothing at all for the whole wait,
    ///    which patrons read as a failure and backed out of.
    /// 4. Idle → invisible spacer to preserve layout height.
    var progressCue: HalfSheetProgressCue {
        HalfSheetProgressCue.resolve(
            isBorrowProcessing: viewModel.isBorrowProcessing,
            downloadProgress: viewModel.downloadProgress,
            bookState: viewModel.bookState,
            buttonState: viewModel.buttonState,
            isDownloadingLCPContent: viewModel.isDownloadingLCPContent
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
