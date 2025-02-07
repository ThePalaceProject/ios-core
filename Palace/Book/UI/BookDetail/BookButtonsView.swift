import SwiftUI

fileprivate typealias DisplayStrings = Strings.BookButton

struct BookButtonsView: View {
  @ObservedObject var viewModel: BookDetailViewModel

  var body: some View {
    HStack(spacing: 10) {
      ForEach(viewModel.buttonState.buttonTypes(book: viewModel.book), id: \.self) { buttonType in
        ActionButton(type: buttonType, viewModel: viewModel, isProcessing: viewModel.isProcessing(for: buttonType))
      }
    }
    .padding(.vertical)
  }
}

struct ActionButton: View {
  let type: BookButtonType
  @ObservedObject var viewModel: BookDetailViewModel
  @Environment(\.colorScheme) var colorScheme
  let isProcessing: Bool

  var body: some View {
    Button(action: {
      viewModel.handleAction(for: type)
    }) {
      ZStack {
        if isProcessing {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: type.buttonTextColor(colorScheme)))
        } else {
          Text(type.title)
            .font(.semiBoldPalaceFont(size: 14))
        }
      }
      .padding()
      .frame(minWidth: 100)
      .background(type.buttonBackgroundColor(colorScheme))
      .foregroundColor(type.buttonTextColor(colorScheme))
      .cornerRadius(8)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(type.borderColor(colorScheme), lineWidth: type.hasBorder ? 2 : 0)
      )
    }
    .buttonStyle(.plain)
    .disabled(isProcessing)
  }
}

extension BookButtonType {
  var title: String {
    switch self {
    case .get: return DisplayStrings.borrow
    case .reserve: return DisplayStrings.placeHold
    case .download: return DisplayStrings.download
    case .return: return DisplayStrings.return
    case .remove: return DisplayStrings.cancelHold
    case .read: return DisplayStrings.read
    case .listen: return DisplayStrings.listen
    case .cancel: return DisplayStrings.cancel
    case .retry: return DisplayStrings.retry
    case .sample, .audiobookSample: return DisplayStrings.preview
    }
  }

  var buttonStyle: ButtonStyleType {
    switch self {
    case .sample, .audiobookSample:
      return .tertiary
    case .get, .reserve, .download, .read, .listen, .retry:
      return .primary
    case .return, .cancel, .remove:
      return .secondary
    }
  }

  var isPrimary: Bool {
    return buttonStyle == .primary
  }

  var hasBorder: Bool {
    return buttonStyle == .secondary
  }

  func buttonBackgroundColor(_ colorScheme: ColorScheme) -> Color {
    switch buttonStyle {
    case .primary:
      return colorScheme == .dark ? .white : .black
    case .secondary, .tertiary:
      return .clear
    }
  }

  func buttonTextColor(_ colorScheme: ColorScheme) -> Color {
    switch buttonStyle {
    case .primary:
      return colorScheme == .dark ? .black : .white
    case .secondary, .tertiary:
      return colorScheme == .dark ? .white : .black
    }
  }

  func borderColor(_ colorScheme: ColorScheme) -> Color {
    return hasBorder ? (colorScheme == .dark ? .white : .black) : .clear
  }
}

enum ButtonStyleType {
  case primary
  case secondary
  case tertiary
}
