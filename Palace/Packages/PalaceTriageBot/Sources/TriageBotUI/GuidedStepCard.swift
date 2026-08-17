#if canImport(UIKit)
import SwiftUI
import TriageBotCore

/// One step of a guided troubleshooting flow. Renders the instruction,
/// the check question, and a row of answer buttons — either the step's
/// explicit `responses` (each with its own label + outcome) or, when
/// none are defined, the legacy generic Yes/No pair.
struct GuidedStepCard: View {
    enum Action {
        case selectedResponse(index: Int)
        case resolved        // legacy Yes path
        case didNotResolve   // legacy No path
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
                    .foregroundStyle(.secondary)

                Spacer()

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
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // Render either the step's specific responses (preferred)
            // or fall back to the legacy generic Yes/No pair.
            if let responses = step.responses, !responses.isEmpty {
                ResponseButtons(responses: responses) { idx in
                    onAction(.selectedResponse(index: idx))
                }
            } else {
                BotUI.YesNoButtons(
                    onYes: { onAction(.resolved) },
                    onNo: { onAction(.didNotResolve) }
                )
            }

            Button {
                onAction(.abandon)
            } label: {
                Label("Skip & file a ticket", systemImage: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

/// Renders a step's explicit responses. Two responses → horizontal pair
/// (most common). Three+ responses → vertical stack so labels can be
/// longer without crowding. Color signals the semantic outcome —
/// resolved = green, advance = blue, escalate = neutral/secondary.
private struct ResponseButtons: View {
    let responses: [KBStepResponse]
    let onSelect: (Int) -> Void

    var body: some View {
        if responses.count <= 2 {
            HStack(spacing: BotUI.Spacing.small) {
                ForEach(Array(responses.enumerated()), id: \.offset) { idx, response in
                    button(for: response) { onSelect(idx) }
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            VStack(spacing: BotUI.Spacing.small) {
                ForEach(Array(responses.enumerated()), id: \.offset) { idx, response in
                    button(for: response) { onSelect(idx) }
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func button(for response: KBStepResponse, action: @escaping () -> Void) -> some View {
        let (fg, bg, icon): (Color, Color, String?) = {
            switch response.outcome {
            case .resolved:
                return (.white, Color(.systemGreen), "checkmark")
            case .advance:
                return (.white, Color(.systemBlue), "arrow.right")
            case .escalate:
                return (Color(.systemBlue), Color(.systemBlue).opacity(0.12), nil)
            case .notApplicable:
                // "This does not apply to me" moves on like `advance`, so it
                // keeps the forward arrow — but it is not a report that the step
                // failed, and styling it like one would invite the patron to
                // read it as another dead end. Neutral, secondary.
                return (Color(.secondaryLabel), Color(.secondarySystemFill), "arrow.right")
            }
        }()
        Button(action: action) {
            HStack(spacing: BotUI.Spacing.xsmall) {
                if let icon {
                    Image(systemName: icon)
                        .font(.body.weight(.semibold))
                }
                Text(response.label)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .foregroundStyle(fg)
            .background(bg)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(response.label)
    }
}
#endif
