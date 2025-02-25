import SwiftUI

import SwiftUI

struct BookImageView: View {
  @ObservedObject var book: TPPBook
  var height: CGFloat = 280
  var showShimmer: Bool = false
  var shimmerDuration: Double?

  @State private var isShimmering = true

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      if !showShimmer || !isShimmering {
        Image(uiImage: book.coverImage)
          .resizable()
          .scaledToFit()
          .frame(height: height)
          .transition(.opacity)


        if book.isAudiobook {
          Image(ImageResource.audiobookBadge)
            .resizable()
            .scaledToFit()
            .frame(width: height * 0.12, height: height * 0.12)
            .background(Color.red)
        }
      } else {
        ShimmerView(width: 180, height: height)
      }
    }
    .onAppear {
      if showShimmer, let duration = shimmerDuration {
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
          withAnimation(.easeInOut(duration: 0.3)) {
            isShimmering = false
          }
        }
      }
    }
  }
}
