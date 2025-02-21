import SwiftUI

fileprivate typealias DisplayStrings = Strings.BookButton

struct BookButtonsView: View {
  @ObservedObject var viewModel: BookDetailViewModel
  var previewEnabled: Bool = true
  var backgroundColor: Color?
  var size: ButtonSize = .regular
  var onButtonTapped: ((BookButtonType) -> Void)?

  var body: some View {
    let isDarkBackground = backgroundColor?.isDark ?? true

    HStack(spacing: 10) {
      ForEach(viewModel.buttonState.buttonTypes(book: viewModel.book, previewEnabled: previewEnabled), id: \.self) { buttonType in
        ActionButton(type: buttonType, viewModel: viewModel, isDarkBackground: isDarkBackground, size: size, onButtonTapped: onButtonTapped)
          .transition(.asymmetric(insertion: .scale(scale: 0.8).combined(with: .opacity),
                                  removal: .opacity))
      }
    }
    .padding(.vertical)
    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: viewModel.buttonState)
  }
}

struct ActionButton: View {
  let type: BookButtonType
  @ObservedObject var viewModel: BookDetailViewModel
  var isDarkBackground: Bool = true
  var size: ButtonSize = .regular
  var onButtonTapped: ((BookButtonType) -> Void)?

  var body: some View {
    Button(action: {
      HapticFeedback.medium()
      withAnimation {
        onButtonTapped?(type) ?? viewModel.handleAction(for: type)
      }
    }) {
      ZStack {
        if viewModel.isProcessing(for: type) {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
            .tint(type.buttonTextColor(isDarkBackground))
            .transition(.opacity)
        }

        Text(type.title)
          .font(size.font)
          .opacity(viewModel.isProcessing(for: type) ? 0.5 : 1)
          .scaleEffect(viewModel.isProcessing(for: type) ? 0.95 : 1.0)
          .animation(.easeInOut(duration: 0.2), value: viewModel.isProcessing(for: type))
      }
      .padding(size.padding)
      .frame(minWidth: 100, minHeight: size.height)
      .background(type.buttonBackgroundColor(isDarkBackground))
      .foregroundColor(type.buttonTextColor(isDarkBackground))
      .cornerRadius(8)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(type.borderColor(isDarkBackground), lineWidth: type.hasBorder ? 2 : 0)
      )
    }
    .disabled(viewModel.isProcessing(for: type))
    .buttonStyle(.plain)
  }
}

// MARK: - Button Size Enum
enum ButtonSize {
  case regular
  case small

  var height: CGFloat {
    switch self {
    case .regular: return 44
    case .small: return 34
    }
  }

  var font: Font {
    switch self {
    case .regular: return .semiBoldPalaceFont(size: 14)
    case .small: return .semiBoldPalaceFont(size: 12)
    }
  }

  var padding: EdgeInsets {
    switch self {
    case .regular: return EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    case .small: return EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
    }
  }
}

// MARK: - Haptic Feedback Utility
struct HapticFeedback {
  static func medium() {
    let generator = UIImpactFeedbackGenerator(style: .medium)
    generator.prepare()
    generator.impactOccurred()
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

  func buttonBackgroundColor(_ isDarkBackground: Bool) -> Color {
    switch buttonStyle {
    case .primary:
      return isDarkBackground ? .white : .black
    case .secondary, .tertiary:
      return .clear
    }
  }

  func buttonTextColor(_ isDarkBackground: Bool) -> Color {
    switch buttonStyle {
    case .primary:
      return isDarkBackground ? .black : .white
    case .secondary, .tertiary:
      return isDarkBackground ? .white : .black
    }
  }

  func borderColor(_ isDarkBackground: Bool) -> Color {
    return hasBorder ? (isDarkBackground ? .white : .black) : .clear
  }
}

enum ButtonStyleType {
  case primary
  case secondary
  case tertiary
}
