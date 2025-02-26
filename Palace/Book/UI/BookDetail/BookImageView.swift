import SwiftUI

struct BookImageView: View {
  @ObservedObject var book: TPPBook
  var height: CGFloat = 280
  var showShimmer: Bool = false
  var shimmerDuration: Double?

  @State private var isShimmering = true

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      if let coverImage = book.coverImage {
        Image(uiImage: coverImage)
          .resizable()
          .scaledToFit()
          .frame(height: height)
          .opacity(isShimmering ? 0 : 1)
          .transition(.opacity)
          .onAppear {
            withAnimation(.easeInOut(duration: 0.6)) {
              isShimmering = false
            }
          }

        if book.isAudiobook {
          Image(ImageResource.audiobookBadge)
            .resizable()
            .scaledToFit()
            .frame(width: height * 0.12, height: height * 0.12)
            .background(Color.red)
            .transition(.opacity)
        }
      }

      if showShimmer && isShimmering {
        ShimmerView(width: 180, height: height)
          .opacity(isShimmering ? 1 : 0)
          .transition(.opacity)
          .onAppear {
            if let duration = shimmerDuration {
              DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                withAnimation(.easeInOut(duration: 0.3)) {
                  isShimmering = false
                }
              }
            }
          }
      }
    }
//    .animation(.easeInOut(duration: 0.5), value: book.coverImage)
  }
}
