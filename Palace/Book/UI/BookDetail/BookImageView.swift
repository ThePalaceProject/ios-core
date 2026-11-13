import SwiftUI
import PalaceBookModel

/// Covers are decorative: the surrounding cell or detail header already announces the book (PP-3968, PP-4326).
struct BookImageView: View {
    @ObservedObject var book: TPPBook
    var width: CGFloat?
    var height: CGFloat = 280
    var usePulseSkeleton: Bool = true
    /// Drop shadow radius applied ONLY to the settled cover image — never to the
    /// loading placeholder. Keeping the shadow off the animated placeholder
    /// avoids re-rasterizing 4 shadow layers every frame while it pulses (the
    /// real GPU cost on a full catalog). `nil` = no shadow.
    var coverShadowRadius: CGFloat? = nil

    @State private var showSkeleton: Bool = true
    /// PP-5285 Testing menu toggle; `@AppStorage` so flipping it redraws covers
    /// already on screen.
    @AppStorage(DebugSettings.coverFormatAndDRMLabelsKey) private var showsFormatAndDRMLabels = false

    private var hasPreloadedCover: Bool {
        book.coverImage != nil || book.thumbnailImage != nil
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Show pulsing skeleton until image is ready
            if showSkeleton && !hasPreloadedCover {
                // Shared-clock skeleton (one TimelineView driver, reduce-motion +
                // low-power aware) — replaces the old per-cover repeatForever pulse.
                SkeletonCover(width: width ?? (height * 2.0 / 3.0), height: height)
            }

            if let coverImage = book.coverImage ?? book.thumbnailImage {
                Image(uiImage: coverImage)
                    .resizable()
                    // High-quality resampling + edge antialiasing. Covers can
                    // land at fractional-point frames inside a Lazy stack; without
                    // these the GPU's default minification shimmers/jaggies the
                    // cover edges as the cell scrolls. Paired with the 1:1 decode
                    // in `TPPBookCoverRegistry.decodePixels`, this settles scroll
                    // aliasing on cover art.
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    .modifier(SettledCoverShadow(radius: coverShadowRadius))
                    .transition(.opacity)
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
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            if let labels = CoverDebugLabels.overlay(for: book.acquisitions, enabled: showsFormatAndDRMLabels) {
                CoverDebugLabelsOverlay(labels: labels)
            }
        }
        .accessibilityElement(children: .ignore)
        // The inner Image and badge carry .accessibilityHidden(true), but
        // `.accessibilityElement(children: .ignore)` above promotes the ZStack
        // itself to a single accessibility element, and that promotion
        // overrides the children's hidden flag, so VoiceOver would still stop
        // on the cover. Hiding the ZStack hides the promoted element too.
        .accessibilityHidden(true)
        .frame(width: width, height: height)
        // Cover fades in: `book.coverImage` changes outside any animation
        // context (only the skeleton fade-out was animated), so the cover's
        // `.transition(.opacity)` never fired. Provide the animation context
        // here, keyed on the cover/thumbnail, routed through the reduce-motion
        // aware seam (honors a mid-session Reduce Motion toggle).
        .accessibleAnimation(PalaceMotion.gentle, value: book.coverImage)
        .accessibleAnimation(PalaceMotion.gentle, value: book.thumbnailImage)
        .onAppear {
            if hasPreloadedCover {
                showSkeleton = false
            }
            // fetchCoverImage checks memory cache (instant), then disk cache
            // (async), then network. Covers survive entry point switches via
            // the async disk→memory promotion path.
            book.fetchCoverImage(forDisplayHeight: height)
        }
        .onChange(of: book.coverImage) { _, newImage in
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
        .onChange(of: book.thumbnailImage) { _, newImage in
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

// MARK: - Settled-cover shadow

/// Applies `adaptiveShadow` to the settled cover image only when a radius is
/// provided. Deliberately NOT applied to the loading skeleton: an animated
/// shadow re-rasterizes its (4-layer) blur every frame, which on a full catalog
/// is the dominant GPU cost. The shadow therefore appears once, on the static
/// settled cover, and never animates.
private struct SettledCoverShadow: ViewModifier {
    let radius: CGFloat?

    func body(content: Content) -> some View {
        if let radius {
            content.adaptiveShadow(radius: radius)
        } else {
            content
        }
    }
}
