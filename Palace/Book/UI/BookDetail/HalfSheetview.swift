import SwiftUI

protocol HalfSheetProvider: ObservableObject, BookButtonProvider {
  var isFullSize: Bool { get }
  var bookState: TPPBookState { get set }
  var buttonState: BookButtonState { get }
  var isReturning: Bool { get }
  var isManagingHold: Bool { get }
  var downloadProgress: Double { get }
  var book: TPPBook { get }
}

extension HalfSheetProvider {
  var isReturning: Bool {
    bookState == .returning
  }
  
  var isManagingHold: Bool {
    switch buttonState {
    case .managingHold, .holding, .holdingFrontOfQueue:
      true
    default:
      false
    }
  }
}

struct HalfSheetView<ViewModel: HalfSheetProvider>: View {
  typealias DisplayStrings = Strings.BookDetailView
  @Environment(\.colorScheme) var colorScheme
  @Environment(\.dismiss) private var dismiss

  @ObservedObject var viewModel: ViewModel
  var backgroundColor: Color
  @Binding var coverImage: UIImage?

  var body: some View {
    VStack(alignment: .leading, spacing: viewModel.isFullSize ? 20 : 10) {

      headerView

      Text(AccountsManager.shared.currentAccount?.name ?? "")
        .font(.headline)

      bookInfoView
      statusInfoView

      if viewModel.bookState == .downloading && viewModel.buttonState != .downloadSuccessful {
        ProgressView(value: viewModel.downloadProgress, total: 1.0)
          .progressViewStyle(LinearProgressViewStyle())
          .frame(height: 6)
          .transition(.opacity)
      }

      if viewModel.isFullSize {
        BookButtonsView(provider: viewModel, previewEnabled: false, onButtonTapped: { type in
          switch type {
          case .close:
            dismiss()
          default:
            viewModel.handleAction(for: type)
          }
        })
          .horizontallyCentered()
      } else {
        BookButtonsView(provider: viewModel, previewEnabled: false, onButtonTapped: { type in
          switch type {
          case .close:
            dismiss()
          default:
            viewModel.handleAction(for: type)
          }
        })
      }
    }
    .padding()
    .presentationDetents([UIDevice.current.isIpad ? .height(540) : .medium])
    .presentationDragIndicator(.visible)
    .onDisappear {
      if viewModel.bookState == .returning {
        viewModel.bookState = .downloadSuccessful
      } else if viewModel.isManagingHold {
        viewModel.bookState = .holding
      }
    }
  }

  @ViewBuilder private var headerView: some View {
    if viewModel.isReturning || viewModel.isManagingHold {
      VStack(alignment: .leading) {
        Text(
          viewModel.isManagingHold
            ? DisplayStrings.manageHold.uppercased()
            : DisplayStrings.returning.uppercased()
        )
        .font(.subheadline)
        .padding(.top, 8)

        Divider()
          .padding(.vertical, 8)
      }
    }
  }
}

// MARK: - Subviews
private extension HalfSheetView {
  @ViewBuilder
  var bookInfoView: some View {
    VStack(alignment: .leading) {
      Divider()
        .padding(.vertical, 8)

      HStack(alignment: .top, spacing: 16) {
        if let coverImage {
          Image(uiImage: coverImage)
            .resizable()
            .scaledToFit()
            .frame(width: 60, height: 90)
            .cornerRadius(4)
        } else {
          RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.25))
            .frame(width: 60, height: 90)
            .opacity(0.8)
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
      Divider()
        .padding(.vertical, 8)
    }
  }

  @ViewBuilder
  var statusInfoView: some View {
    VStack(alignment: .leading) {
      switch viewModel.bookState {
      case .downloadSuccessful, .used:
        borrowedInfoView
      case .downloading, .downloadNeeded:
        borrowingInfoView
      case .returning:
        returningInfoView
      default:
        if viewModel.isManagingHold {
          holdingInfoView
        } else {
          borrowedInfoView
        }
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
      VStack(alignment: .leading) {
        HStack {
          Text(DisplayStrings.borrowingFor)
            .font(.subheadline)
            .foregroundColor(.secondary)
          Spacer()
          Text("\(timeUntil.value) \(timeUntil.unit)")
            .foregroundColor(colorScheme == .dark ? .palaceSuccessLight : .palaceSuccessDark)
        }

        Divider()
          .padding(.vertical, 8)
      }
    }
  }

  @ViewBuilder
  var borrowedInfoView: some View {
    if let availableUntil = viewModel.book.getExpirationDate()?.monthDayYearString {
      VStack(alignment: .leading) {
        HStack {
          Text(DisplayStrings.borrowedUntil)
            .font(.subheadline)
            .foregroundColor(.secondary)
          Spacer()
          Text(availableUntil)
            .foregroundColor(colorScheme == .dark ? .palaceSuccessLight : .palaceSuccessDark)
        }

        Divider()
          .padding(.vertical, 8)
      }
    }
  }

  @ViewBuilder
  var returningInfoView: some View {
    if let expirationDate = viewModel.book.getExpirationDate() {
      VStack(alignment: .leading) {
        HStack {
          Text("\(DisplayStrings.due) \(expirationDate.monthDayYearString)")
            .font(.subheadline)
            .foregroundColor(.secondary)
          Spacer()
          Text("\(expirationDate.timeUntil().value) \(expirationDate.timeUntil().unit)")
            .foregroundColor(colorScheme == .dark ? .palaceSuccessLight : .palaceSuccessDark)
        }

        Divider()
          .padding(.vertical, 8)
      }
    }
  }
}
