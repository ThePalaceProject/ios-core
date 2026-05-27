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
    }

    private func recompute(from center: LCPPDFOpenProgress) {
        percentComplete = center.percentComplete
        statusText = Self.statusText(phase: center.phase, percent: center.percentComplete)
    }

    /// User-facing status. Show a percentage once we're past the
    /// startup phases — common users care that progress is happening,
    /// not which AES block is being decrypted. Once we're near max,
    /// switch to a "Finishing…" string so the user understands the
    /// bar is about to flip to the reader, not stuck.
    private static func statusText(phase: LCPPDFOpenProgress.Phase, percent: Int) -> String {
        switch phase {
        case .idle:
            return NSLocalizedString("Loading…", comment: "")
        case .preparing, .openingPublication:
            return NSLocalizedString("Preparing book…", comment: "")
        case .decryptingContent, .loadingFirstPage:
            if percent >= 95 {
                return NSLocalizedString("Finishing up…", comment: "")
            }
            return String(
                format: NSLocalizedString("Loading… %d%%", comment: ""),
                percent
            )
        }
    }
}
