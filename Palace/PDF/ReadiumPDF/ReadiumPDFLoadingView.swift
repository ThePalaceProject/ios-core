//
//  ReadiumPDFLoadingView.swift
//  Palace
//
//  Shown while the LCP open + first-page render is in flight. Replaces
//  the silent "blank page" the user used to stare at while PDFNavigator
//  walked the PDF cross-ref table through the LCP decrypt layer on a
//  large Marketplace container (hundreds of `Successfully decrypted
//  2064 -> 2048` calls — visible in the log).
//
//  Design intent: dark, cinematic, honest. The book title floats large
//  and faded as a watermark behind a darker overlay; the foreground
//  shows the cover thumbnail, the current pipeline phase, a live
//  decrypted-blocks counter, and an animated linear progress bar. We
//  don't know the denominator (total blocks needed to render page 1
//  varies wildly), so the bar is indeterminate — but the live counter
//  proves forward motion on every block decrypted, which is the
//  honest signal we DO have.
//

import SwiftUI
import PalaceUIKit

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
                .font(.system(size: 56, weight: .heavy, design: .serif))
                .foregroundStyle(.white.opacity(0.08))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 24)

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
                    ProgressView(value: barFillRatio)
                        .progressViewStyle(.linear)
                        .tint(.white.opacity(0.85))
                        .frame(maxWidth: 240)
                        .animation(.easeInOut(duration: 0.4), value: barFillRatio)

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

    /// Bar fill that nudges visibly forward with each decrypt event but
    /// never reaches 100% before the navigator paints the first page.
    /// `1 - exp(-blocks/N)` is monotonically increasing with diminishing
    /// returns, so a user with a small book sees a fast climb and a
    /// user with a huge book sees the bar keep edging upward without
    /// stalling at the same number.
    private var barFillRatio: Double {
        let blocks = Double(progress.decryptedBlocks)
        // Tune so 60 blocks ≈ 50% fill, ~240 blocks ≈ 90% fill.
        return min(0.95, 1.0 - exp(-blocks / 90.0))
    }

    @ViewBuilder
    private var coverThumbnail: some View {
        if let image = book.coverImage {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            // The cover image is loaded lazily by `TPPBookCoverRegistry`
            // and published onto `book.coverImage`. If it hasn't landed
            // yet we show a soft placeholder rather than spinning up an
            // AsyncImage — the cover detail view also drives that
            // registry, so by the time the user reaches the reader the
            // image is usually already in memory.
            Color.white.opacity(0.08)
        }
    }
}

/// SwiftUI bridge to the @MainActor-isolated `LCPPDFOpenProgress.shared`.
/// `ReadiumPDFLoadingView` can't observe the singleton directly because
/// `LCPPDFOpenProgress` is `@MainActor`-isolated and `View.body` is not.
/// This wrapper mirrors the published fields onto a plain
/// `ObservableObject` that the view subscribes to via @StateObject.
@MainActor
private final class ProgressBridge: ObservableObject {
    @Published var statusText: String = NSLocalizedString("Preparing…", comment: "")
    @Published var decryptedBlocks: Int = 0

    private var subscriptions: [AnyObject] = []

    init() {
        let center = LCPPDFOpenProgress.shared
        // Initial snapshot.
        recompute(phase: center.phase, blocks: center.decryptedBlocks, bytes: center.decryptedBytes)

        // Subscribe to changes. Using NotificationCenter would also
        // work, but a direct Combine sink keeps the dependency local.
        subscriptions.append(center.$phase.sink { [weak self, weak center] phase in
            guard let self, let center else { return }
            self.recompute(phase: phase, blocks: center.decryptedBlocks, bytes: center.decryptedBytes)
        })
        subscriptions.append(center.$decryptedBlocks.sink { [weak self, weak center] blocks in
            guard let self, let center else { return }
            self.recompute(phase: center.phase, blocks: blocks, bytes: center.decryptedBytes)
        })
    }

    private func recompute(phase: LCPPDFOpenProgress.Phase, blocks: Int, bytes: Int) {
        decryptedBlocks = blocks
        statusText = Self.statusText(phase: phase, blocks: blocks, bytes: bytes)
    }

    private static func statusText(phase: LCPPDFOpenProgress.Phase, blocks: Int, bytes: Int) -> String {
        switch phase {
        case .idle:
            return NSLocalizedString("Loading…", comment: "")
        case .preparing:
            return NSLocalizedString("Preparing…", comment: "")
        case .openingPublication:
            return NSLocalizedString("Opening publication…", comment: "")
        case .decryptingContent:
            return String(
                format: NSLocalizedString("Decrypting content… %d blocks", comment: ""),
                blocks
            )
        case .loadingFirstPage:
            return blocks > 0
                ? String(
                    format: NSLocalizedString("Rendering first page… %d blocks decrypted", comment: ""),
                    blocks
                  )
                : NSLocalizedString("Rendering first page…", comment: "")
        }
    }
}
