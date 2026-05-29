#if canImport(UIKit)
import SwiftUI
import TriageBotCore

/// One step of a guided troubleshooting flow. Shows the instruction + the
/// follow-up question + Yes/No buttons. The "Skip and just file a ticket"
/// escape is always available so users who don't want to be guided don't
/// feel trapped.
struct GuidedStepCard: View {
    enum Action {
        case resolved
        case didNotResolve
        case abandon
    }

    let stepNumber: Int        // 1-based for display
    let totalSteps: Int        // for "Step 1 of 3" affordance
    let step: KBStep
    let onAction: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BotUI.Spacing.medium) {
            // Header — step counter + progress dots
            HStack(spacing: BotUI.Spacing.small) {
                Text("Step \(stepNumber) of \(totalSteps)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Spacer()

                // Compact progress: filled dots for completed/current, hollow for upcoming
                HStack(spacing: 4) {
                    ForEach(0..<totalSteps, id: \.self) { idx in
                        Circle()
                            .fill(idx <= stepNumber - 1 ? Color(.systemBlue) : Color(.tertiaryLabel))
                            .frame(width: 6, height: 6)
                    }
                }
            }

            Text(step.instruction)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text(step.check)
                .font(.body.weight(.medium))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            BotUI.YesNoButtons(
                onYes: { onAction(.resolved) },
                onNo: { onAction(.didNotResolve) }
            )

            Button {
                onAction(.abandon)
            } label: {
                Label("Skip & file a ticket", systemImage: "chevron.right")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip remaining steps and file a support ticket")
        }
        .padding(BotUI.Spacing.cardPadding)
        .background(BotUI.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: BotUI.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guided troubleshooting step \(stepNumber) of \(totalSteps)")
    }
}
#endif
