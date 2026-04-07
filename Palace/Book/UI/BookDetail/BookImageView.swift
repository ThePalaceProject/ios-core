import SwiftUI

struct BookImageView: View {
    @ObservedObject var book: TPPBook
    var width: CGFloat?
    var height: CGFloat = 280
    var usePulseSkeleton: Bool = true
    /// When true, the cover is not announced by VoiceOver (e.g. in list cells where the cell already announces title/author).
    var treatImageAsDecorativeInLists: Bool = false

    @State private var showSkeleton: Bool = true

    /// Check if cover is already loaded (skip skeleton entirely)
    private var hasPreloadedCover: Bool {
        book.coverImage != nil || book.thumbnailImage != nil
    }

    /// Single combined accessibility label for the cover stack. The cover image is always
    /// announced first; if the book is an audiobook, the badge information is appended so
    /// VoiceOver users still hear it without the badge becoming a separate focus target.
    var combinedAccessibilityLabel: String {
        let coverLabel = String(format: NSLocalizedString("Cover image for %@", comment: "Book cover accessibility"), book.title)
        if book.isAudiobook {
            let audiobookLabel = NSLocalizedString("Audiobook", comment: "Audiobook badge accessibility")
            return "\(coverLabel), \(audiobookLabel)"
        }
        return coverLabel
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Show pulsing skeleton until image is ready
            if showSkeleton && !hasPreloadedCover {
                PulsingSkeletonView(width: width ?? (height * 2.0 / 3.0), height: height)
            }

            if let coverImage = book.coverImage ?? book.thumbnailImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
                    // PP-3968: an explicit empty label tells iOS the image is
                    // intentionally undescribed and disables VoiceOver Image
                    // Recognition (text-on-cover OCR), which would otherwise
                    // read printed blurbs/quotes/series-name from cover art.
                    .accessibilityLabel(Text(verbatim: ""))
                    .accessibilityHidden(true)
            }

            if book.isAudiobook {
                Image(ImageResource.audiobookBadge)
                    .resizable()
                    .scaledToFit()
                    .frame(width: height * 0.12, height: height * 0.12)
                    .background(Circle().fill(Color.colorAudiobookBackground))
                    .clipShape(Circle())
                    .padding([.trailing, .bottom], 10)
                    .accessibilityLabel(Text(verbatim: ""))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(treatImageAsDecorativeInLists)
        .accessibilityLabel(combinedAccessibilityLabel)
        .accessibilityAddTraits(.isImage)
        .frame(width: width, height: height)
        .onAppear {
            // Suppress skeleton immediately if something is already available to show
            if hasPreloadedCover {
                showSkeleton = false
            }
            // Always fetch at the correct display size. The registry checks the size-specific
            // cache key first, so this is instant when the right resolution is cached.
            // Without this, a small thumbnail loaded earlier (e.g. catalog lane) would be
            // displayed at full size, causing pixelation on large screens.
            book.fetchCoverImage(forDisplayHeight: height)
        }
        .onChange(of: book.coverImage) { newImage in
            if newImage != nil {
                if UIAccessibility.isReduceMotionEnabled {
                    showSkeleton = false
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showSkeleton = false
                    }
                }
            }
        }
        .onChange(of: book.thumbnailImage) { newImage in
            if newImage != nil && book.coverImage == nil {
                if UIAccessibility.isReduceMotionEnabled {
                    showSkeleton = false
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showSkeleton = false
                    }
                }
            }
        }
    }
}

// MARK: - Pulsing Skeleton

/// Self-contained pulsing skeleton that starts animating immediately on init
private struct PulsingSkeletonView: View {
    let width: CGFloat
    let height: CGFloat

    @State private var pulse: Bool = false

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.25))
            .frame(width: width, height: height)
            .opacity(pulse ? 0.6 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
