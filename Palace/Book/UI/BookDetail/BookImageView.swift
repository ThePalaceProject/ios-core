import SwiftUI

struct BookImageView: View {
  @ObservedObject var book: TPPBook
  var height: CGFloat = 280

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Image(uiImage: book.coverImage)
        .resizable()
        .scaledToFit()
        .frame(height: height)
        .onAppear {
          book.fetchCoverImage()
        }

      if book.isAudiobook {
        Image(ImageResource.audiobookBadge)
          .resizable()
          .scaledToFit()
          .frame(width: height * 0.12, height: height * 0.12)
          .background(Color.red)
      }
    }
  }
}
