import SwiftUI

/// Skeleton placeholder that is a graytone tracing of `CatalogLaneRowView`: a
/// lane header followed by a horizontal row of cover placeholders.
///
/// Every value is pulled 1:1 from the live lane so content lands exactly where
/// the skeleton boxes were (zero layout shift):
///   * `VStack(alignment: .leading, spacing: 5)` — same as the real lane.
///   * Header: a `.title2` line is ~28pt tall (22pt point size). A ~200pt bar
///     (~50% width) at `.padding(.horizontal, 12)` traces `Text(title)
///     .font(.title2)` (the real header's leading inset is also 12).
///   * Scroller: identical `ScrollView(.horizontal)` → `LazyHStack(spacing: 12)`
///     with `.padding(.horizontal, 12)`, each cover `.padding(.vertical)` — a
///     byte-for-byte structural mirror of `CatalogLaneRowView.scroller`.
///   * Cover: `BookImageView(width: nil, height: 150)` reserves its skeleton at
///     `height * 2/3 = 100` wide (the 2:3 portrait modal), so 100×150 matches
///     the width the real layout reserves.
///
/// Note: the real header height is dynamic — a "More…" button forces the row to
/// `minHeight: 44` and a long title wraps up to 3 lines. We trace the common
/// single-line-title case (~28pt); see the header comment.
struct CatalogLaneSkeletonView: View {
    var itemCount: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header — traces `Text(title).font(.title2)` (~28pt line height).
            SkeletonBox(width: 200, height: 28, cornerRadius: PalaceRadius.control)
                .padding(.horizontal, 12)

            // Scroller — mirrors `CatalogLaneRowView.scroller` exactly.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(0..<itemCount, id: \.self) { _ in
                        SkeletonCover(width: 100, height: 150)
                            .padding(.vertical)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Skeleton placeholder that traces `EntryPointsSelectorView` — the segmented
/// "All · Ebooks · Audiobooks" control that renders above the first lane once
/// the grouped catalog feed loads. The initial-load skeleton (`skeletonList`)
/// has no selector of its own, so without this placeholder the first lane sits
/// ~44pt higher in the skeleton than in the loaded state and every lane visibly
/// pops DOWN when the selector appears (PP-4752).
///
/// Geometry is pulled 1:1 from `EntryPointsSelectorView` so the real control
/// lands in exactly the space the placeholder reserved (zero layout shift):
///   * height `placeholderHeight` (44) — the selector's
///     `Picker(.segmented).frame(minHeight: 44)`. The real control has NO
///     vertical padding, so its reserved footprint IS this height.
///   * `.frame(maxWidth: 700)` then centered — same width clamp as the control.
///   * `.padding(.horizontal, 12)` — same leading/trailing inset.
///   * radius `PalaceRadius.control` (8) — the segmented control's pill radius.
///
/// Only trace this where the real selector actually appears: the initial-load
/// skeleton. The switching-entry-point skeleton (`CatalogLoadingView`, driven by
/// `switchingEntryPointView`) already renders the *real* `EntryPointsSelectorView`
/// above it, so it must NOT get a second placeholder.
struct CatalogEntryPointsSkeletonView: View {
    /// The vertical footprint (points) the entry-point selector reserves, and
    /// therefore the height the placeholder must reserve. Mirrors
    /// `EntryPointsSelectorView`'s `Picker(.segmented).frame(minHeight: 44)`
    /// (the control carries no vertical padding). A regression that zeroes or
    /// shrinks this reintroduces the ~44pt lane pop (PP-4752), so it is pinned
    /// by `SkeletonTests`.
    static let placeholderHeight: CGFloat = 44

    var body: some View {
        SkeletonBox(height: Self.placeholderHeight, cornerRadius: PalaceRadius.control)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .accessibilityHidden(true)
    }
}
