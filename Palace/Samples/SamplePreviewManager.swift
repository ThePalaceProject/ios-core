import SwiftUI

@MainActor
final class SamplePreviewManager: ObservableObject {
    static let shared = SamplePreviewManager()

    @Published private(set) var currentBookID: String?
    @Published private(set) var toolbar: AudiobookSampleToolbar?

    private init() {}

    func isShowingPreview(for book: TPPBook) -> Bool {
        currentBookID == book.identifier && toolbar != nil
    }

    func toggle(for book: TPPBook) {
        if isShowingPreview(for: book) {
            close()
            return
        }

        if book.sampleAcquisition?.type == "text/html" {
            Log.info(#file, "Book '\(book.title)' has text/html preview; " +
                     "web previews should be opened via a web view, not the audio toolbar")
            return
        }

        close()

        guard let toolbarView = AudiobookSampleToolbar(book: book) else {
            Log.warn(#file, "Could not create sample toolbar for '\(book.title)' " +
                     "(contentType=\(book.defaultBookContentType.rawValue), " +
                     "sampleAcq=\(book.sampleAcquisition?.type ?? "nil"), " +
                     "previewLink=\(book.previewLink?.type ?? "nil"))")
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
