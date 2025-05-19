import SwiftUI

struct HalfSheetView: View {
  typealias DisplayStrings = Strings.BookDetailView
  @Environment(\.colorScheme) var colorScheme

  @ObservedObject var viewModel: BookDetailViewModel
  var backgroundColor: Color
  @Binding var coverImage: UIImage?

  var body: some View {
    VStack(alignment: .leading, spacing: viewModel.isFullSize ? 20 : 10) {
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

      if viewModel.isFullSize {
        BookButtonsView(provider: viewModel, previewEnabled: false)
          .horizontallyCentered()
      } else {
        BookButtonsView(provider: viewModel, previewEnabled: false)
      }
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
      if let coverImage {
        Image(uiImage: coverImage)
          .resizable()
          .scaledToFit()
          .frame(width: 60, height: 90)
          .cornerRadius(4)
      } else {
        ShimmerView(width: 60, height: 90)
      }

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
      if viewModel.buttonState == .holding {
        holdingInfoView
      } else {
        borrowedInfoView
      }
    }
  }

  @ViewBuilder
  var holdingInfoView: some View {
    let details = viewModel.book.getReservationDetails()
    Text(
      String(
        format: DisplayStrings.holdStatus,
        details.holdPosition.ordinal(),
        details.copiesAvailable,
        details.copiesAvailable == 1 ? DisplayStrings.copy : DisplayStrings.copies
      )
    )
    .font(.footnote)
  }

  @ViewBuilder
  var borrowingInfoView: some View {
    if let timeUntil = viewModel.book.getExpirationDate()?.timeUntil() {
      HStack {
        Text(DisplayStrings.borrowingFor)
          .font(.subheadline)
          .foregroundColor(.secondary)
        Spacer()
        Text("\(timeUntil.value) \(timeUntil.unit)")
        .foregroundColor(colorScheme == .dark ? .palaceSuccessLight : .palaceSuccessDark)
      }
    }
  }

  @ViewBuilder
  var borrowedInfoView: some View {
    if let availableUntil = viewModel.book.getExpirationDate()?.timeUntil() {
      HStack {
        Text(DisplayStrings.borrowedFor)
          .font(.subheadline)
          .foregroundColor(.secondary)
        Spacer()
        Text("\(availableUntil.value) \(availableUntil.unit)")
          .foregroundColor(colorScheme == .dark ? .palaceSuccessLight : .palaceSuccessDark)
      }
    }
  }
}
