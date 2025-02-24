import SwiftUI

fileprivate typealias DisplayStrings = Strings.BookButton

protocol BookButtonProvider: ObservableObject {
  var book: TPPBook { get }
  var buttonTypes: [BookButtonType] { get }
  func handleAction(for type: BookButtonType)
  func isProcessing(for type: BookButtonType) -> Bool
}

// MARK: - BookButtonsView
struct BookButtonsView<T: BookButtonProvider>: View {
  @ObservedObject var provider: T
  var previewEnabled: Bool = true
  var backgroundColor: Color?
  var size: ButtonSize = .large
  var onButtonTapped: ((BookButtonType) -> Void)?
  @Environment(\.colorScheme) private var colorScheme

  private var isDarkBackground: Bool {
    backgroundColor?.isDark ?? (colorScheme == .dark)
  }

  var body: some View {
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
  var size: ButtonSize = .large
  var onButtonTapped: ((BookButtonType) -> Void)?

  private var accessibilityString: String {
    return type.title
  }

  var body: some View {
    Button(action: {
      HapticFeedback.medium()
      withAnimation {
        onButtonTapped?(type) ?? provider.handleAction(for: type)
      }
    }) {
      ZStack {
        if provider.isProcessing(for: type) {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
            .tint(type.buttonTextColor(isDarkBackground))
            .transition(.opacity)
        }
        Text(type.title)
          .fixedSize(horizontal: false, vertical: true)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .font(size.font)
          .opacity(provider.isProcessing(for: type) ? 0.5 : 1)
          .scaleEffect(provider.isProcessing(for: type) ? 0.95 : 1.0)
          .animation(.easeInOut(duration: 0.2), value: provider.isProcessing(for: type))
      }
      .padding(size.padding)
      .frame(minHeight: size.height)
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
}

// MARK: - Button Size Enum
enum ButtonSize {
  case large
  case medium
  case small

  var height: CGFloat {
    switch self {
    case .large: return 44
    case .medium: return 40
    case .small: return 34
    }
  }

  var font: Font {
    switch self {
    case .large: return .semiBoldPalaceFont(size: 14)
    case .medium: return .semiBoldPalaceFont(size: 13)
    case .small: return .semiBoldPalaceFont(size: 12)
    }
  }

  var padding: EdgeInsets {
    switch self {
    case .large: return EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
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
