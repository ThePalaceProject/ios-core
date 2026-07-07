import SwiftUI

/// Skeleton placeholder matching the layout of `CatalogLaneRowView`: a lane
/// title followed by a horizontal row of cover placeholders.
///
/// Built on the unified `Skeleton` primitives so the base color, card radius,
/// and diagonal shimmer match every other skeleton. Measurements mirror the
/// live lane (title left-aligned at x=12, 100×150 covers, 12pt spacing).
struct CatalogLaneSkeletonView: View {
    var itemCount: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SkeletonBox(width: 200, height: 26, cornerRadius: PalaceRadius.control)
                .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<itemCount, id: \.self) { _ in
                        SkeletonCover(width: 100, height: 150)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical)
            }
        }
        .accessibilityHidden(true)
    }
}
