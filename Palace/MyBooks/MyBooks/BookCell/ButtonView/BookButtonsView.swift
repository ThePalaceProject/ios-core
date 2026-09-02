import SwiftUI
import PalaceBookModel

private typealias DisplayStrings = Strings.BookButton

@MainActor
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

    private var filteredButtonTypes: [BookButtonType] {
        guard !previewEnabled else { return provider.buttonTypes }
        return provider.buttonTypes.filter { $0 != .sample && $0 != .audiobookSample }
    }

    var body: some View {
        HStack(spacing: size.buttonSpacing) {
            ForEach(filteredButtonTypes, id: \.self) { buttonType in
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
        .accessibleAnimation(.spring(response: 0.4, dampingFraction: 0.7), value: filteredButtonTypes)
    }
}

// MARK: - Tap debounce

/// Decides whether a repeat press on the same control should be delivered.
///
/// PP-5063: none of the book action buttons debounced. Five quick taps on
/// Borrow started five borrows; three on Remove sent three returns. The action
/// buttons show a spinner via `isProcessing`, but they were never disabled and
/// `isProcessing` only flips once the action has already been dispatched — so
/// every tap inside that window was delivered.
///
/// Time-based rather than state-based on purpose. Gating on
/// `provider.isProcessing` would leave a button permanently dead if processing
/// state ever failed to clear, which is a known failure mode on this path; a
/// window that expires on its own cannot strand a control.
///
/// This addresses repeat presses on the SAME control. It does not address a
/// tap landing on a DIFFERENT control after the first press reflows or pops the
/// view — that is a navigation-level problem and is out of scope here.
enum ButtonTapDebounce {

    /// Presses closer together than this are treated as one.
    ///
    /// 400ms: comfortably longer than an accidental double-tap or a stutter
    /// from an unresponsive-feeling screen, comfortably shorter than a
    /// deliberate second press (a patron cancelling and re-borrowing is not
    /// doing it inside half a second).
    static let window: TimeInterval = 0.4

    /// `true` when this press should be delivered.
    /// - Parameters:
    ///   - now: the incoming press.
    ///   - lastAccepted: the last press that was delivered, or `nil` if none.
    static func shouldAccept(now: TimeInterval, lastAccepted: TimeInterval?) -> Bool {
        guard let lastAccepted else { return true }
        return (now - lastAccepted) >= window
    }
}

// MARK: - ActionButton
struct ActionButton<T: BookButtonProvider>: View {
    let type: BookButtonType
    @ObservedObject var provider: T
    var isDarkBackground: Bool = true
    var size: ButtonSize = .large
    var onButtonTapped: ((BookButtonType) -> Void)?

    @ObservedObject private var previewManager = AppContainer.production().samplePreviewManager

    private var buttonTitle: String {
        type.title(for: provider.book)
    }

    private var accessibilityString: String {
        return buttonTitle
    }

    private var accessibilityID: String {
        switch type {
        case .get:
            return AccessibilityID.BookDetail.getButton
        case .download:
            return AccessibilityID.BookDetail.downloadButton
        case .read:
            return AccessibilityID.BookDetail.readButton
        case .listen:
            return AccessibilityID.BookDetail.listenButton
        case .readStreaming:
            // PP-4161: distinct identifier from `readButton` so a simdrive
            // journey can disambiguate "open EPUB reader" from "open streaming
            // web reader" at the accessibility-tree level.
            return AccessibilityID.BookDetail.readStreamingButton
        case .remove:
            return AccessibilityID.BookDetail.deleteButton
        case .return:
            return AccessibilityID.BookDetail.returnButton
        case .reserve:
            return AccessibilityID.BookDetail.reserveButton
        case .cancel:
            return AccessibilityID.BookDetail.cancelButton
        case .retry:
            return AccessibilityID.BookDetail.retryButton
        case .manageHold:
            return AccessibilityID.BookDetail.manageHoldButton
        case .sample:
            return AccessibilityID.BookDetail.sampleButton
        case .audiobookSample:
            return AccessibilityID.BookDetail.audiobookSampleButton
        case .returning, .cancelHold:
            return AccessibilityID.BookDetail.returnButton
        case .close:
            return AccessibilityID.Common.closeButton
        }
    }

    /// Timestamp of the last press this button actually delivered.
    /// Per-button, so debouncing Borrow never suppresses Remove.
    @State private var lastAcceptedTap: TimeInterval?

    var body: some View {
        Button(action: {
            // PP-5063: swallow repeat presses inside the debounce window.
            let now = Date().timeIntervalSinceReferenceDate
            guard ButtonTapDebounce.shouldAccept(now: now, lastAccepted: lastAcceptedTap) else { return }
            lastAcceptedTap = now

            HapticFeedback.medium()
            withAnimation(UIAccessibility.isReduceMotionEnabled ? .none : .default) {
                onButtonTapped?(type) ?? provider.handleAction(for: type)
            }
        }, label: {
            ZStack {
                if provider.isProcessing(for: type) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .tint(type.buttonTextColor(isDarkBackground))
                        .transition(.opacity)
                }
                Text(buttonTitle)
                    .fixedSize(horizontal: true, vertical: true)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .font(size.font)
                    .opacity(provider.isProcessing(for: type) ? 0.5 : 1)
                    .scaleEffect(provider.isProcessing(for: type) ? 0.95 : 1.0)
                    .accessibleAnimation(.easeInOut(duration: 0.2), value: provider.isProcessing(for: type))
            }
            .padding(size.padding)
            .frame(minHeight: size.height)
            .background(type.buttonBackgroundColor(isDarkBackground))
            .foregroundStyle(type.buttonTextColor(isDarkBackground))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(type.borderColor(isDarkBackground), lineWidth: type.hasBorder ? 2 : 0)
            )
        })
        .disabled(provider.isProcessing(for: type))
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityString)
        .accessibilityIdentifier(accessibilityID)
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
        case .medium: return 44
        case .small: return 44
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

    var buttonSpacing: CGFloat {
        switch self {
        case .large: return 18
        case .medium: return 16
        case .small: return 12
        }
    }
}

struct HapticFeedback {
    // `UIImpactFeedbackGenerator` and its `prepare()`/`impactOccurred()`
    // members are `@MainActor`-isolated UIKit APIs. Under `complete`-mode
    // strict concurrency a nonisolated `static func` calling them warns.
    // The sole caller is the SwiftUI `Button(action:)` closure in
    // `ActionButton.body`, which is already `@MainActor`, so pinning this to
    // the main actor is the correct isolation and adds no caller ripple.
    @MainActor
    static func medium() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }
}
