import SwiftUI

fileprivate typealias DisplayStrings = Strings.BookButton

struct BookButtonsView: View {
  @ObservedObject var viewModel: BookDetailViewModel

  var body: some View {
    HStack(spacing: 10) {
      ForEach(viewModel.buttonState.buttonTypes(book: viewModel.book), id: \.self) { buttonType in
        ActionButton(type: buttonType, viewModel: viewModel)
      }
    }
    .padding(.vertical)
  }
}

struct ActionButton: View {
  let type: BookButtonType
  @ObservedObject var viewModel: BookDetailViewModel
  @Environment(\.colorScheme) var colorScheme

  var body: some View {
    Button(action: {
      viewModel.handleAction(for: type)
    }) {
      Text(type.title)
        .font(.semiBoldPalaceFont(size: 14))
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
  }
}

extension BookButtonType {
  var title: String {
    switch self {
    case .get: return DisplayStrings.borrow
    case .reserve: return DisplayStrings.placeHold
    case .download: return DisplayStrings.download
    case .return, .remove: return DisplayStrings.return
    case .read: return DisplayStrings.read
    case .listen: return DisplayStrings.listen
    case .cancel: return DisplayStrings.cancelHold
    case .retry: return DisplayStrings.retry
    case .sample, .audiobookSample: return DisplayStrings.preview
    }
  }

  /// Categorizing buttons into Primary, Secondary, and Tertiary
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

  /// Checks if the button is primary
  var isPrimary: Bool {
    return buttonStyle == .primary
  }

  /// Checks if the button is secondary (bordered)
  var hasBorder: Bool {
    return buttonStyle == .secondary
  }

  /// Defines background color based on button style and color scheme
  func buttonBackgroundColor(_ colorScheme: ColorScheme) -> Color {
    switch buttonStyle {
    case .primary:
      return colorScheme == .dark ? .white : .black
    case .secondary, .tertiary:
      return .clear
    }
  }

  /// Defines text color based on button style and color scheme
  func buttonTextColor(_ colorScheme: ColorScheme) -> Color {
    switch buttonStyle {
    case .primary:
      return colorScheme == .dark ? .black : .white
    case .secondary, .tertiary:
      return colorScheme == .dark ? .white : .black
    }
  }

  /// Defines border color for secondary buttons
  func borderColor(_ colorScheme: ColorScheme) -> Color {
    return hasBorder ? (colorScheme == .dark ? .white : .black) : .clear
  }
}

/// Enum to classify button styles
enum ButtonStyleType {
  case primary
  case secondary
  case tertiary
}
