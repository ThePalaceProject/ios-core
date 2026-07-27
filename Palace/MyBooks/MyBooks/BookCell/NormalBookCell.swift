//
//  NormalBookCell.swift
//  Palace
//
//  Created by Maurice Carrier on 2/8/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine
import PalaceUIKit
import PalaceBookModel

struct NormalBookCell: View {
    @Environment(\.colorScheme) var colorScheme
    @State var showHalfSheet: Bool = false

    @ObservedObject var model: BookCellModel
    var previewEnabled: Bool = true
    private let cellHeight: CGFloat = 180

    // Download progress tracking
    @State private var downloadProgress: Double = 0.0

    // Download-complete "moment" (display-only celebration; no download logic).
    /// Drives a one-shot scale pulse on the incoming Read button.
    @State private var readButtonPulseActive: Bool = false
    /// Monotonic counter that triggers the success haptic exactly once per
    /// download-complete transition (via `.palaceHaptic(.success, trigger:)`).
    @State private var downloadCompleteHaptic: Int = 0

    /// Check download state directly from stableButtonState (source of truth for SwiftUI)
    private var isDownloading: Bool {
        model.stableButtonState == .downloadInProgress
    }

    private var isDownloadFailed: Bool {
        model.stableButtonState == .downloadFailed
    }

    /// Pure transition detector for the download-complete celebration: true only
    /// on the transition INTO `.downloadSuccessful` (not while already in it, and
    /// not for any other state). Display-only trigger; carries no download logic.
    static func shouldPulseReadButton(previous: BookButtonState, current: BookButtonState) -> Bool {
        current == .downloadSuccessful && previous != .downloadSuccessful
    }

    /// Pure seam (PP-4748): the progress bar tracks a max-seen high-water mark
    /// (`max(downloadProgress, progress)`), which strands the bar at the previous
    /// download's high after a cancel→retry. Returns true exactly on the
    /// transition INTO the downloading state (false→true), signalling a reset of
    /// the display value to 0. Display-only; carries no download machinery.
    static func shouldResetDownloadProgress(wasDownloading: Bool, isDownloading: Bool) -> Bool {
        isDownloading && !wasDownloading
    }

    var body: some View {
        ZStack {
            HStack(alignment: .center, spacing: 15) {
                HStack(spacing: 5) {
                    unreadImageView
                    titleCoverImageView
                }
                .frame(alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    infoView
                    VStack(alignment: .leading, spacing: 4) {
                        downloadProgressView
                        buttons
                            // One-shot scale pulse when the download completes.
                            .scaleEffect(readButtonPulseActive ? 1.06 : 1.0)
                            .accessibleAnimation(PalaceMotion.emphasized, value: readButtonPulseActive)
                        borrowedInfoView
                    }
                    .padding(.bottom, 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .sheet(isPresented: $showHalfSheet, onDismiss: {
                    model.showHalfSheet = false
                    model.isManagingHold = false  // Reset managing hold state when sheet is dismissed
                }, content: {
                    HalfSheetView(
                        viewModel: model,
                        backgroundColor: Color(model.book.dominantUIColor),
                        coverImage: $model.book.coverImage
                    )
                })
                .alert(item: $model.showAlert) { alert in
                    if alert.secondaryButtonTitle != nil {
                        Alert(
                            title: Text(alert.title),
                            message: Text(alert.message),
                            primaryButton: .default(
                                Text(alert.buttonTitle ?? Strings.MyDownloadCenter.retry),
                                action: alert.primaryAction
                            ),
                            secondaryButton: .cancel(
                                Text(alert.secondaryButtonTitle ?? Strings.Generic.cancel),
                                action: alert.secondaryAction
                            )
                        )
                    } else {
                        Alert(
                            title: Text(alert.title),
                            message: Text(alert.message),
                            dismissButton: .default(
                                Text(alert.buttonTitle ?? Strings.Generic.ok),
                                action: alert.primaryAction
                            )
                        )
                    }
                }
            }

            // Gentle download overlay
            downloadOverlay
        }
        .multilineTextAlignment(.leading)
        .padding(5)
        .frame(minHeight: cellHeight)
        // Activate the (previously dead) progress-bar & dim-overlay transitions:
        // `stableButtonState` is assigned via a Combine `.assign` with no
        // animation context, so the declared `.transition(...)` on
        // downloadProgressView / downloadOverlay never fired. Provide the
        // animation context here (display-layer only — no download logic),
        // routed through the reduce-motion-aware seam.
        .accessibleAnimation(PalaceMotion.standard, value: model.stableButtonState)
        // Download-complete moment: pref-gated success haptic + one-shot scale
        // pulse fired only on the transition INTO `.downloadSuccessful`. Reads
        // `stableButtonState` only — no download machinery is touched.
        .palaceHaptic(.success, trigger: downloadCompleteHaptic)
        .onChange(of: model.stableButtonState) { oldValue, newValue in
            // Bug PP-4748: reset the progress high-water mark on entry into the
            // downloading state so a cancel→retry doesn't strand the bar at the
            // previous download's max. Display-only; no download machinery.
            if Self.shouldResetDownloadProgress(
                wasDownloading: oldValue == .downloadInProgress,
                isDownloading: newValue == .downloadInProgress
            ) {
                downloadProgress = 0
            }
            guard Self.shouldPulseReadButton(previous: oldValue, current: newValue) else { return }
            downloadCompleteHaptic &+= 1
            readButtonPulseActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                readButtonPulseActive = false
            }
        }
        .onDisappear { model.isLoading = false }
        .onReceive(downloadProgressPublisher) { progress in
            accessibleWithAnimation(.easeInOut(duration: 0.15)) {
                // Clamp to max-seen-so-far to prevent progress bar from sliding backwards
                downloadProgress = max(downloadProgress, progress)
            }
        }
        .onAppear {
            // Initialize with current progress if downloading
            if isDownloading {
                downloadProgress = model.downloadCenter.downloadProgress(for: model.book.identifier)
            }
        }
    }

    // MARK: - Download Progress Publisher

    private var downloadProgressPublisher: AnyPublisher<Double, Never> {
        model.downloadCenter.downloadProgressPublisher
            .filter { [model] (update: (String, Double)) in
                update.0 == model.book.identifier
            }
            .map { (update: (String, Double)) in
                update.1
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    @ViewBuilder private var titleCoverImageView: some View {
        BookImageView(book: model.book, width: nil, height: cellHeight, treatImageAsDecorativeInLists: true)
            .adaptiveShadowLight(radius: 1.5)
            .frame(width: cellHeight * 2.0 / 3.0)
    }

    // MARK: - Download Progress View

    /// Threshold below which we show "Requesting..." instead of progress bar
    /// This handles the checkout→download transition where progress resets
    private let progressThreshold: Double = 0.03

    /// Whether we have meaningful download progress (above threshold, below complete)
    private var hasMeaningfulProgress: Bool {
        downloadProgress >= progressThreshold && downloadProgress < 0.99
    }

    @ViewBuilder private var downloadProgressView: some View {
        if isDownloading {
            VStack(alignment: .leading, spacing: 2) {
                if hasMeaningfulProgress {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 4)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(TPPConfiguration.mainColor()))
                                .frame(width: geometry.size.width * downloadProgress, height: 4)
                        }
                    }
                    .frame(height: 4)
                } else {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.DownloadAnnouncements.downloadingTitle(model.book.title))
            .accessibilityValue(
                hasMeaningfulProgress
                    ? Strings.DownloadAnnouncements.percentComplete(Int(downloadProgress * 100))
                    : Strings.BookCell.downloading
            )
            .accessibilityIdentifier( AccessibilityID.BookDetail.downloadProgress)
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if isDownloadFailed {
            Text(Strings.BookCell.downloadFailedMessage)
                .palaceFont(size: 11)
                .foregroundStyle(.red)
                .padding(.bottom, 4)
                .transition(.opacity)
        }
    }

    // MARK: - Download Overlay

    @ViewBuilder private var downloadOverlay: some View {
        if isDownloading {
            Color.black.opacity(0.08)
                .allowsHitTesting(false)
                .transition(.opacity)
        } else if isDownloadFailed {
            Color.black.opacity(0.15)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var infoView: some View {
        VStack(alignment: .leading) {
            Text(model.title)
                .lineLimit(2)
                .palaceFont(size: 17)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(model.book.defaultBookContentType == .audiobook ? "\(model.book.title). Audiobook." : model.book.title)
            Text(model.authors)
                .palaceFont(size: 12)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttonSize: ButtonSize {
        UIDevice.current.isIpad && UIDevice.current.orientation != .portrait ? .small : .medium
    }

    @ViewBuilder private var buttons: some View {
        BookButtonsView(provider: model, previewEnabled: previewEnabled, size: buttonSize) { type in
            // Exhaustive (no `default:`) — F-011 class-of-bug guard. Compiler
            // flags this site if BookButtonType gains a case, so a button
            // can't silently route to the callDelegate fallback.
            switch type {
            case .close:
                accessibleWithAnimation(.spring()) { self.showHalfSheet = false }
            case .get, .reserve, .download, .read, .listen, .retry, .cancel,
                 .sample, .audiobookSample, .remove, .cancelHold,
                 .manageHold, .return, .returning, .readStreaming:
                model.callDelegate(for: type)
                accessibleWithAnimation(.spring()) { self.showHalfSheet = model.showHalfSheet }
            }
        }
    }

    @ViewBuilder private var unreadImageView: some View {
        VStack {
            ImageProviders.MyBooksView.unreadBadge
                .frame(width: 10, height: 10)
                .foregroundStyle(Color(TPPConfiguration.accentColor()))
            Spacer()
        }
        .opacity(model.showUnreadIndicator ? 1.0 : 0.0)
        .accessibilityHidden(true)
    }

    @ViewBuilder var borrowedInfoView: some View {
        if model.registryState == .holding {
            holdingInfoView
        } else {
            loanTermsInfoView
        }
    }

    @ViewBuilder var holdingInfoView: some View {
        let details = model.book.getReservationDetails()
        if details.holdPosition > 0 {
            if details.copiesAvailable > 0 {
                Text(
                    String(
                        format: Strings.BookDetailView.holdStatus,
                        details.holdPosition.ordinal(),
                        details.copiesAvailable,
                        details.copiesAvailable == 1 ? Strings.BookDetailView.copy : Strings.BookDetailView.copies
                    )
                )
                .font(.footnote)
            } else {
                Text(
                    String(
                        format: Strings.BookDetailView.holdPositionOnly,
                        details.holdPosition.ordinal()
                    )
                )
                .font(.footnote)
            }
        } else {
            Text(
                String(
                    format: Strings.BookDetailView.holdPositionOnly,
                    1.ordinal()
                )
            )
            .font(.footnote)
        }
    }

    @ViewBuilder var loanTermsInfoView: some View {
        if let expirationDate = model.book.getExpirationDate() {
            HStack(alignment: .bottom, spacing: 10) {
                Text("Due \(expirationDate.monthDayYearString)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(expirationDate.timeUntil().value) \(expirationDate.timeUntil().unit)")
                    .foregroundStyle(colorScheme == .dark ? Color.palaceSuccessLight : Color.palaceSuccessDark)
            }
            .palaceFont(size: 12)
            .minimumScaleFactor(0.8)
            .padding(.trailing)
        }
    }
}
