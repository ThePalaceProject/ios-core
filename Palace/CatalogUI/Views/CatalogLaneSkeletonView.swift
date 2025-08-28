import SwiftUI

struct CatalogLaneSkeletonView: View {
  var titleWidth: CGFloat = 120
  var itemSize: CGSize = CGSize(width: 140, height: 200)
  var itemCount: Int = 6

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.gray.opacity(0.25))
        .frame(width: titleWidth, height: 16)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 12) {
          ForEach(0..<itemCount, id: \.self) { _ in
            ShimmerView(width: itemSize.width, height: itemSize.height)
              .frame(width: itemSize.width, height: itemSize.height)
              .clipShape(RoundedRectangle(cornerRadius: 8))
          }
        }
        .padding(.horizontal, 12)
      }
    }
  }
}


