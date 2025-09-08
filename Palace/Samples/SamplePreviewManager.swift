import SwiftUI

@MainActor
final class SamplePreviewManager: ObservableObject {
  static let shared = SamplePreviewManager()

  @Published private(set) var currentBookID: String? = nil
  @Published private(set) var toolbar: AudiobookSampleToolbar? = nil

  private init() {}

  func isShowingPreview(for book: TPPBook) -> Bool {
    currentBookID == book.identifier && toolbar != nil
  }

  func toggle(for book: TPPBook) {
    if isShowingPreview(for: book) {
      close()
      return
    }

    guard let toolbarView = AudiobookSampleToolbar(book: book) else {
      close()
      return
    }

    toolbar = toolbarView
    currentBookID = book.identifier
    try? toolbar?.player.playAudiobook()
  }

  func close() {
    if let player = toolbar?.player {
      player.pauseAudiobook()
    }
    toolbar = nil
    currentBookID = nil
  }
}

struct SamplePreviewBarView: View {
  @ObservedObject private var manager = SamplePreviewManager.shared

  var body: some View {
    SwiftUI.Group {
      if let toolbar = manager.toolbar {
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          toolbar
        }
      } else {
        EmptyView()
      }
    }
  }
}


