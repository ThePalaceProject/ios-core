import SwiftUI

struct HalfSheetView: View {
  @ObservedObject var viewModel: BookDetailViewModel
  var backgroundColor: Color
  var coverImage: UIImage

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(AccountsManager.shared.currentAccount?.name ?? "")
        .font(.headline)

      Divider()

      bookInfoView

      Divider()

      statusInfoView

      if viewModel.state == .downloading && viewModel.buttonState != .downloadSuccessful {
        ProgressView(value: viewModel.downloadProgress, total: 1.0)
          .progressViewStyle(LinearProgressViewStyle())
          .frame(height: 6)
          .transition(.opacity)
      }

      BookButtonsView(viewModel: viewModel, previewEnabled: false)
        .horizontallyCentered()
    }
    .padding()
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
    .onReceive(viewModel.$state) { _ in
      withAnimation {
      }
    }
  }
}

// MARK: - Subviews
private extension HalfSheetView {
  @ViewBuilder
  var bookInfoView: some View {
    HStack(alignment: .top, spacing: 16) {
      Image(uiImage: coverImage)
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
  }

  @ViewBuilder
  var statusInfoView: some View {
    switch viewModel.state {
    case .downloadSuccessful, .used:
      borrowedInfoView
    case .downloading, .downloadNeeded:
      borrowingInfoView
    default:
      if viewModel.buttonState == .canHold {
        holdingInfoView
      } else {
        borrowedInfoView
      }
    }
  }

  @ViewBuilder
  var holdingInfoView: some View {
    let details = viewModel.book.getReservationDetails()
    VStack {
      Text("Approximately \(details.remainingTime) \(details.timeUnit) wait.")
        .font(.subheadline)
        .fontWeight(.semibold)
      Text("You are \(details.holdPosition.ordinal()) in line. \(details.copiesAvailable) \(details.copiesAvailable == 1 ? "copy" : "copies") in use.")
        .font(.footnote)
    }
  }

  @ViewBuilder
  var borrowingInfoView: some View {
    if let timeUntil = viewModel.book.getExpirationDate()?.timeUntil() {
      HStack {
        Text("Borrowing for")
          .font(.subheadline)
          .foregroundColor(.secondary)
        Spacer()
        Text("\(timeUntil.value) \(timeUntil.unit)")
          .foregroundColor(.palaceSuccessDark)
      }
    }
  }

  @ViewBuilder
  var borrowedInfoView: some View {
    if let availableUntil = viewModel.book.getAvailabilityDetails().availableUntil {
      HStack {
        Text("Borrowed until")
          .font(.subheadline)
          .foregroundColor(.secondary)
        Spacer()
        Text(availableUntil)
          .foregroundColor(.palaceSuccessDark)
      }
    }
  }
}
