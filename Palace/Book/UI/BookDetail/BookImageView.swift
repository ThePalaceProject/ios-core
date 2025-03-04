import SwiftUI

struct BookImageView: View {
  @ObservedObject var book: TPPBook
  var height: CGFloat = 280
  var showShimmer: Bool = true
  var shimmerDuration: Double? = nil

  @State private var isShimmering: Bool = true

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      if let coverImage = book.coverImage ?? book.thumbnailImage {
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
            .background(Circle().fill(Color.colorAudiobookBackground))
            .clipShape(Circle())
            .padding([.trailing, .bottom], 5)
        }
      }

      if showShimmer && isShimmering {
        ShimmerView(width: 180, height: height)
          .opacity(isShimmering ? 1 : 0)
          .transition(.opacity)
      }
    }
    .onAppear {
      if book.coverImage == nil && book.thumbnailImage == nil {
        book.fetchCoverImage()
      }
    }
    .onChange(of: book.coverImage) { newImage in
      if newImage != nil {
        withAnimation(.easeInOut(duration: 0.3)) {
          isShimmering = false
        }
      }
    }
    .onChange(of: book.thumbnailImage) { newImage in
      if newImage != nil && book.coverImage == nil {
        withAnimation(.easeInOut(duration: 0.3)) {
          isShimmering = false
        }
      }
    }
  }
}
