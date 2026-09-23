#if canImport(UIKit)
import SwiftUI
import TriageBotCore

struct KBMatchCard: View {
    enum Action {
        case notifyMe
        case fileAnyway
        case dismiss
        /// User opted into the multi-step troubleshooting flow. Only
        /// dispatched when the entry has `userFacingSteps` populated.
        case walkMeThroughIt
    }

    let entry: KBEntry
    let onAction: (Action) -> Void

    private var hasGuidedSteps: Bool {
        (entry.userFacingSteps?.isEmpty == false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BotUI.Spacing.medium) {
            statusBadge

            Text(entry.userFacingWorkaround)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            // Primary action — full width, can't be misread. Either the
            // guided-flow entry point (preferred when steps exist) or the
            // "file a ticket" path (when there's nothing to walk through).
            if hasGuidedSteps {
                BotUI.PrimaryButton(
                    title: "Walk me through it",
                    systemImage: "list.bullet.rectangle"
                ) { onAction(.walkMeThroughIt) }
            } else {
                BotUI.PrimaryButton(
                    title: "File a ticket",
                    systemImage: "envelope.fill"
                ) { onAction(.fileAnyway) }
            }

            // Secondary actions row. Single line, tight chips. Only shown
            // when there ARE secondary actions to take.
            HStack(spacing: BotUI.Spacing.small) {
                if KBMatchActionPolicy.showsNotifyMeOnFix(
                    entryHasFixVersion: entry.fixedInVersion != nil
                ) {
                    BotUI.SecondaryChip(title: "Notify me", systemImage: "bell.fill") {
                        onAction(.notifyMe)
                    }
                }
                if hasGuidedSteps {
                    // When guided flow is the primary, file-ticket becomes
                    // a secondary "skip the steps" affordance.
                    BotUI.SecondaryChip(title: "Just file a ticket", systemImage: "envelope") {
                        onAction(.fileAnyway)
                    }
                }
            }

            Button("Thanks, I'm good") {
                onAction(.dismiss)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(BotUI.Spacing.cardPadding)
        .background(BotUI.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: BotUI.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        // Was "Known issue match: <id>" — factually wrong for a how-to or a
        // generic ladder, and it read an internal id aloud. Announce what the
        // card actually claims, in the same words a sighted patron sees.
        .accessibilityLabel(badgePresentation.label)
    }

    /// Badge presentation. The DECISION lives in TriageBotCore so it can be
    /// tested — this target is behind `canImport(UIKit)` and macOS
    /// `swift test` never sees it. Here we only map a semantic badge to its
    /// presentation, and reuse the label for VoiceOver.
    private var badgePresentation: (label: String, symbol: String, color: Color) {
        let badge = KBMatchBadgePolicy.badge(for: entry)
        // Text comes from Core (`KBMatchBadge.label`) so it is testable and the
        // port shares it; only the symbol and colour are decided here.
        let (symbol, color): (String, Color) = {
            switch badge {
            case .fixedIn:               return ("checkmark.seal.fill", .green)
            case .knownIssueFixComing:   return ("wrench.and.screwdriver.fill", .orange)
            case .knownIssueWorkaround:  return ("exclamationmark.triangle.fill", .orange)
            case .setupMixUp:            return ("info.circle.fill", .blue)
            case .byDesign:              return ("info.circle", .gray)
            case .tracked:               return ("tag.fill", .gray)
            case .howTo:                 return ("questionmark.circle.fill", .blue)
            // A generic ladder, not an answer — must not read as one.
            case .narrowingDown:         return ("arrow.triangle.branch", .gray)
            }
        }()
        return (badge.label, symbol, color)
    }

    @ViewBuilder private var statusBadge: some View {
        let (label, symbol, color) = badgePresentation
        Label {
            Text(label)
                .font(.caption.weight(.semibold))
        } icon: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .lineLimit(2)
    }
}
#endif
