import SwiftUI

struct BookRowSkeletonView: View {
  var imageSize: CGSize = CGSize(width: 100, height: 150)
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.gray.opacity(0.25))
        .frame(width: imageSize.width, height: imageSize.height)
        .overlay(
          ShimmerView(width: imageSize.width, height: imageSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        )

      VStack(alignment: .leading, spacing: 10) {
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.gray.opacity(0.25))
          .frame(width: 180, height: 14)
          .overlay(ShimmerView(width: 180, height: 14).clipShape(RoundedRectangle(cornerRadius: 4)))

        RoundedRectangle(cornerRadius: 4)
          .fill(Color.gray.opacity(0.25))
          .frame(width: 120, height: 12)
          .overlay(ShimmerView(width: 120, height: 12).clipShape(RoundedRectangle(cornerRadius: 4)))
      }
      Spacer()
    }
    .padding(5)
    .overlay(
      Rectangle()
        .frame(height: 1)
        .foregroundColor(Color.gray.opacity(0.5))
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
  }
}


