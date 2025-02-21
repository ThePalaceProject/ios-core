import SwiftUI

//fileprivate typealias DisplayStrings = Strings.BookButton

//struct BookButtonsView: View {
//  @ObservedObject var viewModel: BookDetailViewModel
//  var previewEnabled: Bool = true
//  var backgroundColor: Color?
//  var size: ButtonSize = .regular
//  var onButtonTapped: ((BookButtonType) -> Void)?
//
//  var body: some View {
//    let isDarkBackground = backgroundColor?.isDark ?? true
//
//    HStack(spacing: 10) {
//      ForEach(viewModel.buttonState.buttonTypes(book: viewModel.book, previewEnabled: previewEnabled), id: \.self) { buttonType in
//        ActionButton(type: buttonType, viewModel: viewModel, isDarkBackground: isDarkBackground, size: size, onButtonTapped: onButtonTapped)
//          .transition(.asymmetric(insertion: .scale(scale: 0.8).combined(with: .opacity),
//                                  removal: .opacity))
//      }
//    }
//    .padding(.vertical)
//    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: viewModel.buttonState)
//  }
//}
//
//struct ActionButton: View {
//  let type: BookButtonType
//  @ObservedObject var viewModel: BookDetailViewModel
//  var isDarkBackground: Bool = true
//  var size: ButtonSize = .regular
//  var onButtonTapped: ((BookButtonType) -> Void)?
//
//  var body: some View {
//    Button(action: {
//      HapticFeedback.medium()
//      withAnimation {
//        onButtonTapped?(type) ?? viewModel.handleAction(for: type)
//      }
//    }) {
//      ZStack {
//        if viewModel.isProcessing(for: type) {
//          ProgressView()
//            .progressViewStyle(CircularProgressViewStyle())
//            .tint(type.buttonTextColor(isDarkBackground))
//            .transition(.opacity)
//        }
//
//        Text(type.title)
//          .font(size.font)
//          .opacity(viewModel.isProcessing(for: type) ? 0.5 : 1)
//          .scaleEffect(viewModel.isProcessing(for: type) ? 0.95 : 1.0)
//          .animation(.easeInOut(duration: 0.2), value: viewModel.isProcessing(for: type))
//      }
//      .padding(size.padding)
//      .frame(minWidth: 100, minHeight: size.height)
//      .background(type.buttonBackgroundColor(isDarkBackground))
//      .foregroundColor(type.buttonTextColor(isDarkBackground))
//      .cornerRadius(8)
//      .overlay(
//        RoundedRectangle(cornerRadius: 8)
//          .stroke(type.borderColor(isDarkBackground), lineWidth: type.hasBorder ? 2 : 0)
//      )
//    }
//    .disabled(viewModel.isProcessing(for: type))
//    .buttonStyle(.plain)
//  }
//}
//
//// MARK: - Button Size Enum
//enum ButtonSize {
//  case regular
//  case small
//
//  var height: CGFloat {
//    switch self {
//    case .regular: return 44
//    case .small: return 34
//    }
//  }
//
//  var font: Font {
//    switch self {
//    case .regular: return .semiBoldPalaceFont(size: 14)
//    case .small: return .semiBoldPalaceFont(size: 12)
//    }
//  }
//
//  var padding: EdgeInsets {
//    switch self {
//    case .regular: return EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
//    case .small: return EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
//    }
//  }
//}
//
//// MARK: - Haptic Feedback Utility
//struct HapticFeedback {
//  static func medium() {
//    let generator = UIImpactFeedbackGenerator(style: .medium)
//    generator.prepare()
//    generator.impactOccurred()
//  }
//}
//

import SwiftUI

fileprivate typealias DisplayStrings = Strings.BookButton

// MARK: - Protocol for Button State Providers
protocol BookButtonProvider: ObservableObject {
  var book: TPPBook { get }
  var buttonTypes: [BookButtonType] { get }
  func handleAction(for type: BookButtonType)
  func indicatorDate(for type: BookButtonType) -> Date?
  func isProcessing(for type: BookButtonType) -> Bool
}

// MARK: - BookButtonsView
struct BookButtonsView<T: BookButtonProvider>: View {
  @ObservedObject var provider: T
  var previewEnabled: Bool = true
  var backgroundColor: Color?
  var size: ButtonSize = .regular
  var onButtonTapped: ((BookButtonType) -> Void)?

  var body: some View {
    let isDarkBackground = backgroundColor?.isDark ?? true

    HStack(spacing: 10) {
      ForEach(provider.buttonTypes, id: \.self) { buttonType in
        ActionButton(
          type: buttonType,
          provider: provider,
          isDarkBackground: isDarkBackground,
          size: size,
          onButtonTapped: onButtonTapped
        )
        .transition(.asymmetric(
          insertion: .scale(scale: 0.8).combined(with: .opacity),
          removal: .opacity
        ))
      }
    }
    .padding(.vertical)
    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: provider.buttonTypes)
  }
}

// MARK: - ActionButton
struct ActionButton<T: BookButtonProvider>: View {
  let type: BookButtonType
  @ObservedObject var provider: T
  var isDarkBackground: Bool = true
  var size: ButtonSize = .regular
  var onButtonTapped: ((BookButtonType) -> Void)?

  private var accessibilityString: String {
    if let untilDate = provider.indicatorDate(for: type)?.timeUntilString(suffixType: .long) {
      return "\(type.title). \(untilDate) remaining"
    }
    return type.title
  }

  var body: some View {
    Button(action: {
      HapticFeedback.medium()
      withAnimation {
        onButtonTapped?(type) ?? provider.handleAction(for: type)
      }
    }) {
      HStack(spacing: 5) {
        indicatorView
        ZStack {
          if provider.isProcessing(for: type) {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle())
              .tint(type.buttonTextColor(isDarkBackground))
              .transition(.opacity)
          }
          Text(type.title)
            .font(size.font)
            .opacity(provider.isProcessing(for: type) ? 0.5 : 1)
            .scaleEffect(provider.isProcessing(for: type) ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: provider.isProcessing(for: type))
        }
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
    .disabled(provider.isProcessing(for: type))
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityString)
  }

  @ViewBuilder private var indicatorView: some View {
    if let untilDate = provider.indicatorDate(for: type)?.timeUntilString(suffixType: .short) {
      VStack(spacing: 2) {
        ImageProviders.MyBooksView.clock
          .resizable()
          .square(length: 14)
        Text(untilDate)
          .palaceFont(size: 9)
      }
      .foregroundColor(type.buttonTextColor(isDarkBackground))
    }
  }
}

// MARK: - Button Size Enum
enum ButtonSize {
  case regular
  case medium
  case small

  var height: CGFloat {
    switch self {
    case .regular: return 44
    case .medium: return 40
    case .small: return 34
    }
  }

  var font: Font {
    switch self {
    case .regular: return .semiBoldPalaceFont(size: 14)
    case .medium: return .semiBoldPalaceFont(size: 13)
    case .small: return .semiBoldPalaceFont(size: 12)
    }
  }

  var padding: EdgeInsets {
    switch self {
    case .regular: return EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    case .medium: return EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
    case .small: return EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
    }
  }
}

struct HapticFeedback {
  static func medium() {
    let generator = UIImpactFeedbackGenerator(style: .medium)
    generator.prepare()
    generator.impactOccurred()
  }
}
