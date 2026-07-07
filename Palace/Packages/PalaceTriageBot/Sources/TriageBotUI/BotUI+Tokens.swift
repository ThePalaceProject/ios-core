#if canImport(UIKit)
import SwiftUI

/// Shared design tokens + reusable button primitives for the triage bot
/// chat surface. Keeping these in one place means a polish pass touches
/// one file instead of five, and the visual language stays consistent
/// across cards, chips, and bubbles.
///
/// Naming follows Apple's HIG vocabulary where possible — `.regularMaterial`,
/// system blue, standard 8-pt spacing rhythm.
enum BotUI {

    // MARK: - Spacing rhythm

    enum Spacing {
        /// 6 pt — within a single control (icon + text inside a button).
        static let xsmall: CGFloat = 6
        /// 8 pt — between sibling controls in the same row.
        static let small: CGFloat = 8
        /// 12 pt — between sections of a card.
        static let medium: CGFloat = 12
        /// 16 pt — between top-level cards / chat bubbles.
        static let large: CGFloat = 16
        /// 14 pt — internal padding for a card.
        static let cardPadding: CGFloat = 14
    }

    // MARK: - Card chrome

    /// Material-backed card surface. Renders with depth in both light and
    /// dark mode without color collisions (lesson learned from the
    /// `accentColor`-was-white-in-dark-mode bug across chaos-qa F-003
    /// and the ChatBubble follow-up).
    static let cardBackground: some ShapeStyle = Material.regularMaterial

    static let cardCornerRadius: CGFloat = 16

    // MARK: - Buttons

    /// Full-width primary action. White-on-systemBlue capsule; can't be
    /// misread in any appearance. lineLimit + minimumScaleFactor prevent
    /// the wrap-to-second-line issue we saw with long labels in HStacks.
    struct PrimaryButton: View {
        let title: String
        let systemImage: String?
        let action: () -> Void

        init(title: String, systemImage: String? = nil, action: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                HStack(spacing: Spacing.xsmall) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.body.weight(.semibold))
                    }
                    Text(title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .foregroundStyle(.white)
                .background(Color(.systemBlue))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
        }
    }

    /// Compact secondary chip. Tinted background, accent text. Sits in a
    /// row of siblings; never expands to fill width. Single line enforced.
    struct SecondaryChip: View {
        let title: String
        let systemImage: String?
        let action: () -> Void

        init(title: String, systemImage: String? = nil, action: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                HStack(spacing: Spacing.xsmall) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.footnote.weight(.semibold))
                    }
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(Color(.systemBlue))
                .background(Color(.systemBlue).opacity(0.14))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
        }
    }

    /// Full-width destructive-tinted action. Used for "Cancel" in ticket
    /// preview so it reads as the de-escalating choice without looking
    /// like a primary CTA.
    struct CancelButton: View {
        let title: String
        let action: () -> Void

        init(title: String = "Cancel", action: @escaping () -> Void) {
            self.title = title
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .foregroundStyle(Color(.systemBlue))
                    .background(Color(.systemBlue).opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
        }
    }

    /// Confirming Yes/No pair for guided-step cards. Green for resolved,
    /// blue-tinted for "still broken" — never red (we're not confirming
    /// destruction). Both single-line.
    struct YesNoButtons: View {
        let onYes: () -> Void
        let onNo: () -> Void

        var body: some View {
            HStack(spacing: Spacing.small) {
                Button(action: onNo) {
                    Text("Still broken")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .foregroundStyle(Color(.systemBlue))
                        .background(Color(.systemBlue).opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("This step did not resolve the issue")

                Button(action: onYes) {
                    HStack(spacing: Spacing.xsmall) {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                        Text("Fixed it")
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .foregroundStyle(.white)
                    .background(Color(.systemGreen))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("This step resolved the issue")
            }
        }
    }
}
#endif
