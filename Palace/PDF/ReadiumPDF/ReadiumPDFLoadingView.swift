//
//  ReadiumPDFLoadingView.swift
//  Palace
//
//  Shown while an LCP PDF open and first-page render is in flight, which can
//  take a while on large containers. Title watermark behind a dark overlay,
//  with the cover, the current pipeline phase and a progress bar in front.
//

import SwiftUI
import PalaceUIKit
import PalaceBookModel

struct ReadiumPDFLoadingView: View {
    let book: TPPBook

    @StateObject private var progress = ProgressBridge()

    var body: some View {
        ZStack {
            // Dark, deep background. Slightly lighter at the top so
            // the title watermark has somewhere to sit visually.
            LinearGradient(
                colors: [Color(white: 0.08), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Title as a faded watermark behind the foreground content.
            // Large display weight, low opacity — present but not loud.
            Text(book.title)
                // Display watermark sized to the screen rather than to body
                // copy: it already shrinks to 50% to fit four lines, and the
                // same title is repeated below in a Dynamic-Type .headline.
                // accesslint:disable A11Y.SWIFTUI.FIXED_FONT - fixed display geometry
                .font(.system(size: 56, weight: .heavy, design: .serif))
                .foregroundStyle(.white.opacity(0.08))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 24)
                .accessibilityHidden(true)

            VStack(spacing: 24) {
                Spacer()
                coverThumbnail
                    .frame(width: 140, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.6), radius: 12, y: 6)

                VStack(spacing: 6) {
                    Text(book.title)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if let authors = book.authors, !authors.isEmpty {
                        Text(authors)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 32)

                VStack(spacing: 10) {
                    ProgressView(value: Double(progress.percentComplete) / 100.0)
                        .progressViewStyle(.linear)
                        .tint(.white.opacity(0.85))
                        .frame(maxWidth: 240)
                        .animation(.easeInOut(duration: 0.4), value: progress.percentComplete)

                    Text(progress.statusText)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(.vertical, 32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title), \(progress.statusText)")
    }

    @ViewBuilder
    private var coverThumbnail: some View {
        if let image = book.coverImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        } else {
            // Placeholder until `book.coverImage` lands; it is usually already
            // in memory from the detail view.
            Color.white.opacity(0.08)
        }
    }
}

/// Mirrors `LCPPDFOpenProgress.shared`'s published fields onto an
/// `ObservableObject` the view can hold as a `@StateObject`.
@MainActor
private final class ProgressBridge: ObservableObject {
    @Published var statusText: String = NSLocalizedString("Loading…", comment: "")
    @Published var percentComplete: Int = 0

    private var subscriptions: [AnyObject] = []

    init() {
        let center = LCPPDFOpenProgress.shared
        recompute(from: center)

        subscriptions.append(center.$phase.sink { [weak self, weak center] _ in
            guard let self, let center else { return }
            self.recompute(from: center)
        })
        subscriptions.append(center.$decryptedBlocks.sink { [weak self, weak center] _ in
            guard let self, let center else { return }
            self.recompute(from: center)
        })
        subscriptions.append(center.$cachedHits.sink { [weak self, weak center] _ in
            guard let self, let center else { return }
            self.recompute(from: center)
        })
        subscriptions.append(center.$bytesExtracted.sink { [weak self, weak center] _ in
            guard let self, let center else { return }
            self.recompute(from: center)
        })
        subscriptions.append(center.$totalExtractBytes.sink { [weak self, weak center] _ in
            guard let self, let center else { return }
            self.recompute(from: center)
        })
    }

    private func recompute(from center: LCPPDFOpenProgress) {
        percentComplete = center.percentComplete
        statusText = Self.statusText(phase: center.phase, percent: center.percentComplete)
    }

    /// User-facing status: a percentage after the startup phases, then
    /// "Finishing…" near the end so the bar does not look stuck.
    private static func statusText(phase: LCPPDFOpenProgress.Phase, percent: Int) -> String {
        switch phase {
        case .idle:
            return NSLocalizedString("Loading…", comment: "")
        case .preparing, .openingPublication:
            return NSLocalizedString("Preparing book…", comment: "")
        case .decryptingContent, .extractingToDisk, .loadingFirstPage:
            if percent >= 99 {
                return NSLocalizedString("Finishing up…", comment: "")
            }
            return String(
                format: NSLocalizedString("Loading… %d%%", comment: ""),
                percent
            )
        }
    }
}
