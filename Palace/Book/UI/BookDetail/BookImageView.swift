import SwiftUI

struct BookImageView: View {
  @ObservedObject var book: TPPBook
  var width: CGFloat? = nil
  var height: CGFloat = 280

  @State private var isShimmering: Bool = true

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      if isShimmering {
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.gray.opacity(0.25))
          .frame(width: width, height: height)
          .overlay(
            ShimmerView(width: width ?? 140, height: height)
              .clipShape(RoundedRectangle(cornerRadius: 8))
          )
          .transition(.opacity)
      }

      if let coverImage = book.coverImage ?? book.thumbnailImage {
        Image(uiImage: coverImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: width, height: height)
          .opacity(isShimmering ? 0 : 1)
          .transition(.opacity)
          .onAppear { withAnimation(.easeInOut(duration: 0.25)) { isShimmering = false } }
      }

      if book.isAudiobook {
        Image(ImageResource.audiobookBadge)
          .resizable()
          .scaledToFit()
          .frame(width: height * 0.12, height: height * 0.12)
          .background(Circle().fill(Color.colorAudiobookBackground))
          .clipShape(Circle())
          .padding([.trailing, .bottom], 10)
      }
    }
    .frame(width: width, height: height)
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
