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
