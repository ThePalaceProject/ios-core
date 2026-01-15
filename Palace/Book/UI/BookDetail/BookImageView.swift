import SwiftUI

struct BookImageView: View {
  @ObservedObject var book: TPPBook
  var width: CGFloat? = nil
  var height: CGFloat = 280
  var usePulseSkeleton: Bool = true

  @State private var showSkeleton: Bool = true
  
  /// Check if cover is already loaded (skip skeleton entirely)
  private var hasPreloadedCover: Bool {
    book.coverImage != nil || book.thumbnailImage != nil
  }

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      // Show pulsing skeleton until image is ready
      if showSkeleton && !hasPreloadedCover {
        PulsingSkeletonView(width: width ?? (height * 2.0 / 3.0), height: height)
      }

      if let coverImage = book.coverImage ?? book.thumbnailImage {
        Image(uiImage: coverImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .transition(.opacity)
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
      // Skip skeleton if image already loaded
      if hasPreloadedCover {
        showSkeleton = false
      } else {
        book.fetchCoverImage()
      }
    }
    .onChange(of: book.coverImage) { newImage in
      if newImage != nil {
        withAnimation(.easeOut(duration: 0.2)) {
          showSkeleton = false
        }
      }
    }
    .onChange(of: book.thumbnailImage) { newImage in
      if newImage != nil && book.coverImage == nil {
        withAnimation(.easeOut(duration: 0.2)) {
          showSkeleton = false
        }
      }
    }
  }
}

// MARK: - Pulsing Skeleton

/// Self-contained pulsing skeleton that starts animating immediately on init
private struct PulsingSkeletonView: View {
  let width: CGFloat
  let height: CGFloat
  
  @State private var pulse: Bool = false
  
  var body: some View {
    Rectangle()
      .fill(Color.gray.opacity(0.25))
      .frame(width: width, height: height)
      .opacity(pulse ? 0.6 : 1.0)
      .onAppear {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
          pulse = true
        }
      }
  }
}
