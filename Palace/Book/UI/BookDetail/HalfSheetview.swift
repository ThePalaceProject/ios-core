import SwiftUI

struct HalfSheetView: View {
  typealias DisplayStrings = Strings.BookDetailView
  @Environment(\.colorScheme) var colorScheme
  
  @ObservedObject var viewModel: BookDetailViewModel
  var backgroundColor: Color
  @Binding var coverImage: UIImage?
  
  var body: some View {
    VStack(alignment: .leading, spacing: viewModel.isFullSize ? 20 : 10) {
      
      if viewModel.state == .returning {
        VStack(alignment: .leading) {
          Text(DisplayStrings.returning.uppercased())
            .font(.subheadline)
          
          Divider()
            .padding(.vertical, 8)
        }
      }
      
      Text(AccountsManager.shared.currentAccount?.name ?? "")
        .font(.headline)
      
      bookInfoView
      
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
    .onDisappear {
      if viewModel.buttonState == .returning {
        viewModel.buttonState = .downloadSuccessful
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
      Divider()
        .padding(.vertical, 8)
    }
  }
  
  @ViewBuilder
  var statusInfoView: some View {
    VStack(alignment: .leading) {
      switch viewModel.state {
      case .downloadSuccessful, .used:
        borrowedInfoView
      case .downloading, .downloadNeeded:
        borrowingInfoView
      case .returning:
        returningInfoView
      default:
        if viewModel.buttonState == .holding {
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
