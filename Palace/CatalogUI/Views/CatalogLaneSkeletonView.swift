import SwiftUI

struct CatalogLaneSkeletonView: View {
  var titleWidth: CGFloat = 160
  var itemSize: CGSize = CGSize(width: 120, height: 180)
  var itemCount: Int = 8
  @State private var pulse: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Rectangle()
        .fill(Color.gray.opacity(0.25))
        .frame(width: titleWidth, height: 16)
        .opacity(pulse ? 0.6 : 1.0)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 12) {
          ForEach(0..<itemCount, id: \.self) { _ in
            Rectangle()
              .fill(Color.gray.opacity(0.25))
              .frame(width: itemSize.width, height: itemSize.height)
              .opacity(pulse ? 0.6 : 1.0)
          }
        }
        .padding(.horizontal, 12)
      }
    }
    .onAppear {
      withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
        pulse = true
      }
    }
  }
}


