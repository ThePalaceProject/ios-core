import SwiftUI

/// Skeleton row that is a graytone tracing of `NormalBookCell` (the real
/// MyBooks / Holds / search-result row). Every value is pulled 1:1 from
/// `NormalBookCell` so a loaded row and its skeleton have identical height and
/// column positions (zero layout shift):
///   * Outer `HStack(alignment: .center, spacing: 15)` — matches the real cell.
///   * Leading unread-badge gutter: `HStack(spacing: 5)` with a 10pt reserve
///     (the real `unreadImageView` is a 10pt-wide column that reserves its
///     layout width even when the indicator is hidden), then the cover.
///   * Cover: `BookImageView(height: 180).frame(width: cellHeight * 2/3 = 120)`
///     ⇒ 120×180.
///   * Text column mirrors the real right stack: `VStack(spacing: 10)` of
///     [infoView (title 17pt + author 12pt), then a `VStack(spacing: 4)` with a
///     44pt button row (BookButtonsView `minHeight: 44`) + a footnote due/hold
///     line, `.padding(.bottom, 5)`], `.frame(maxWidth: .infinity, .leading)`.
///   * `.padding(5)` + `.frame(minHeight: 180)` — the real cell's `cellHeight`.
///   * iPhone bottom hairline matches `BorderStyleModifier` (1pt gray @0.5).
struct BookRowSkeletonView: View {
    var imageSize: CGSize = CGSize(width: 120, height: 180)

    var body: some View {
        HStack(alignment: .center, spacing: 15) {
            HStack(spacing: 5) {
                // Reserve the unread-badge gutter (10pt) so the cover starts at
                // the same x as the real cell.
                Color.clear.frame(width: 10, height: 10)
                SkeletonCover(width: imageSize.width, height: imageSize.height)
            }

            VStack(alignment: .leading, spacing: 10) {
                // infoView: title (17pt) + author (12pt).
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBox(width: 200, height: 18, cornerRadius: 4)
                    SkeletonBox(width: 130, height: 13, cornerRadius: 4)
                }

                // Button block: a 44pt control (BookButtonsView `minHeight: 44`)
                // + the footnote due-date / hold line, `.padding(.bottom, 5)`.
                VStack(alignment: .leading, spacing: 4) {
                    SkeletonBox(width: 120, height: 44, cornerRadius: PalaceRadius.control)
                    SkeletonBox(width: 150, height: 12, cornerRadius: 4)
                }
                .padding(.bottom, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(5)
        .frame(minHeight: 180)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.gray.opacity(0.5))
                .offset(y: 0.5),
            alignment: .bottom
        )
    }
}

struct BookListSkeletonView: View {
    var rows: Int = 8
    var imageSize: CGSize = CGSize(width: 120, height: 180)

    var body: some View {
        ScrollView {
            // Matches `BookListView`'s `.padding(.horizontal, 12)
            // .padding(.vertical, 12)` so rows align with loaded content.
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { _ in
                    BookRowSkeletonView(imageSize: imageSize)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .accessibilityHidden(true)
    }
}
