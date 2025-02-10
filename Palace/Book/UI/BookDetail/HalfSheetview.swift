import SwiftUI

struct HalfSheetView: View {
  @ObservedObject var viewModel: BookDetailViewModel

  var body: some View {
    VStack(spacing: 20) {
      Text(AccountsManager.shared.currentAccount?.name ?? "")
        .font(.headline)

      Divider()

      HStack(alignment: .top, spacing: 16) {
        Image(uiImage: viewModel.coverImage)
          .resizable()
          .scaledToFit()
          .frame(width: 60, height: 90)
          .cornerRadius(4)

        VStack(alignment: .leading, spacing: 4) {
          Text(viewModel.book.title)
            .font(.body)
            .foregroundColor(.primary)

          if let authors = viewModel.book.authors, !authors.isEmpty {
            Text(authors)
              .font(.subheadline)
              .foregroundColor(.secondary)
          }
        }
        Spacer()
      }

      Divider()

      // Example: "Borrowing for 21 days" or "Borrowed until March 12, 2024"
      if viewModel.state == .downloading || viewModel.state == .downloadNeeded {
        borrowingInfoView
        // Progress bar if downloading
        if viewModel.state == .downloading {
          ProgressView(value: viewModel.downloadProgress, total: 1.0)
            .progressViewStyle(LinearProgressViewStyle())
            .frame(height: 6)
        }
      } else if viewModel.state == .downloadSuccessful || viewModel.state == .used {
        borrowedInfoView
      }

      BookButtonsView(viewModel: viewModel, previewEnabled: false)
    }
    .padding()
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
  }

  @ViewBuilder
  private var borrowingInfoView: some View {
    HStack {
      Text("Borrowing for")
        .foregroundColor(.secondary)
      Spacer()
      Text("21 days") // you could store in viewModel or parse from availability
        .foregroundColor(.green)
    }
  }

  @ViewBuilder
  private var borrowedInfoView: some View {
    HStack {
      Text("Borrowed until")
        .foregroundColor(.secondary)
      Spacer()
      // Example dueDate logic
      Text("March 12, 2024")
        .foregroundColor(.green)
    }
  }
}
