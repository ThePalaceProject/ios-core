import SwiftUI

struct BookImageView: View {
  @ObservedObject var book: TPPBook
  var width: CGFloat?
  var height: CGFloat = 280
  var usePulseSkeleton: Bool = false

  @State private var isShimmering: Bool = true
  @State private var pulse: Bool = false

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      if isShimmering {
        Rectangle()
          .fill(Color.gray.opacity(0.25))
          .frame(width: width ?? (height * 2.0 / 3.0), height: height)
          .opacity(usePulseSkeleton ? (pulse ? 0.6 : 1.0) : 1.0)
          .transition(.opacity)
      }

      if let coverImage = book.coverImage ?? book.thumbnailImage {
        Image(uiImage: coverImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
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
      if usePulseSkeleton {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
          pulse = true
        }
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
