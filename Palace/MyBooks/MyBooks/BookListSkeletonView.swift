import SwiftUI

/// Skeleton row mirroring the real MyBooks book cell: a cover on the left, a
/// title + author + a short button-shaped block on the right. Built on the
/// unified `Skeleton` primitives so the base color, radii, and diagonal shimmer
/// match every other skeleton in the app.
struct BookRowSkeletonView: View {
    var imageSize: CGSize = CGSize(width: 100, height: 150)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SkeletonCover(width: imageSize.width, height: imageSize.height)

            VStack(alignment: .leading, spacing: 10) {
                // Title — wider, heavier line.
                SkeletonBox(width: 180, height: 14, cornerRadius: 4)
                // Author — shorter, lighter line.
                SkeletonBox(width: 120, height: 12, cornerRadius: 4)

                Spacer(minLength: 8)

                // A button-shaped placeholder where the Read/Download control sits.
                SkeletonBox(width: 96, height: 32, cornerRadius: PalaceRadius.control)
            }
            Spacer()
        }
        .padding(5)
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
    var imageSize: CGSize = CGSize(width: 100, height: 150)

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { _ in
                    BookRowSkeletonView(imageSize: imageSize)
                }
            }
            .padding()
        }
        .accessibilityHidden(true)
    }
}
