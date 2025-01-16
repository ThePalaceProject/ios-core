import SwiftUI

struct BookDetailView: View {
  @StateObject var viewModel: BookDetailViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {

        viewModel.coverImage
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 160)

        VStack(alignment: .leading, spacing: 8) {
          Text(viewModel.book.title)
            .font(.headline)

          if let subtitle = viewModel.book.subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .font(.subheadline)
              .foregroundColor(.secondary)
          }

          if let authors = viewModel.book.authors, !authors.isEmpty {
            Text(authors)
              .font(.footnote)
              .foregroundColor(.secondary)
          }
        }

        // Book Description
        if let description = viewModel.book.summary {
          VStack(alignment: .leading, spacing: 8) {
            Text("Description")
              .font(.headline)
            Text(description)
              .font(.body)
              .lineLimit(nil)
          }
        }

        // Action Buttons
        HStack(spacing: 16) {
          Button("Start Sample") {
            // Uncomment when toggleSampleView() is implemented
            // viewModel.toggleSampleView()
          }
          Button("Download") {
            // Uncomment when startDownload() is implemented
            // viewModel.startDownload()
          }
        }

        // Download Progress
//        if viewModel.state == .downloading {
//          ProgressView(value: viewModel.downloadProgress)
//            .progressViewStyle(LinearProgressViewStyle())
//        }
      }
      .padding()
    }
    .navigationTitle("Book Details")
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button("Close") {
          // Close action
        }
      }
    }
  }
}
