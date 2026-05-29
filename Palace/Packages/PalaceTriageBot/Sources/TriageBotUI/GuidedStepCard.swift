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
        VStack(alignment: .leading, spacing: 12) {
            Text("Step \(stepNumber) of \(totalSteps)")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            Text(step.instruction)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text(step.check)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button { onAction(.didNotResolve) } label: {
                    Text("No, still broken")
                        .font(.body.weight(.semibold))
                        .foregroundColor(Color(.systemBlue))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemBlue).opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("This step did not fix the issue")

                Button { onAction(.resolved) } label: {
                    Text("Yes, fixed it")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemGreen))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("This step resolved the issue")
            }

            Button { onAction(.abandon) } label: {
                Text("Skip troubleshooting and file a ticket")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip the remaining steps and file a support ticket instead")
        }
        .padding(14)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.systemBlue).opacity(0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guided troubleshooting step \(stepNumber) of \(totalSteps)")
    }
}
#endif
